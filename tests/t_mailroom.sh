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
  printf 'mailroom-claude\tMailroom\t%s\tsid-bridge\tclaude\n' "$T/user" >>"$T/home/operators/REGISTRY.tsv"
  printf 'mailroom-codex\tMailroom\t%s\tthread-bridge\tcodex\n' "$T/user" >>"$T/home/operators/REGISTRY.tsv"
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
  assert_has "$MR/claude/delivered/log.tsv" "$r${TAB}t3-headless${TAB}send${TAB}ok"
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
  assert_has "$MR/codex/delivered/log.tsv" "t3-cli-queue${TAB}queue${TAB}accepted"
}

test_a_down_bridge_gets_one_rearm_per_app_process_then_one_alarm() {
  mr_setup
  bridge_rows
  mkdir -p "$MR/codex/.watcher"
  : >"$MR/codex/.watcher/log"
  later 0
  FAKE_MODE=sent run mailroom.sh supervise
  assert_rc 0
  assert_has "$FAKE_LOG" 'arg: thread-bridge'
  assert_has "$FAKE_LOG" 'Re-arm doorbell watcher'
  assert_has "$FAKE_LOG" 'to "Mailroom"'
  assert_lacks "$FAKE_LOG" '== open'
  _n=$(grep -c '^== ' "$FAKE_LOG")
  later 60
  run mailroom.sh supervise
  assert_eq "$(grep -c '^== ' "$FAKE_LOG")" "$_n" "no second re-arm for the same app process"
  assert_eq "$(notes_named mailroom-bridge-down)" 0 "no alarm inside the grace"
  later 200
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-bridge-down)" 2 "one alarm per side"
  later 900
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-bridge-down)" 2 "still one alarm per side"
  assert_eq "$(grep -c '^== ' "$FAKE_LOG")" "$_n" "still no second re-arm"
  # The Codex app restarted: a new process gets one re-arm.
  echo 4343 >"$T/apps/com.openai.codex"
  later 960
  run mailroom.sh supervise
  assert_eq "$(grep -c 'Re-arm doorbell watcher' "$FAKE_LOG")" 2 "re-armed for the new app process"
  assert_has "$T/state/mailroom.tsv" "${TAB}bridge-down${TAB}codex"
}

test_an_app_that_is_not_running_is_opened_not_messaged() {
  mr_setup
  bridge_rows
  echo none >"$T/apps/com.anthropic.claudefordesktop"
  later 0
  run mailroom.sh supervise
  assert_has "$FAKE_LOG" 'arg: com.anthropic.claudefordesktop'
  assert_lacks "$FAKE_LOG" 'to "Mailroom"'
  assert_lacks "$FAKE_LOG" 'Re-arm doorbell watcher'
  later 600
  run mailroom.sh supervise
  assert_eq "$(grep -c '^== open' "$FAKE_LOG")" 1 "opened at most once an hour"
  assert_has "$T/state/mailroom.tsv" "${TAB}relaunch${TAB}claude"
}

test_an_undeployed_codex_watcher_is_left_alone() {
  mr_setup
  printf 'mailroom-codex\tMailroom\t%s\tthread-bridge\tcodex\n' "$T/user" >>"$T/home/operators/REGISTRY.tsv"
  run mailroom.sh supervise
  assert_rc 0
  assert_no_file "$FAKE_LOG"
}

test_an_armed_bridge_is_left_alone_and_never_probed() {
  mr_setup
  bridge_rows
  live_pid
  mkdir -p "$MR/claude/.watcher" "$MR/codex/.watcher" "$T/state/mailroom-probe"
  printf '%s\n' "$LIVE" >"$MR/claude/.watcher/pid"
  printf '2026-11-19T00:00:00Z %s\n' "$LIVE" >"$MR/codex/.watcher/heartbeat"
  run mailroom.sh supervise
  stop_live
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  assert_eq "$(rings claude | grep -c probe)" 0 "no hourly probe"
  assert_no_file "$T/state/mailroom-probe"
}

test_file_moves_rings_and_rejects_bad_names() {
  mr_setup
  mkdir -p "$MR/claude"
  printf 'x\n' >"$MR/claude/sid-a--a-1.md"
  printf 'y\n' >"$MR/claude/sid-b--b-1.md"
  run mailroom.sh file claude sid-a--a-1.md "$MR/claude/sid-b--b-1.md" --mode sent
  assert_rc 0
  assert_eq "$(ring_count claude)" 1 "only delivered/ left"
  assert_eq "$(grep -c "${TAB}t2-bridge${TAB}sent${TAB}ok${TAB}" "$MR/claude/delivered/log.tsv")" 2 "logged"
  run mailroom.sh file claude sid-a--a-1.md --tier t9
  assert_rc 2
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
  touch -t "$(date -r "$AO_NOW" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$AO_NOW" +%Y%m%d%H%M.%S)" "$MR/claude/$r"
  AO_NOW=$((AO_NOW + 30))
  run mailroom.sh file claude "$r"
  assert_has "$MR/claude/delivered/log.tsv" "$r${TAB}t2-bridge${TAB}send${TAB}ok${TAB}30000${TAB}-"
  run mailroom.sh metrics 24
  assert_rc 0
  assert_has "$T/out" "Claude: rings 1; delivered 1: t2-bridge 100% (1; p50 30.0s, p90 30.0s), t3-headless 0; first tier t2-bridge: ok -"
  assert_has "$T/out" "Waiting now: Claude 0, Codex 0."
  run mailroom.sh metrics 0
  assert_rc 2
}

test_status_reports_each_side() {
  mr_setup
  bridge_rows
  run mailroom.sh status
  assert_rc 0
  assert_has "$T/out" "claude: watcher DOWN; first tier t2-bridge (ok -); waiting 0"
  assert_has "$T/out" "codex: watcher DOWN; first tier t1-native (ok -); waiting 0"
}

