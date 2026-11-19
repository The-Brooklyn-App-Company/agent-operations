#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_mailroom.sh - the mailroom: rings, the supervisor, bridges, watchers.
. "$(dirname -- "$0")/lib.sh"

MR=
mr_setup() {
  profile_set relay_bridge on
  MR=$T/home/inbox/.mailroom
  printf 'gamma\tGamma Op\t%s\tthread-gamma\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
}
# bridge_rows: register both bridges.
bridge_rows() {
  printf 'mailroom-claude\tMailroom bridge (Claude)\t%s\tsid-bridge\tclaude\n' "$T/user" >>"$T/home/operators/REGISTRY.tsv"
  printf 'mailroom-codex\tMailroom bridge (Codex)\t%s\tthread-bridge\tcodex\n' "$T/user" >>"$T/home/operators/REGISTRY.tsv"
}
later() { AO_NOW=$(($(date +%s) + $1)); export AO_NOW; }
ring_count() { count_files "$MR/$1"; }
rings() { find "$MR/$1" -maxdepth 1 -name '*.md' -type f | sed 's|.*/||' | sort; }
# age_file FILE SECONDS  Set FILE's mtime SECONDS in the past.
age_file() {
  _t=$(($(date +%s) - $2))
  touch -t "$(date -r "$_t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$_t" +%Y%m%d%H%M.%S)" "$1"
}
# live_pid: a process that lives for the test (killed by the harness exit).
live_pid() { sleep 300 >/dev/null 2>&1 & LIVE=$!; }
stop_live() { kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; }
# notes_named PATTERN  Count Oracle inbox notes whose name contains PATTERN.
notes_named() {
  _c=0
  for _f in "$T/home/inbox/oracle"/*"$1"*; do [ -f "$_f" ] && _c=$((_c + 1)); done
  echo "$_c"
}

test_relay_rings_the_claude_bridge_instead_of_a_headless_run() {
  mr_setup
  note alpha 001-a.md "secret body"
  run relay.sh
  assert_rc 0
  assert_count "$T/home/inbox/alpha" 0
  assert_count "$T/home/inbox/sent" 1
  assert_no_file "$T/home/inbox/alpha/.relay-pending"
  r=$(rings claude)
  case $r in sid-alpha--alpha-*.md) ;; *) _fail "unexpected ring name: $r" ;; esac
  assert_has "$MR/claude/$r" "Relay (automated inbox, not from the human):"
  assert_has "$MR/claude/$r" "relay-id: alpha-"
  assert_lacks "$MR/claude/$r" "secret body"
  assert_no_file "$FAKE_LOG"
  assert_has "$T/state/relay.log" "via=mailroom-claude"
  assert_has "$T/state/mailroom.tsv" "${TAB}ring${TAB}claude${TAB}$r"
}

test_codex_rings_carry_steer_or_queue_from_the_note_name() {
  mr_setup
  note gamma 001-plain.md "x"
  run relay.sh
  assert_rc 0
  note gamma 002-URGENT-fix.md "y"
  later 2
  run relay.sh
  assert_rc 0
  assert_eq "$(rings codex | grep -c -- '--queue.md$')" 1 "queue rings"
  assert_eq "$(rings codex | grep -c -- '--steer.md$')" 1 "steer rings"
  assert_eq "$(rings codex | grep -c '^thread-gamma--gamma-')" 2 "target thread leads the name"
  assert_no_file "$FAKE_LOG"
}

test_rows_without_a_session_and_bridge_rows_are_not_rung() {
  mr_setup
  bridge_rows
  printf 'delta\tDelta Op\t%s\tpending\tclaude\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note delta a.md "x"
  note mailroom-claude b.md "y"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_eq "$(ring_count claude)" 0 "rings"
  assert_has "$FAKE_LOG" 'to "Delta Op"'
  assert_count "$T/home/inbox/mailroom-claude" 1
}

test_relay_bridge_off_delivers_directly() {
  note alpha a.md "x"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_has "$FAKE_LOG" 'to "Alpha Op"'
  assert_no_file "$T/home/inbox/.mailroom"
}

test_supervisor_leaves_young_rings_and_falls_back_for_old_claude_rings() {
  mr_setup
  note alpha a.md "x"
  run relay.sh
  r=$(rings claude)
  later 60
  run mailroom.sh supervise
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  later 200
  FAKE_MODE=sent run mailroom.sh supervise
  assert_rc 0
  assert_has "$FAKE_LOG" 'to "Alpha Op"'
  assert_has "$FAKE_LOG" 'relay-id: alpha-'
  assert_eq "$(ring_count claude)" 1 "only delivered/ left"
  assert_has "$MR/claude/delivered/log.tsv" "$r${TAB}fallback${TAB}-${TAB}ok"
  assert_has "$T/state/mailroom.tsv" "fallback-ok"
}

test_failed_fallbacks_are_spaced_capped_and_alarm_once() {
  mr_setup
  note alpha a.md "x"
  run relay.sh
  later 200
  FAKE_MODE=failed run mailroom.sh supervise
  assert_rc 1
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 1 "first attempt"
  later 260
  FAKE_MODE=failed run mailroom.sh supervise
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 1 "spaced: no second attempt yet"
  later 700
  FAKE_MODE=failed run mailroom.sh supervise
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 2 "second attempt"
  assert_eq "$(notes_named mailroom-ring-waiting)" 1 "one alarm"
  later 1100
  FAKE_MODE=failed run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-ring-waiting)" 1 "still one alarm"
}

test_old_codex_rings_are_queued_to_the_target_unless_held() {
  mr_setup
  note gamma a.md "x"
  note gamma b-urgent.md "y"
  run relay.sh
  later 2
  note gamma c.md "z"
  run relay.sh
  unset AO_NOW
  for r in $(rings codex); do age_file "$MR/codex/$r" 200; done
  held=$(rings codex | head -n 1)
  mkdir -p "$MR/codex/.watcher/holding"
  live_pid
  printf '2026-11-19T00:00:00Z %s\n' "$LIVE" >"$MR/codex/.watcher/heartbeat"
  date +%s >"$MR/codex/.watcher/holding/$held"
  run mailroom.sh supervise
  assert_rc 0
  stop_live
  assert_eq "$(grep -c '^== codex' "$FAKE_LOG")" 1 "one direct queue: the other ring is held"
  assert_has "$FAKE_LOG" 'arg: thread-gamma'
  assert_has "$FAKE_LOG" '(mailroom fallback, queued)'
  assert_has "$FAKE_LOG" 'arg: --resume'
  assert_eq "$(rings codex)" "$held" "the held ring waits"
  assert_has "$MR/codex/delivered/log.tsv" "queue-direct${TAB}queue${TAB}accepted"
}

test_a_down_bridge_gets_one_rearm_an_hour_then_an_alarm() {
  mr_setup
  bridge_rows
  FAKE_MODE=sent run mailroom.sh supervise
  assert_rc 0
  assert_has "$FAKE_LOG" 'arg: thread-bridge'
  assert_has "$FAKE_LOG" 'Re-arm doorbell watcher'
  assert_has "$FAKE_LOG" 'to "Mailroom bridge (Claude)"'
  _n=$(grep -c '^== ' "$FAKE_LOG")
  later 600
  run mailroom.sh supervise
  assert_eq "$(grep -c '^== ' "$FAKE_LOG")" "$_n" "no second re-arm within the hour"
  assert_count "$T/home/inbox/oracle" 0
  later 3700
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-bridge-down)" 2 "one alarm per side"
  assert_has "$T/state/mailroom.tsv" "${TAB}bridge-down${TAB}codex"
}

test_an_armed_bridge_is_left_alone_and_probed_for_free() {
  mr_setup
  bridge_rows
  live_pid
  mkdir -p "$MR/claude/.watcher" "$MR/codex/.watcher"
  printf '%s\n' "$LIVE" >"$MR/claude/.watcher/pid"
  printf '2026-11-19T00:00:00Z %s\n' "$LIVE" >"$MR/codex/.watcher/heartbeat"
  run mailroom.sh supervise
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  pc=$(rings claude) px=$(rings codex)
  case $pc in echo--probe-*.md) ;; *) _fail "no Claude probe ring: $pc" ;; esac
  case $px in echo--probe-*--queue.md) ;; *) _fail "no Codex probe ring: $px" ;; esac
  run mailroom.sh file claude "$pc"
  assert_rc 0
  assert_has "$MR/claude/delivered/log.tsv" "$pc${TAB}bridge${TAB}echo"
  # An hour later: the Claude bridge filed its probe; the Codex watcher died.
  age_file "$T/state/mailroom-probe/sent" 3700
  printf '2026-11-19T00:00:00Z 1\n' >"$MR/codex/.watcher/heartbeat"
  FAKE_MODE=sent run mailroom.sh supervise
  stop_live
  assert_has "$T/state/mailroom-probe.tsv" "${TAB}claude${TAB}ok${TAB}"
  assert_has "$T/state/mailroom-probe.tsv" "${TAB}codex${TAB}FAIL${TAB}"
  assert_eq "$(notes_named mailroom-probe-fail-codex)" 1 "probe alarm"
}

test_file_moves_rings_and_rejects_bad_names() {
  mr_setup
  mkdir -p "$MR/claude"
  printf 'x\n' >"$MR/claude/sid-a--a-1.md"
  printf 'y\n' >"$MR/claude/sid-b--b-1.md"
  run mailroom.sh file claude sid-a--a-1.md "$MR/claude/sid-b--b-1.md" --mode sent
  assert_rc 0
  assert_eq "$(ring_count claude)" 1 "only delivered/ left"
  assert_eq "$(grep -c "${TAB}bridge${TAB}sent${TAB}ok" "$MR/claude/delivered/log.tsv")" 2 "logged"
  run mailroom.sh file claude sid-a--a-1.md
  assert_rc 1
  run mailroom.sh file claude 'bad name.md'
  assert_rc 2
  run mailroom.sh file other x.md
  assert_rc 2
}

test_metrics_count_rings_deliveries_and_latency() {
  mr_setup
  note alpha a.md "x"
  later 0
  run relay.sh
  r=$(rings claude)
  AO_NOW=$((AO_NOW + 30))
  run mailroom.sh file claude "$r"
  run mailroom.sh metrics 24
  assert_rc 0
  assert_has "$T/out" "Claude: rings 1; delivered by bridge 1, by fallback 0 (failed 0); median ring-to-delivery 30s."
  assert_has "$T/out" "Waiting now: Claude 0, Codex 0."
  run mailroom.sh metrics 0
  assert_rc 2
}

test_status_reports_each_side() {
  mr_setup
  bridge_rows
  run mailroom.sh status
  assert_rc 0
  assert_has "$T/out" "claude: watcher DOWN; waiting 0"
  assert_has "$T/out" "codex: watcher DOWN; waiting 0"
}

test_doorbells_ring_the_mailroom() {
  mr_setup
  run doorbell-claude.sh ring "Alpha Op" sid-alpha
  assert_rc 0
  assert_has "$T/out" "mailroom sid-alpha--doorbell-"
  assert_has "$MR/claude/$(rings claude)" "doorbell-id: doorbell-"
  assert_no_file "$FAKE_LOG"
  profile_set doorbell_codex queue
  run doorbell-codex.sh ring "Gamma Op" thread-gamma
  assert_rc 0
  case $(rings codex) in thread-gamma--doorbell-*--queue.md) ;; *) _fail "no Codex doorbell ring" ;; esac
  assert_no_file "$FAKE_LOG"
}

test_wait_blocks_until_a_ring_and_records_its_pid() {
  if ! [ -x /usr/bin/python3 ] || ! /usr/bin/python3 -c 'import select; select.kqueue' 2>/dev/null; then
    echo "    (skipped: no kqueue)"
    return 0
  fi
  mr_setup
  mkdir -p "$MR/claude"
  "$AO_TEST_SHELL" "$SCRIPTS/mailroom.sh" wait claude </dev/null >"$T/out" 2>"$T/err" &
  w=$!
  _n=0
  while [ ! -f "$MR/claude/.watcher/pid" ] && [ "$_n" -lt 50 ]; do sleep 0.1; _n=$((_n + 1)); done
  assert_eq "$(cat "$MR/claude/.watcher/pid")" "$w" "pid recorded (sh execs python)"
  kill -0 "$w" 2>/dev/null || _fail "wait returned with no ring"
  printf 'hello\n' >"$MR/claude/.t" && mv "$MR/claude/.t" "$MR/claude/sid-a--a-1.md"
  _n=0
  while kill -0 "$w" 2>/dev/null && [ "$_n" -lt 50 ]; do sleep 0.1; _n=$((_n + 1)); done
  kill -0 "$w" 2>/dev/null && { kill "$w"; _fail "wait did not return"; }
  wait "$w"
  assert_eq "$?" 0 "exit code"
  assert_has "$T/out" "=== sid-a--a-1.md"
  assert_has "$T/out" "hello"
}

# ---------------------------------------------------------------- Codex watcher

# watcher [VAR=VALUE...]  Start the watcher against the fake app server.
watcher() {
  env FAKE_APP_LOG="$T/app.log" FAKE_APP_BUSY_DIR="$T/busy" AO_MR_IDLE_POLL_MS=100 AO_MR_HEARTBEAT_MS=200 "$@" \
    node "$SCRIPTS/mailroom-codex-watcher.cjs" --dir "$MR/codex" --server "$TESTS_DIR/fakes/fake-app-tools.cjs" \
    --self-thread thread-bridge </dev/null >"$T/wout" 2>"$T/werr" &
  WPID=$!
  _n=0
  while ! grep -q armed "$T/wout" 2>/dev/null && kill -0 "$WPID" 2>/dev/null && [ "$_n" -lt 50 ]; do sleep 0.1; _n=$((_n + 1)); done
}
put_ring() { printf '%s\n' "$2" >"$MR/codex/.t" && mv "$MR/codex/.t" "$MR/codex/$1"; }
wait_for() { _n=0; while ! eval "$1" && [ "$_n" -lt "${2:-50}" ]; do sleep 0.1; _n=$((_n + 1)); done; eval "$1"; }
has_node() { command -v node >/dev/null 2>&1 || { echo "    (skipped: node not installed)"; return 1; }; }

test_codex_watcher_delivers_a_burst_once_in_order_and_holds_queue_rings() {
  has_node || return 0
  mr_setup
  mkdir -p "$MR/codex" "$T/busy"
  put_ring thread-a--a-0--queue.md "waiting at start"
  : >"$T/busy/thread-q"
  watcher
  for i in 1 2 3 4 5; do put_ring "thread-s--s-$i--steer.md" "burst $i"; done
  put_ring thread-q--q-1--queue.md "for a busy thread"
  put_ring echo--probe-1--queue.md "probe"
  wait_for '[ "$(grep -c "${TAB}steer${TAB}ok" "$MR/codex/delivered/log.tsv" 2>/dev/null)" = 5 ]'
  wait_for '[ -f "$MR/codex/.watcher/holding/thread-q--q-1--queue.md" ]'
  assert_file "$MR/codex/thread-q--q-1--queue.md"
  rm "$T/busy/thread-q"
  wait_for '[ ! -f "$MR/codex/thread-q--q-1--queue.md" ]'
  assert_file "$MR/codex/.watcher/heartbeat"
  kill "$WPID"
  wait "$WPID"
  assert_eq "$?" 0 "stopped by TERM"
  assert_has "$MR/codex/delivered/log.tsv" "thread-a--a-0--queue.md${TAB}watcher${TAB}queue${TAB}ok"
  assert_has "$MR/codex/delivered/log.tsv" "thread-q--q-1--queue.md${TAB}watcher${TAB}queue${TAB}ok"
  assert_has "$MR/codex/delivered/log.tsv" "echo--probe-1--queue.md${TAB}watcher${TAB}echo${TAB}ok"
  assert_eq "$(grep -c send_message_to_thread "$T/app.log")" 7 "one send per ring, none for the probe"
  assert_eq "$(grep send_message_to_thread "$T/app.log" | grep -o 'burst [0-9]' | tr -d '\n')" "burst 1burst 2burst 3burst 4burst 5" "in order"
  assert_has "$T/app.log" '"prompt":"Doorbell [thread-s--s-1--steer.md]: burst 1"'
  assert_has "$T/app.log" '"hostId":"local"'
  assert_no_file "$MR/codex/.watcher/pid"
}

test_codex_watcher_releases_a_queue_ring_at_the_cap_and_marks_unknown_state() {
  has_node || return 0
  mr_setup
  mkdir -p "$MR/codex" "$T/busy"
  : >"$T/busy/thread-q"
  watcher AO_MR_HOLD_CAP_MS=500
  put_ring thread-q--q-1--queue.md "never idle"
  wait_for 'grep -q queue-cap "$MR/codex/.watcher/log"'
  assert_file "$MR/codex/thread-q--q-1--queue.md"
  assert_no_file "$MR/codex/.watcher/holding/thread-q--q-1--queue.md"
  kill "$WPID"
  wait "$WPID"
  watcher FAKE_APP_MODE=nostatus
  put_ring thread-u--u-1--queue.md "unknown"
  wait_for 'grep -q "thread-u--u-1--queue.md${TAB}watcher${TAB}queue-unknown${TAB}ok" "$MR/codex/delivered/log.tsv"'
  kill "$WPID"
  wait "$WPID"
}

test_codex_watcher_refuses_bad_preflight_a_second_copy_and_a_closed_pipe() {
  has_node || return 0
  mr_setup
  mkdir -p "$MR/codex"
  watcher FAKE_APP_MODE=nolist
  wait "$WPID"
  assert_eq "$?" 2 "preflight"
  assert_has "$T/werr" "send_message_to_thread missing"
  watcher
  first=$WPID
  watcher
  wait "$WPID"
  assert_eq "$?" 3 "second copy"
  kill "$first"
  wait "$first"
  watcher FAKE_APP_MODE=die-on-send
  put_ring thread-s--s-1--steer.md "x"
  wait "$WPID"
  assert_eq "$?" 1 "pipe closed"
  assert_file "$MR/codex/thread-s--s-1--steer.md"
  assert_has "$MR/codex/.watcher/log" "connection lost"
}

test_codex_watcher_never_resends_after_a_timeout() {
  has_node || return 0
  mr_setup
  mkdir -p "$MR/codex"
  watcher FAKE_APP_MODE=hang-on-send AO_MR_CALL_TIMEOUT_MS=300
  put_ring thread-s--s-1--steer.md "x"
  wait_for 'grep -q "${TAB}steer${TAB}unknown" "$MR/codex/delivered/log.tsv" 2>/dev/null'
  sleep 0.5
  assert_eq "$(grep -c send_message_to_thread "$T/app.log")" 1 "sent once"
  kill "$WPID"
  wait "$WPID"
}

test_arm_codex_needs_the_app_paths_and_reports_an_armed_watcher() {
  mr_setup
  run mailroom.sh arm-codex
  assert_rc 2
  assert_has "$T/err" "bridge_codex_node"
  live_pid
  mkdir -p "$MR/codex/.watcher"
  printf '2026-11-19T00:00:00Z %s\n' "$LIVE" >"$MR/codex/.watcher/heartbeat"
  run mailroom.sh arm-codex
  stop_live
  assert_rc 0
  assert_has "$T/out" "armed"
}

ao_test_main "$0"
