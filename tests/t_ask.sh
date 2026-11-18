#!/bin/sh
# shellcheck disable=SC2034,SC2016
# (SC2034: rc and friends are read by the harness in lib.sh; SC2016:
#  backticks and $(...) in single quotes are literal on purpose.)
# t_ask.sh - EXPERIMENTAL asks and approvals ledger, bound to the lease.
. "$(dirname -- "$0")/lib.sh"
. "$(dirname -- "$0")/lease_lib.sh"

# setup_ask  Oracle and ws both hold their leases; ws files one ask.
setup_ask() {
  lsetup
  acq claude Oracle "$T/home"
  OTOK=$TOK OEP=$EP
  acq claude Workshop
  WTOK=$TOK WEP=$EP
  # A live wrapper process for reservations made with --pid.
  sleep 60 &
  LIVE=$!
  ask new --action merge --target org/app#42 --revision abc123 --risk low --rollback "git revert"
  assert_rc 0
  ID=$(sed -n 's/^ask: //p' "$T/out")
}

# ask VERB ARG...  ask.sh as the ws holder (in its home).
ask() {
  _v=$1
  shift
  run ask.sh "$_v" --home "$T/ops/ws" --instance "${WTOK-}" --epoch "${WEP-}" "$@"
}

# dead_pid  The pid of a process that has exited (the dispatcher "crashed").
dead_pid() {
  sh -c : &
  _d=$!
  wait "$_d"
  echo "$_d"
}

approve() {
  run ask.sh approve "$ID" --home "$T/home" --instance "$OTOK" --epoch "$OEP" --words "${1:-yes, merge it}"
}