test_doorbells_ring_the_mailroom() {
  mr_setup
  run doorbell-claude.sh ring "Alpha Op" sid-alpha
  assert_rc 0
  assert_has "$T/out" "mailroom sid-alpha--.doorbell-"
  assert_has "$MR/claude/$(rings claude)" "doorbell-id: doorbell-"
  assert_no_file "$FAKE_LOG"
  profile_set doorbell_codex queue
  run doorbell-codex.sh ring "Gamma Op" thread-gamma
  assert_rc 0
  case $(rings codex) in thread-gamma--.doorbell-*--queue.md) ;; *) _fail "no Codex doorbell ring" ;; esac
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
  assert_file "$MR/claude/.watcher/handing/sid-a--a-1.md"
  run mailroom.sh file claude sid-a--a-1.md --mode sent
  assert_rc 0
  assert_has "$MR/claude/delivered/log.tsv" "sid-a--a-1.md${TAB}t2-bridge${TAB}sent${TAB}ok"
  # A probe ring is filed by the watcher itself and wakes nobody.
  "$AO_TEST_SHELL" "$SCRIPTS/mailroom.sh" wait claude </dev/null >"$T/out2" 2>&1 &
  w=$!
  wait_for '[ "$(cat "$MR/claude/.watcher/pid" 2>/dev/null)" = "$w" ]' 100
  # A second watcher is refused while this one holds the lock.
  run mailroom.sh wait claude
  assert_rc 3
  assert_has "$T/out" "armed: another watcher is running"
  printf 'p\n' >"$MR/claude/.t" && mv "$MR/claude/.t" "$MR/claude/echo--probe-1.md"
  wait_for 'grep -q "echo--probe-1.md" "$MR/claude/delivered/log.tsv"'
  kill -0 "$w" 2>/dev/null || _fail "a probe woke the bridge"
  kill "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  assert_has "$MR/claude/delivered/log.tsv" "echo--probe-1.md${TAB}none${TAB}echo${TAB}ok"
}

# ---------------------------------------------------------------- Codex watcher

# watcher [VAR=VALUE...]  Start the watcher against the fake app server.
watcher() {
  env FAKE_APP_LOG="$T/app.log" FAKE_APP_BUSY_DIR="$T/busy" AO_MR_HEARTBEAT_MS=200 "$@" \
    node "$SCRIPTS/mailroom-codex-watcher.cjs" --dir "$MR/codex" --server "$TESTS_DIR/fakes/fake-app-tools.cjs" \
    --self-thread thread-bridge </dev/null >"$T/wout" 2>"$T/werr" &
  WPID=$!
  _n=0
  while ! grep -q armed "$T/wout" 2>/dev/null && kill -0 "$WPID" 2>/dev/null && [ "$_n" -lt 50 ]; do sleep 0.1; _n=$((_n + 1)); done
}
put_ring() { printf '%s\n' "$2" >"$MR/codex/.t" && mv "$MR/codex/.t" "$MR/codex/$1"; }
wait_for() { _n=0; while ! eval "$1" 2>/dev/null && [ "$_n" -lt "${2:-50}" ]; do sleep 0.1; _n=$((_n + 1)); done; eval "$1" 2>/dev/null; }
has_node() { command -v node >/dev/null 2>&1 || { echo "    (skipped: node not installed)"; return 1; }; }
# rollout THREAD  A target's rollout file, as the Codex app writes it.
rollout() {
  mkdir -p "$T/codex/sessions/2026/11/19"
  ROLLOUT=$T/codex/sessions/2026/11/19/rollout-2026-11-19T00-00-00-$1.jsonl
  printf '{"type":"session_meta"}\n' >>"$ROLLOUT"
}
turn_complete() { printf '{"type":"event_msg","payload":{"type":"task_complete"}}\n' >>"$ROLLOUT"; }

