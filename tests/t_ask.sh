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
    --target "${1:-org/app#42}" --revision "${2:-abc123}" --pid "$(dead_pid)"
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

ao_test_main "$0"