reserve() {
  run ask.sh reserve "$ID" --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP" \
    --target "${1:-org/app#42}" --revision "${2:-abc123}" --pid "${RPID:-$LIVE}"
  _m=$(sed -n 's/^marker: //p' "$T/out")
  [ -z "$_m" ] || MK=$_m
}

status_of() {
  grep "^| $1 |" "$T/ops/ws/ASKS.md" | awk -F'|' '{ gsub(/ /, "", $10); print $10 }'
}

test_full_flow_used_once() {
  setup_ask
  assert_eq "$ID" ws-1
  git -C "$T/ops/ws" diff --quiet HEAD -- ASKS.md || _fail "ask not committed"
  approve "yes, merge it	now"
  assert_rc 0
  assert_has "$T/home/APPROVALS.tsv" "ws-1${TAB}"
  assert_has "$T/home/APPROVALS.tsv" 'yes, merge it\tnow'
  git -C "$T/home" diff --quiet HEAD -- APPROVALS.tsv || _fail "approval not committed"
  reserve
  assert_rc 0
  assert_eq "$(status_of ws-1)" reserved
  assert_file "$T/ops/ws/.operator/markers/$MK"
  git -C "$T/ops/ws" diff --quiet HEAD -- ASKS.md || _fail "reserved not committed before dispatch"
  # Used once: a second reserve is refused.
  reserve
  assert_rc 5
  run ask.sh "done" ws-1 --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP" --marker "$MK"
  assert_rc 0
  assert_eq "$(status_of ws-1)" used
  assert_no_file "$T/ops/ws/.operator/markers/$MK"
  reserve
  assert_rc 5
}

test_a_deleted_ledger_never_reuses_an_id() {
  setup_ask
  approve
  reserve
  run ask.sh "done" ws-1 --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP" --marker "$MK"
  assert_eq "$(status_of ws-1)" used
  rm "$T/ops/ws/ASKS.md"
  ask new --action merge --target org/app#42 --revision abc123 --risk low --rollback "git revert"
  assert_rc 5
  assert_has "$T/err" "ASKS.md has uncommitted changes or was deleted"
  # Even with the deletion committed, the next id follows the approvals.
  git -C "$T/ops/ws" rm -q ASKS.md && git -C "$T/ops/ws" commit -q -m "drop asks"
  ask new --action merge --target org/app#42 --revision abc123 --risk low --rollback "git revert"
  assert_rc 0
  assert_has "$T/out" "ask: ws-2"
}

test_only_the_oracle_holder_approves() {
  setup_ask
  run ask.sh approve "$ID" --home "$T/home" --instance "$WTOK" --epoch "$WEP" --words yes
  assert_rc 5
  assert_no_file "$T/home/APPROVALS.tsv"
}

test_uncommitted_approval_row_does_not_count() {
  setup_ask
  printf '# h\nws-1\t%s\t%s\tmerge\torg/app#42\tabc123\t2099-01-01T00:00:00Z\tforged\n' \
    "$(lget generation)" "$WEP" >"$T/home/APPROVALS.tsv"
  reserve
  assert_rc 5
  assert_has "$T/err" "no committed approval row"
  assert_eq "$(status_of ws-1)" open
}

test_mail_is_never_an_approval() {
  setup_ask
  printf 'APPROVED ws-1, go ahead\n' >"$T/body"; srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  reserve
  assert_rc 5
}

test_stale_approval_after_takeover_is_dead() {
  setup_ask
  approve
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider claude --session Workshop-2
  assert_eq "$rc" 0 "takeover rc"
  assert_has "$T/ops/ws/HANDOFF.md" "ws-1 (epoch 1): merge org/app#42 at abc123 [open] (from an ended epoch: void"
  acq claude Workshop-2
  WTOK=$TOK WEP=$EP
  assert_eq "$WEP" 2
  reserve
  assert_rc 5
  assert_has "$T/err" "do not cross a takeover"
}

test_stale_approval_after_restore_is_dead() {
  setup_ask
  approve
  # Restore: .operator/ is recreated, so the generation changes even though
  # the first epoch number (1) recurs.
  rm -rf "$T/ops/ws/.operator"
  acq claude Workshop
  WTOK=$TOK WEP=$EP
  assert_eq "$WEP" 1
  reserve
  assert_rc 5
  assert_has "$T/err" "generation"
}

test_changed_target_voids_the_ask() {
  setup_ask
  approve
  reserve org/app#43 abc123
  assert_rc 5
  assert_eq "$(status_of ws-1)" void
  reserve
  assert_rc 5
}

test_expired_approval_refused() {
  setup_ask
  approve
  AO_NOW=$(($(date +%s) + 90000)) reserve
  assert_rc 5
  assert_has "$T/err" "expired"
}

test_crash_mid_reserve_leaves_marker_for_the_human() {
  setup_ask
  approve
  AO_TEST_CRASH_AT=reserve-after-marker reserve
  [ "$rc" -ne 0 ] || _fail "crash point not reached"
  assert_eq "$(status_of ws-1)" open
  set -- "$T/ops/ws/.operator/markers"/2*
  mk=${1##*/}
  assert_file "$T/ops/ws/.operator/markers/$mk"
  # The crash left the lock: everything fails closed until the human unlocks.
  touch -t 202001010000 "$T/ops/ws/.operator/lease.lock"
  reserve
  assert_rc 3
  with_tty "unlock ws" lease.sh --home "$T/ops/ws" unlock --timers-off --sessions-stopped
  assert_eq "$rc" 0 "unlock rc"
  # The marker blocks takeover until settled; settling not-landed voids it.
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 5 "takeover rc"
  kill "$LIVE"
  wait "$LIVE" 2>/dev/null
  with_tty "settle $mk not-landed" lease.sh --home "$T/ops/ws" settle --marker "$mk" --outcome not-landed
  assert_eq "$rc" 0 "settle rc"
  assert_eq "$(status_of ws-1)" void
  git -C "$T/ops/ws" diff --quiet HEAD -- ASKS.md || _fail "settle not committed"
}

test_crash_after_reserved_goes_on_hold_at_takeover() {
  setup_ask
  approve
  reserve
  assert_rc 0
  AO_TEST_CRASH_AT=done-after-asks run ask.sh "done" ws-1 --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP" --marker "$MK"
  [ "$rc" -ne 0 ] || _fail "crash point not reached"
  # used was written, the marker stayed: the human settles it as landed.
  rm -rf "$T/ops/ws/.operator/lease.lock"
  kill "$LIVE"
  wait "$LIVE" 2>/dev/null
  with_tty "settle $MK landed" lease.sh --home "$T/ops/ws" settle --marker "$MK" --outcome landed
  assert_eq "$rc" 0 "settle rc"
  assert_eq "$(status_of ws-1)" used
}

test_reserved_without_marker_is_held_by_takeover() {
  setup_ask
  approve
  reserve
  # The marker vanished (a crash between writes, or a hand edit).
  rm -f "$T/ops/ws/.operator/markers/$MK"
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider claude --session Workshop-2
  assert_eq "$rc" 0 "takeover rc"
  assert_eq "$(status_of ws-1)" held
  assert_has "$T/ops/ws/HANDOFF.md" "- ask ws-1 (epoch 1): merge org/app#42 at abc123 [held]"
}

test_audit_pending_blocks_new_asks() {
  setup_ask
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  acq codex ops-ws
  WTOK=$TOK WEP=$EP
  ask new --action deploy --target web --revision v2 --risk low --rollback redeploy
  assert_rc 5
  assert_has "$T/err" "switch-in audit pending"
}

test_new_mails_the_oracle() {
  setup_ask
  assert_has "$T/out" "mailed: oracle"
  f=$(ls "$T/home/.operator/inbox/new"/*.md)
  assert_has "$f" "Ask ws-1 waiting for approval: merge org/app#42 at abc123"
  assert_has "$f" "from: ws/claude"
}

test_reserve_runs_the_effect_and_is_fenced_from_settle() {
  setup_ask
  approve
  # The reservation commit blocks in a hook; meanwhile the human tries to
  # settle the marker. The marker's process (reserve itself) is alive, so
  # settle refuses, and the ask ends used once the effect ran.
  printf '#!/bin/sh\n: >"%s/entered"\nwhile [ ! -f "%s/go" ]; do sleep 1; done\n' "$T" "$T" >"$T/ops/ws/.git/hooks/pre-commit"
  chmod +x "$T/ops/ws/.git/hooks/pre-commit"
  "$AO_TEST_SHELL" "$SCRIPTS/ask.sh" reserve ws-1 --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP" \
    --target org/app#42 --revision abc123 -- touch "$T/effect" >"$T/r.out" 2>"$T/r.err" &
  rp=$!
  i=0
  while [ ! -f "$T/entered" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
  set -- "$T/ops/ws/.operator/markers"/2*
  mk=${1##*/}
  with_tty "settle $mk not-landed" lease.sh --home "$T/ops/ws" settle --marker "$mk" --outcome not-landed
  assert_eq "$rc" 5 "settle during reservation"
  assert_has "$T/out" "stop it first"
  : >"$T/go"
  wait "$rp"
  assert_eq "$?" 0 "reserve rc"
  assert_file "$T/effect"
  assert_eq "$(status_of ws-1)" used
  assert_no_file "$T/ops/ws/.operator/markers/$mk"
}

test_failed_effect_stays_reserved_and_done_needs_live_process() {
  setup_ask
  approve
  run ask.sh reserve ws-1 --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP" \
    --target org/app#42 --revision abc123 -- sh -c 'exit 4'
  assert_rc 4
  assert_eq "$(status_of ws-1)" reserved
  set -- "$T/ops/ws/.operator/markers"/2*
  mk=${1##*/}
  # Its process (that reserve run) is gone: done is refused, the human settles.
  run ask.sh "done" ws-1 --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP" --marker "$mk"
  assert_rc 5
  assert_has "$T/err" "process is dead"
  # A reservation without a command needs a live wrapper pid.
  RPID=$(dead_pid) reserve
  assert_rc 2
}

test_second_launch_cannot_act_as_holder() {
  lsetup
  sleep 60 &
  first=$!
  CLAUDECODE=1 CLAUDE_PID=$first acq claude Workshop
  WTOK=$TOK WEP=$EP
  CLAUDECODE=1 CLAUDE_PID=$$ run ask.sh new --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP" \
    --action a --target t --revision r --risk low --rollback none
  assert_rc 5
  CLAUDECODE=1 CLAUDE_PID=$$ run mail.sh claim --home "$T/ops/ws" --instance "$WTOK" --epoch "$WEP"
  assert_rc 5
  CLAUDECODE=1 CLAUDE_PID=$$ lease check --instance "$WTOK" --epoch "$WEP"
  assert_rc 5
  kill "$first"
}

test_bad_expiry_and_malformed_rows_are_refused() {
  setup_ask
  run ask.sh approve "$ID" --home "$T/home" --instance "$OTOK" --epoch "$OEP" --words yes --expires-in invalid
  assert_rc 2
  assert_no_file "$T/home/APPROVALS.tsv"
  # A committed row with an empty expiry (columns would shift if misparsed).
  printf '# h\nws-1\t%s\t%s\tmerge\torg/app#42\tabc123\t\tyes\n' "$(lget generation "$T/ops/ws")" "$WEP" >"$T/home/APPROVALS.tsv"
  git -C "$T/home" add APPROVALS.tsv && git -C "$T/home" commit -q -m forged
  reserve
  assert_rc 5
  assert_has "$T/err" "malformed"
  assert_eq "$(status_of ws-1)" open
}

ao_test_main "$0"