test_codex_watcher_delivers_a_burst_once_in_order_and_holds_queue_rings() {
  has_node || return 0
  mr_setup
  mkdir -p "$MR/codex" "$T/busy"
  put_ring thread-a--a-0--queue.md "waiting at start"
  : >"$T/busy/thread-q"
  rollout thread-q
  watcher
  for i in 1 2 3 4 5; do put_ring "thread-s--s-$i--steer.md" "burst $i"; done
  put_ring thread-q--q-1--queue.md "for a busy thread"
  put_ring echo--probe-1--queue.md "probe"
  wait_for '[ "$(grep -c "${TAB}steer${TAB}ok" "$MR/codex/delivered/log.tsv" 2>/dev/null)" = 5 ]'
  wait_for '[ -f "$MR/codex/.watcher/holding/thread-q--q-1--queue.md" ]'
  assert_file "$MR/codex/thread-q--q-1--queue.md"
  # Idle now, but no turn-complete event yet: nothing polls, so it waits.
  rm "$T/busy/thread-q"
  sleep 0.6
  assert_file "$MR/codex/thread-q--q-1--queue.md"
  reads=$(grep -c '"read_thread"' "$T/app.log")
  printf '{"type":"event_msg","payload":{"type":"token_count"}}\n' >>"$ROLLOUT"
  sleep 0.4
  assert_eq "$(grep -c '"read_thread"' "$T/app.log")" "$reads" "unrelated appends trigger no read"
  turn_complete
  wait_for 'grep -q "thread-q--q-1--queue.md" "$MR/codex/delivered/log.tsv"'
  assert_file "$MR/codex/.watcher/heartbeat"
  kill "$WPID"
  wait "$WPID"
  assert_eq "$?" 0 "stopped by TERM"
  assert_has "$MR/codex/delivered/log.tsv" "thread-a--a-0--queue.md${TAB}t1-native${TAB}queue${TAB}ok"
  assert_has "$MR/codex/delivered/log.tsv" "thread-q--q-1--queue.md${TAB}t1-native${TAB}queue${TAB}ok"
  assert_has "$MR/codex/delivered/log.tsv" "echo--probe-1--queue.md${TAB}none${TAB}echo${TAB}ok"
  assert_has "$MR/codex/.watcher/fingerprint" "tools="
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
  rollout thread-q
  watcher AO_MR_HOLD_CAP_MS=500
  put_ring thread-q--q-1--queue.md "never idle"
  wait_for 'grep -q queue-cap "$MR/codex/.watcher/log"'
  assert_file "$MR/codex/thread-q--q-1--queue.md"
  assert_no_file "$MR/codex/.watcher/holding/thread-q--q-1--queue.md"
  kill "$WPID"
  wait "$WPID"
  assert_eq "$(cat "$MR/codex/.watcher/released/thread-q--q-1--queue.md")" queue-cap "release step"
  # An unreadable thread state counts as busy: held, never sent at once.
  rollout thread-u
  watcher FAKE_APP_MODE=nostatus AO_MR_HOLD_CAP_MS=500
  put_ring thread-u--u-1--queue.md "unknown"
  wait_for 'grep -q "released thread-u--u-1--queue.md to tier 3: queue-cap" "$MR/codex/.watcher/log"'
  kill "$WPID"
  wait "$WPID"
  assert_file "$MR/codex/thread-u--u-1--queue.md"
  assert_eq "$(grep -c send_message_to_thread "$T/app.log")" 0 "never sent to an unreadable thread"
  # No rollout to tail: released to tier 3 at once, with the step.
  : >"$T/busy/thread-n"
  watcher
  n=thread-n--nrow-20261119T000000-abcdef--queue.md
  put_ring "$n" "no rollout"
  wait_for '[ -f "$MR/codex/.watcher/released/$n" ]'
  kill "$WPID"
  wait "$WPID"
  assert_eq "$(cat "$MR/codex/.watcher/released/$n")" no-rollout "release step"
  age_file "$MR/codex/$n" 200
  printf 'nrow\tN Op\t%s\tthread-n\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  run mailroom.sh supervise
  assert_has "$MR/codex/delivered/log.tsv" "$n${TAB}t3-cli-queue${TAB}queue${TAB}accepted${TAB}"
  assert_has "$MR/codex/delivered/log.tsv" "${TAB}no-rollout"
}

test_codex_watcher_refuses_bad_preflight_a_second_copy_and_a_closed_pipe() {
  has_node || return 0
  mr_setup
  mkdir -p "$MR/codex"
  watcher FAKE_APP_MODE=nolist
  wait "$WPID"
  assert_eq "$?" 2 "preflight"
  assert_has "$T/werr" "send_message_to_thread missing"
  watcher FAKE_APP_MODE=die-on-send
  put_ring thread-s--s-1--steer.md "x"
  wait "$WPID"
  assert_eq "$?" 1 "pipe closed"
  assert_has "$MR/codex/.watcher/log" "connection lost"
  # The send may have landed: never left for a fallback to send again.
  assert_no_file "$MR/codex/thread-s--s-1--steer.md"
  if [ -f "$MR/codex/.watcher/sending/thread-s--s-1--steer.md" ]; then
    run mailroom.sh supervise
    assert_has "$T/state/mailroom.tsv" "${TAB}unknown${TAB}codex${TAB}thread-s--s-1--steer.md"
  fi
  # Either way it is marked for reconciliation against the target's rollout.
  assert_file "$MR/codex/.watcher/unknown/thread-s--s-1--steer.md"
  assert_has "$MR/codex/delivered/log.tsv" "thread-s--s-1--steer.md${TAB}t1-native"
  assert_has "$MR/codex/delivered/log.tsv" "${TAB}unknown"
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
  assert_file "$MR/codex/.watcher/unknown/thread-s--s-1--steer.md"
  # Reconciled only once it is 5 minutes old; this thread has no record to
  # read, so it alarms once and is never resent.
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-unknown-codex)" 0 "too early to reconcile"
  later 400
  run mailroom.sh supervise
  unset AO_NOW
  assert_eq "$(notes_named mailroom-unknown-codex)" 1 "the supervisor alarms once"
  assert_no_file "$MR/codex/.watcher/unknown/thread-s--s-1--steer.md"
  assert_lacks "$FAKE_LOG" "arg: queue"
  # A protocol error after submission is just as unknown.
  watcher FAKE_APP_MODE=rpcerror-on-send
  put_ring thread-s--s-2--steer.md "y"
  wait_for 'grep -q "thread-s--s-2--steer.md${TAB}t1-native${TAB}steer${TAB}unknown" "$MR/codex/delivered/log.tsv"'
  sleep 0.3
  kill "$WPID"
  wait "$WPID"
  assert_eq "$(grep -c send_message_to_thread "$T/app.log")" 2 "each sent once"
}

# unknown_ring NAME  A Codex ring the watcher filed `unknown`.
unknown_ring() {
  mkdir -p "$MR/codex/delivered" "$MR/codex/.watcher/unknown"
  printf 'relay-id: r-%s\nnotes: x\n' "$1" >"$MR/codex/delivered/$1"
  printf '2026-11-19T00:00:00Z\t%s\t%s\tt1-native\tsteer\tunknown\t5\t-\n' "$(date +%s)" "$1" >>"$MR/codex/delivered/log.tsv"
  : >"$MR/codex/.watcher/unknown/$1"
}

test_unknown_codex_sends_reconcile_against_the_targets_record() {
  mr_setup
  rollout thread-gamma
  # Arrived after all: its text is in the rollout. No resend.
  unknown_ring thread-gamma--gamma-20261119T000001-aaaaa1--steer.md
  printf '{"type":"response_item","text":"Doorbell [thread-gamma--gamma-20261119T000001-aaaaa1--steer.md]: x"}\n' >>"$ROLLOUT"
  # Absent from a readable rollout: escalated once by the CLI queue.
  unknown_ring thread-gamma--gamma-20261119T000002-aaaaa2--steer.md
  later 400
  run mailroom.sh supervise
  assert_has "$MR/codex/delivered/log.tsv" "thread-gamma--gamma-20261119T000001-aaaaa1--steer.md${TAB}t1-native${TAB}resolve${TAB}ok${TAB}-${TAB}late-receipt"
  assert_has "$MR/codex/delivered/log.tsv" "thread-gamma--gamma-20261119T000002-aaaaa2--steer.md${TAB}t3-cli-queue${TAB}resolve${TAB}accepted${TAB}-${TAB}unknown-absent"
  assert_eq "$(grep -c 'arg: queue' "$FAKE_LOG")" 1 "one escalation"
  assert_has "$FAKE_LOG" "Doorbell [thread-gamma--gamma-20261119T000002-aaaaa2--steer.md] (mailroom fallback after an unconfirmed send, queued)"
  assert_count "$MR/codex/.watcher/unknown" 0
  run mailroom.sh supervise
  assert_eq "$(grep -c 'arg: queue' "$FAKE_LOG")" 1 "never twice"
  # An escalation that is itself unconfirmed alarms and stops there.
  unknown_ring thread-gamma--gamma-20261119T000003-aaaaa3--steer.md
  FAKE_MODE=queue-ambiguous run mailroom.sh supervise
  assert_has "$MR/codex/delivered/log.tsv" "thread-gamma--gamma-20261119T000003-aaaaa3--steer.md${TAB}t3-cli-queue${TAB}resolve${TAB}unknown"
  assert_eq "$(notes_named mailroom-unknown-codex)" 1 "one alarm"
  FAKE_MODE=queue-ambiguous run mailroom.sh supervise
  assert_eq "$(grep -c 'arg: queue' "$FAKE_LOG")" 2 "no third queue"
  # A switched operator: absence on the old thread re-rings the new owner,
  # never the retired thread.
  unknown_ring thread-gamma--gamma-20261119T000004-aaaaa4--steer.md
  sed "s/thread-gamma${TAB}codex/thread-new${TAB}codex/" "$T/home/operators/REGISTRY.tsv" >"$T/r" && mv "$T/r" "$T/home/operators/REGISTRY.tsv"
  later 800
  run mailroom.sh supervise
  assert_has "$MR/codex/delivered/log.tsv" "thread-gamma--gamma-20261119T000004-aaaaa4--steer.md${TAB}none${TAB}resolve${TAB}ok${TAB}-${TAB}rerouted-absent"
  # (The fake clock makes the new ring old at once, so tier 3 sends it to
  # the new thread in the same pass.)
  assert_has "$MR/codex/delivered/log.tsv" "thread-new--gamma-"
  assert_lacks "$FAKE_LOG" "Doorbell [thread-gamma--gamma-20261119T000004-aaaaa4--steer.md] (mailroom fallback after an unconfirmed send"
  assert_has "$FAKE_LOG" "arg: thread-new"
  # An unreadable rollout is no evidence of absence: one alarm, no queue.
  rollout thread-locked
  chmod 000 "$ROLLOUT"
  unknown_ring thread-locked--gamma-20261119T000005-aaaaa5--steer.md
  n=$(grep -c 'arg: queue' "$FAKE_LOG")
  run mailroom.sh supervise
  chmod 600 "$ROLLOUT"
  assert_eq "$(grep -c 'arg: queue' "$FAKE_LOG")" "$n" "nothing sent on an unreadable record"
  assert_has "$T/state/mailroom.tsv" "thread-locked--gamma-20261119T000005-aaaaa5--steer.md${TAB}outcome unknown and the target's record is unreadable"
  # An escalation cut off mid-call is settled unknown, never sent again.
  mkdir -p "$MR/codex/.watcher/escalating"
  printf 'x\n' >"$MR/codex/.watcher/escalating/thread-gamma--gamma-20261119T000006-aaaaa6--steer.md"
  run mailroom.sh supervise
  assert_has "$MR/codex/delivered/log.tsv" "thread-gamma--gamma-20261119T000006-aaaaa6--steer.md${TAB}t3-cli-queue${TAB}resolve${TAB}unknown${TAB}-${TAB}escalation-interrupted"
  assert_eq "$(grep -c 'arg: queue' "$FAKE_LOG")" "$n" "no second escalation"
  assert_count "$MR/codex/.watcher/escalating" 0
  # Metrics count resolutions apart from deliveries.
  run mailroom.sh metrics 24
  assert_has "$T/out" "outcome unknown 5 (arrived late 1, escalated once absent 3)"
}

test_a_held_queue_ring_follows_a_switched_operator() {
  mr_setup
  mkdir -p "$MR/codex/.watcher/holding"
  live_pid
  printf '2026-11-19T00:00:00Z %s\n' "$LIVE" >"$MR/codex/.watcher/heartbeat"
  r=thread-gamma--gamma-20261119T000001-aaaaa1--queue.md
  printf 'relay-id: r1\n' >"$MR/codex/$r"
  date +%s >"$MR/codex/.watcher/holding/$r"
  run mailroom.sh supervise
  assert_file "$MR/codex/$r"
  sed "s/thread-gamma${TAB}codex/thread-new${TAB}codex/" "$T/home/operators/REGISTRY.tsv" >"$T/r" && mv "$T/r" "$T/home/operators/REGISTRY.tsv"
  run mailroom.sh supervise
  stop_live
  assert_no_file "$MR/codex/$r"
  assert_has "$MR/codex/delivered/log.tsv" "$r${TAB}none${TAB}rerouted${TAB}ok"
  ls "$MR/codex"/thread-new--gamma-*--queue.md >/dev/null 2>&1 || _fail "no ring for the new owner"
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

test_claimed_but_unfiled_claude_rings_fall_back_from_the_claim_time() {
  mr_setup
  note alpha a.md "x"
  run relay.sh
  r=$(rings claude)
  mkdir -p "$MR/claude/.watcher/handing"
  mv "$MR/claude/$r" "$MR/claude/.watcher/handing/$r"
  run mailroom.sh supervise
  assert_no_file "$FAKE_LOG"
  age_file "$MR/claude/.watcher/handing/$r" 200
  FAKE_MODE=sent run mailroom.sh supervise
  assert_rc 0
  assert_has "$FAKE_LOG" 'to "Alpha Op"'
  assert_has "$MR/claude/delivered/log.tsv" "$r${TAB}t3-headless${TAB}send${TAB}ok"
  assert_has "$MR/claude/delivered/log.tsv" "${TAB}bridge-stuck"
  assert_no_file "$MR/claude/.watcher/handing/$r"
}

test_a_fallback_follows_the_operator_to_its_current_owner() {
  mr_setup
  note alpha a.md "x"
  run relay.sh
  r=$(rings claude)
  age_file "$MR/claude/$r" 200
  # The operator moved to Codex meanwhile.
  sed "s/^alpha${TAB}Alpha Op${TAB}\([^${TAB}]*\)${TAB}sid-alpha/alpha${TAB}Alpha Op${TAB}\1${TAB}thread-alpha${TAB}codex/" \
    "$T/home/operators/REGISTRY.tsv" >"$T/reg" && mv "$T/reg" "$T/home/operators/REGISTRY.tsv"
  run mailroom.sh supervise
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  assert_has "$MR/claude/delivered/log.tsv" "$r${TAB}none${TAB}rerouted"
  case $(rings codex) in thread-alpha--alpha-*--queue.md) ;; *) _fail "no ring for the new owner" ;; esac
}

test_only_the_original_note_name_sets_steer() {
  mr_setup
  printf 'steering\tSteering Op\t%s\tthread-steer\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note steering plain.md "x"
  run relay.sh
  case $(rings codex) in *--queue.md) ;; *) _fail "the key made it steer: $(rings codex)" ;; esac
}

test_metrics_report_tier_share_and_percentiles() {
  mr_setup
  mkdir -p "$MR/codex/delivered" "$T/state"
  AO_NOW=$(date +%s)
  export AO_NOW
  : >"$MR/codex/delivered/log.tsv"
  for l in 100 200 300 400 500 600 700 800 900 1000; do
    printf 'x\t%s\tr%s--queue.md\tt1-native\tqueue\tok\t%s\t-\n' "$AO_NOW" "$l" "$l" >>"$MR/codex/delivered/log.tsv"
  done
  printf 'x\t%s\tc--queue.md\tt3-cli-queue\tqueue\taccepted\t200000\tsend-error\n' "$AO_NOW" >>"$MR/codex/delivered/log.tsv"
  printf 'x\t%s\techo--canary-1--queue.md\tt1-native\tcanary\tok\t5\t-\n' "$AO_NOW" >>"$MR/codex/delivered/log.tsv"
  run mailroom.sh metrics 1
  assert_has "$T/out" "Codex: rings 0; delivered 11: t1-native 91% (10; p50 0.6s, p90 0.9s), t2-bridge 0, t3-cli-queue 9% (1; p50 200.0s, p90 200.0s)"
}

test_codex_watcher_keeps_releases_across_a_restart() {
  has_node || return 0
  mr_setup
  mkdir -p "$MR/codex" "$T/busy"
  : >"$T/busy/thread-q"
  rollout thread-q
  watcher AO_MR_HOLD_CAP_MS=300
  put_ring thread-q--q-1--queue.md "never idle"
  wait_for 'grep -q queue-cap "$MR/codex/.watcher/log"'
  kill "$WPID"
  wait "$WPID"
  rm "$T/busy/thread-q"
  turn_complete
  watcher
  sleep 0.5
  kill "$WPID"
  wait "$WPID"
  assert_file "$MR/codex/thread-q--q-1--queue.md"
  assert_eq "$(grep -c send_message_to_thread "$T/app.log" 2>/dev/null)" 0 "released ring not taken up again"
}

test_arm_codex_holds_one_watcher_lock() {
  has_node || return 0
  mr_setup
  profile_set bridge_codex_node "$(command -v node)"
  profile_set bridge_codex_server "$TESTS_DIR/fakes/fake-app-tools.cjs"
  mkdir -p "$MR/codex"
  CODEX_THREAD_ID=thread-bridge FAKE_APP_LOG=$T/app.log \
    "$AO_TEST_SHELL" "$SCRIPTS/mailroom.sh" arm-codex </dev/null >"$T/a1" 2>&1 &
  first=$!
  wait_for 'grep -q armed "$T/a1"'
  rm -f "$MR/codex/.watcher/heartbeat"
  CODEX_THREAD_ID=thread-bridge run mailroom.sh arm-codex
  assert_rc 0
  assert_has "$T/out" "another watcher holds the lock"
  kill "$first"
  wait "$first" 2>/dev/null
}

test_an_unconfirmed_direct_queue_is_filed_unknown_not_resent() {
  mr_setup
  note gamma a.md "x"
  run relay.sh
  r=$(rings codex)
  age_file "$MR/codex/$r" 200
  FAKE_MODE=queue-ambiguous run mailroom.sh supervise
  assert_rc 1
  later 900
  FAKE_MODE=queue-ambiguous run mailroom.sh supervise
  assert_eq "$(grep -c '^== codex' "$FAKE_LOG")" 1 "queued once"
  assert_has "$MR/codex/delivered/log.tsv" "$r${TAB}t3-cli-queue${TAB}queue${TAB}unknown"
  assert_eq "$(notes_named mailroom-unknown-codex)" 1 "alarm"
}

test_failed_fallbacks_for_claimed_rings_keep_their_spacing() {
  mr_setup
  note alpha a.md "x"
  run relay.sh
  r=$(rings claude)
  mkdir -p "$MR/claude/.watcher/handing"
  mv "$MR/claude/$r" "$MR/claude/.watcher/handing/$r"
  age_file "$MR/claude/.watcher/handing/$r" 700
  FAKE_MODE=failed run mailroom.sh supervise
  FAKE_MODE=failed run mailroom.sh supervise
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 1 "one attempt, spaced"
  assert_eq "$(notes_named mailroom-ring-waiting)" 1 "one alarm"
  assert_file "$MR/claude/.watcher/handing/$r"
}

test_a_doorbell_is_never_rerouted_to_an_operator_named_doorbell() {
  mr_setup
  printf 'doorbell\tDoorbell Op\t%s\tsid-db\tclaude\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  run doorbell-claude.sh ring "Alpha Op" sid-alpha
  r=$(rings claude)
  age_file "$MR/claude/$r" 200
  FAKE_MODE=sent run mailroom.sh supervise
  assert_has "$FAKE_LOG" 'to "Alpha Op"'
  assert_lacks "$FAKE_LOG" 'Doorbell Op'
}

test_a_ring_for_an_operator_no_longer_registered_is_held() {
  mr_setup
  note gamma a.md "x"
  run relay.sh
  r=$(rings codex)
  age_file "$MR/codex/$r" 200
  grep -v "^gamma${TAB}" "$T/home/operators/REGISTRY.tsv" >"$T/reg" && mv "$T/reg" "$T/home/operators/REGISTRY.tsv"
  run mailroom.sh supervise
  assert_no_file "$FAKE_LOG"
  assert_file "$MR/codex/$r"
}

# ---------------------------------------------------------------- tier 1 (Claude socket)

has_kq() {
  [ -x /usr/bin/python3 ] && /usr/bin/python3 -c 'import select; select.kqueue' 2>/dev/null && return 0
  echo "    (skipped: no kqueue)"
  return 1
}

# peer SID MODE  A warm fake Claude session for SID: a session record, a
# peer key, a transcript and a socket served by fakes/fake-peer.py.
peer() {
  SOCKD=$(mktemp -d /tmp/aopeer.XXXXXX)
  _sock=$SOCKD/p.sock
  _cwd=$T/proj/warm
  mkdir -p "$_cwd" "$T/claude/sessions"
  TX=$T/claude/projects/$(printf '%s' "$_cwd" | sed 's/[^A-Za-z0-9]/-/g')/00000000-0000-4000-8000-000000000001.jsonl
  mkdir -p "${TX%/*}"
  : >"$TX"
  /usr/bin/python3 -I "$TESTS_DIR/fakes/fake-peer.py" "$_sock" t0ken-secret "$TX" "$2" </dev/null >/dev/null 2>&1 &
  PEER=$!
  wait_for '[ -S "$_sock" ]'
  _h=$(/usr/bin/python3 -I -c 'import hashlib, os, sys; print(hashlib.sha256(os.path.abspath(sys.argv[1]).encode()).hexdigest())' "$_sock")
  printf '{"peerToken":"t0ken-secret"}\n' >"$T/claude/sessions/$PEER.$_h.key"
  printf '{"pid":%s,"hostSessionId":"%s","sessionId":"00000000-0000-4000-8000-000000000001","cwd":"%s","messagingSocketPath":"%s","peerProtocol":1,"version":"9.9.9"}\n' \
    "$PEER" "$1" "$_cwd" "$_sock" >"$T/claude/sessions/$PEER.json"
}
stop_peer() { kill "$PEER" 2>/dev/null; wait "$PEER" 2>/dev/null; rm -rf "$SOCKD"; }
t1_setup() {
  mr_setup
  bridge_rows
  profile_set bridge_claude_t1 socket
  printf 'warm\tWarm Op\t%s\tlocal_w1\tclaude\n' "$T/proj/warm" >>"$T/home/operators/REGISTRY.tsv"
  mkdir -p "$MR/claude"
}
start_wait() {
  env AO_MR_T1_CONFIRM_S="${1:-3}" AO_MR_T1_RATE=0,100 "$AO_TEST_SHELL" "$SCRIPTS/mailroom.sh" wait claude </dev/null >"$T/wout" 2>"$T/werr" &
  W=$!
  wait_for '[ "$(cat "$MR/claude/.watcher/pid" 2>/dev/null)" = "$W" ]' 100
}

test_claude_t1_delivers_to_a_warm_session_and_hands_misses_to_the_bridge() {
  has_kq || return 0
  t1_setup
  peer local_w1 ok
  start_wait
  note warm a.md "x"
  run relay.sh
  r=$(rings claude)
  wait_for 'grep -q "$r" "$MR/claude/delivered/log.tsv"' 100
  assert_has "$MR/claude/delivered/log.tsv" "$r${TAB}t1-socket${TAB}send${TAB}ok${TAB}"
  kill -0 "$W" 2>/dev/null || _fail "the watcher stopped after a tier-1 delivery"
  assert_has "$TX" '"operation": "enqueue"'
  assert_has "$TX" "Doorbell [$r]"
  assert_has "$TX.log" '"auth_ok": true'
  assert_lacks "$MR/claude/.watcher/log" "t0ken-secret"
  assert_lacks "$T/wout" "t0ken-secret"
  # A cold target (no live session record) goes to the bridge model, with the step.
  note alpha b.md "y"
  later 2
  run relay.sh
  r2=$(rings claude)
  wait_for '! kill -0 "$W" 2>/dev/null' 100
  wait "$W"
  assert_has "$T/wout" "=== $r2"
  assert_file "$MR/claude/.watcher/handing/$r2"
  run mailroom.sh file claude "$r2"
  assert_rc 0
  assert_has "$MR/claude/delivered/log.tsv" "$r2${TAB}t2-bridge${TAB}send${TAB}ok${TAB}"
  assert_has "$MR/claude/delivered/log.tsv" "${TAB}cold-target"
  # The kill switch sends everything to the bridge model.
  touch "$MR/claude/.watcher/t1-off"
  start_wait
  note warm c.md "z"
  later 4
  run relay.sh
  wait_for '! kill -0 "$W" 2>/dev/null' 100
  wait "$W"
  stop_peer
  r3=$(sed -n 's/^=== //p' "$T/wout")
  assert_eq "$(sed -n 1p "$MR/claude/.watcher/meta/$r3" | cut -f 2)" kill-switch "miss step"
  assert_eq "$(grep -c '"auth_ok"' "$TX.log")" 1 "no send with the kill switch on"
}

test_claude_t1_without_a_receipt_is_a_miss_and_never_counts_a_mention() {
  has_kq || return 0
  t1_setup
  peer local_w1 mention
  start_wait 1
  note warm a.md "x"
  run relay.sh
  r=$(rings claude)
  wait_for '! kill -0 "$W" 2>/dev/null' 100
  wait "$W"
  stop_peer
  assert_has "$T/wout" "=== $r"
  assert_eq "$(cut -f 2 "$MR/claude/.watcher/meta/$r")" no-receipt "miss step"
  assert_no_file "$MR/claude/.watcher/t1/$r.tx"
  run mailroom.sh file claude "$r"
  assert_has "$MR/claude/delivered/log.tsv" "${TAB}no-receipt"
}

test_a_tier1_claim_a_dead_watcher_left_is_filed_on_a_receipt_else_returned() {
  has_kq || return 0
  t1_setup
  mkdir -p "$MR/claude/.watcher/t1"
  tx=$T/tx.jsonl
  printf '{"type":"queue-operation","operation":"enqueue","content":"<cross-session-message>\\nDoorbell [local_w1--warm-1.md]: x\\n</cross-session-message>"}\n' >"$tx"
  printf 'x\n' >"$MR/claude/.watcher/t1/local_w1--warm-1.md"
  printf '%s\n' "$tx" >"$MR/claude/.watcher/t1/local_w1--warm-1.md.tx"
  printf 'y\n' >"$MR/claude/.watcher/t1/local_w1--warm-2.md"
  printf '%s\n' "$tx" >"$MR/claude/.watcher/t1/local_w1--warm-2.md.tx"
  run mailroom.sh supervise
  assert_has "$MR/claude/delivered/log.tsv" "local_w1--warm-1.md${TAB}t1-socket${TAB}send${TAB}ok"
  assert_file "$MR/claude/local_w1--warm-2.md"
  assert_no_file "$MR/claude/.watcher/t1/local_w1--warm-2.md.tx"
  assert_has "$T/state/mailroom.tsv" "${TAB}t1-returned${TAB}claude"
  # A transcript that cannot be read is no evidence of absence: kept, one
  # alarm, never back in the queue.
  printf 'z\n' >"$MR/claude/.watcher/t1/local_w1--warm-3.md"
  printf '%s\n' "$T/gone.jsonl" >"$MR/claude/.watcher/t1/local_w1--warm-3.md.tx"
  run mailroom.sh supervise
  assert_file "$MR/claude/.watcher/t1/local_w1--warm-3.md"
  assert_no_file "$MR/claude/local_w1--warm-3.md"
  assert_eq "$(notes_named mailroom-unknown-claude)" 1 "one alarm"
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-unknown-claude)" 1 "still one alarm"
}

# ---------------------------------------------------------------- degradation reporting

# codex_up  A live Codex watcher (heartbeat, log, fingerprint FP).
codex_up() {
  mkdir -p "$MR/codex/.watcher"
  live_pid
  printf '2026-11-19T00:00:00Z %s\n' "$LIVE" >"$MR/codex/.watcher/heartbeat"
  : >"$MR/codex/.watcher/log"
  printf '%s\n' "$1" >"$MR/codex/.watcher/fingerprint"
}
codex_bridge_row() { printf 'mailroom-codex\tMailroom\t%s\tthread-bridge\tcodex\n' "$T/user" >>"$T/home/operators/REGISTRY.tsv"; }

test_a_version_change_sends_one_canary_and_a_failed_canary_alarms_once() {
  mr_setup
  codex_bridge_row
  codex_up "tools=aaa server=x-1"
  run mailroom.sh supervise
  assert_rc 0
  c=$(rings codex)
  case $c in echo--canary-*--queue.md) ;; *) _fail "no canary: $c" ;; esac
  assert_has "$T/state/mailroom-versions.tsv" "${TAB}codex${TAB}none${TAB}tools=aaa server=x-1"
  run mailroom.sh supervise
  assert_eq "$(rings codex | grep -c canary)" 1 "one canary"
  # The watcher files it from tier 1: confirmed, no alarm.
  mkdir -p "$MR/codex/delivered"
  mv "$MR/codex/$c" "$MR/codex/delivered/$c"
  printf 'x\t%s\t%s\tt1-native\tcanary\tok\t5\t-\n' "$(date +%s)" "$c" >>"$MR/codex/delivered/log.tsv"
  run mailroom.sh supervise
  assert_has "$T/state/mailroom.tsv" "${TAB}canary-ok${TAB}codex"
  # A new version whose canary is never filed: one alarm, flagged as degraded.
  printf 'tools=bbb server=x-2\n' >"$MR/codex/.watcher/fingerprint"
  run mailroom.sh supervise
  assert_eq "$(rings codex | grep -c canary)" 1 "a canary for the new version"
  printf '2099-01-01T00:00:00Z %s\n' "$LIVE" >"$MR/codex/.watcher/heartbeat"
  later 700
  touch -t 209901010000 "$MR/codex/.watcher/heartbeat"
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-degraded-codex)" 1 "canary alarm"
  assert_has "$(ls "$T/home/inbox/oracle"/*mailroom-degraded-codex*)" "slower tiers, with higher latency"
  later 1400
  run mailroom.sh supervise
  stop_live
  assert_eq "$(notes_named mailroom-degraded-codex)" 1 "once per cause"
}

test_two_first_tier_misses_alarm_once_and_a_first_tier_delivery_clears_it() {
  mr_setup
  mkdir -p "$MR/codex/delivered"
  now=$(date +%s)
  row() { printf 'x\t%s\t%s--queue.md\t%s\tqueue\t%s\t1000\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$MR/codex/delivered/log.tsv"; }
  row "$now" a t1-native ok -
  row "$now" b t3-cli-queue accepted queue-cap
  row "$now" c t3-cli-queue accepted queue-cap
  later 0
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-degraded-codex)" 0 "a busy target is not a failure"
  row "$now" d t3-cli-queue accepted send-error
  row "$now" e t3-cli-queue accepted send-error
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-degraded-codex)" 1 "degraded"
  assert_has "$(ls "$T/home/inbox/oracle"/*mailroom-degraded-codex*)" "at step send-error"
  run mailroom.sh status
  assert_has "$T/out" "first tier t1-native (degraded send-error)"
  later 60
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-degraded-codex)" 1 "once"
  row $((now + 120)) f t1-native ok -
  later 120
  run mailroom.sh supervise
  assert_has "$T/state/mailroom.tsv" "${TAB}first-tier-ok${TAB}codex"
  row $((now + 180)) g t3-cli-queue accepted send-error
  row $((now + 180)) h t3-cli-queue accepted send-error
  later 200
  run mailroom.sh supervise
  assert_eq "$(notes_named mailroom-degraded-codex)" 2 "the same cause alarms again after a recovery"
}

test_tier4_pushes_the_owner_once_when_the_oracle_does_not_receive_an_alarm() {
  mr_setup
  mkdir -p "$T/home/hooks" "$T/state/mailroom/alarm-pending"
  printf '#!/bin/sh\nprintf "push: %%s\\n" "$1" >>"%s/push.log"\n' "$T" >"$T/home/hooks/push"
  chmod +x "$T/home/hooks/push"
  later 0
  printf '%s 20261119T000000-mailroom-bridge-down-claude.md\n' "$((AO_NOW - 1000))" >"$T/state/mailroom/alarm-pending/mailroom-bridge-down-claude"
  run mailroom.sh supervise
  assert_has "$T/push.log" "the Oracle has not received an alarm for 15+ minutes"
  later 60
  run mailroom.sh supervise
  assert_eq "$(grep -c push: "$T/push.log")" 1 "once per outage"
  # An unrelated ring to the Oracle, or one only accepted, settles nothing.
  mkdir -p "$MR/claude/delivered"
  printf -- '- 20261119T000001-oracle-20261119T000001-other-note.md\nrelay-id: oracle-1\n' >"$MR/claude/delivered/sid-oracle--oracle-20261119T000001-aaaaaa.md"
  printf 'x\t%s\tsid-oracle--oracle-20261119T000001-aaaaaa.md\tt2-bridge\tsend\tok\t1\t-\n' "$AO_NOW" >>"$MR/claude/delivered/log.tsv"
  printf -- '- 20261119T000002-oracle-20261119T000000-mailroom-bridge-down-claude.md\n' >"$MR/claude/delivered/sid-oracle--oracle-20261119T000002-bbbbbb.md"
  printf 'x\t%s\tsid-oracle--oracle-20261119T000002-bbbbbb.md\tt3-cli-queue\tqueue\taccepted\t1\t-\n' "$AO_NOW" >>"$MR/claude/delivered/log.tsv"
  later 90
  run mailroom.sh supervise
  assert_file "$T/state/mailroom/alarm-pending/mailroom-bridge-down-claude"
  # The ring that lists the alarm note is delivered: the outage closes.
  printf -- '- 20261119T000003-oracle-20261119T000000-mailroom-bridge-down-claude.md\nrelay-id: oracle-3\n' >"$MR/claude/delivered/sid-oracle--oracle-20261119T000003-abcdef.md"
  printf 'x\t%s\tsid-oracle--oracle-20261119T000003-abcdef.md\tt2-bridge\tsend\tok\t1\t-\n' "$AO_NOW" >>"$MR/claude/delivered/log.tsv"
  later 120
  run mailroom.sh supervise
  assert_no_file "$T/state/mailroom/alarm-pending/mailroom-bridge-down-claude"
  assert_has "$T/state/mailroom.tsv" "${TAB}outage-closed${TAB}"
}

test_a_claude_app_restart_wakes_the_bridge_then_returns_to_the_oracle() {
  mr_setup
  printf 'mailroom-claude\tMailroom\t%s\tsid-bridge\tclaude\n' "$T/user" >>"$T/home/operators/REGISTRY.tsv"
  profile_set wake_link 'exampleapp://session/{session}'
  later 0
  FAKE_MODE=sent run mailroom.sh supervise
  assert_rc 0
  b=$(grep -n 'arg: exampleapp://session/sid-bridge' "$FAKE_LOG" | cut -d: -f1)
  o=$(grep -n 'arg: exampleapp://session/sid-oracle' "$FAKE_LOG" | cut -d: -f1)
  [ -n "$b" ] && [ -n "$o" ] && [ "$b" -lt "$o" ] || _fail "expected the bridge link, then the Oracle's (bridge line ${b:-none}, oracle line ${o:-none})"
  assert_has "$FAKE_LOG" 'to "Mailroom"'
  assert_has "$FAKE_LOG" 'Re-arm'
}

ao_test_main "$0"
