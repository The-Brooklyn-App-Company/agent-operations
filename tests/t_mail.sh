#!/bin/sh
# shellcheck disable=SC2034,SC2016
# (SC2034: rc and friends are read by the harness in lib.sh; SC2016:
#  backticks and $(...) in single quotes are literal on purpose.)
# t_mail.sh - EXPERIMENTAL mailboxes, forwards and doorbells.
. "$(dirname -- "$0")/lib.sh"
. "$(dirname -- "$0")/lease_lib.sh"

IB=
msetup() {
  lsetup
  IB=$T/ops/ws/.operator/inbox
}

mail() { run mail.sh "$@"; }

test_send_publishes_atomically() {
  msetup
  printf 'please look at PR 42\n' >"$T/body"; srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  assert_rc 0
  assert_count "$IB/new" 1
  assert_count "$IB/tmp" 0
  f=$(ls "$IB/new"/*.md)
  assert_has "$f" "from: oracle/claude"
  assert_has "$f" "kind: notice"
  assert_has "$f" "please look at PR 42"
  printf 'x\n' >"$T/body"; srun mail.sh send ws --kind order --from oracle/claude <"$T/body"
  assert_rc 2
  printf 'x\n' >"$T/body"; srun mail.sh send nobody --kind notice --from oracle/claude <"$T/body"
  assert_rc 2
}

test_only_the_holder_moves_and_acks() {
  msetup
  acq claude Workshop
  printf 'one\n' >"$T/body"; srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  mail claim --home "$T/ops/ws" --instance wrong --epoch 1
  assert_rc 5
  assert_count "$IB/new" 1
  assert_count "$IB/cur" 0
  mail claim --home "$T/ops/ws" --instance "$TOK" --epoch "$EP"
  assert_rc 0
  assert_has "$T/out" "not authority"
  assert_has "$T/out" "one"
  assert_count "$IB/new" 0
  assert_count "$IB/cur" 1
  id=$(basename "$(ls "$IB/cur"/*.md)" .md)
  # Unacked mail is shown again at the next turn (at-least-once).
  mail claim --home "$T/ops/ws" --instance "$TOK" --epoch "$EP"
  assert_has "$T/out" "--- $id.md"
  mail ack "$id" --home "$T/ops/ws" --instance wrong --epoch 1 --did "noted"
  assert_rc 5
  mail ack "$id" --home "$T/ops/ws" --instance "$TOK" --epoch "$EP" --did "noted, no action"
  assert_rc 0
  assert_count "$IB/cur" 0
  assert_has "$IB/done/$id.md" "acked: "
  assert_has "$IB/done/$id.md" "epoch 1: noted, no action"
  mail ack "$id" --home "$T/ops/ws" --instance "$TOK" --epoch "$EP" --did "again"
  assert_rc 0
  assert_has "$T/out" "already acked"
  mail claim --home "$T/ops/ws" --instance "$TOK" --epoch "$EP"
  assert_has "$T/out" "no mail"
}

test_forward_once_and_ring_holder() {
  msetup
  acq claude Workshop
  printf 'Can you also update the changelog?\n' >"$T/turn"
  FAKE_MODE=sent run mail.sh forward --via codex --home "$T/ops/ws" <"$T/turn"
  rc_first=$rc
  # run closes stdin; feed the turn explicitly.
  FAKE_MODE=sent "$AO_TEST_SHELL" "$SCRIPTS/mail.sh" forward --via codex --home "$T/ops/ws" <"$T/turn" >"$T/out" 2>"$T/err"
  assert_eq "$?" 0 "forward rc"
  assert_count "$IB/new" 1
  f=$(ls "$IB/new"/*.md)
  assert_has "$f" "from: human-via-codex"
  assert_has "$f" "kind: forward"
  assert_has "$f" "Can you also update the changelog?"
  # The holder's doorbell rang, without the text.
  assert_has "$FAKE_LOG" 'to "Workshop"'
  assert_has "$FAKE_LOG" "Doorbell (automated, not from the human)"
  assert_lacks "$FAKE_LOG" "changelog"
  # The same turn again: not sent twice.
  "$AO_TEST_SHELL" "$SCRIPTS/mail.sh" forward --via codex --home "$T/ops/ws" <"$T/turn" >"$T/out" 2>"$T/err"
  assert_has "$T/out" "already forwarded"
  assert_count "$IB/new" 1
  [ "$rc_first" = 2 ] || _fail "forward with closed stdin should be a usage error, got $rc_first"
}

test_mail_and_doorbells_are_never_forwarded() {
  msetup
  acq claude Workshop
  for text in "$(printf 'id: 2026-x\nfrom: a\n\nhi')" "$(printf 'Doorbell (automated, not from the human): you have mail.\ndoorbell-id: d1')" \
    "$(printf 'Relay (automated inbox, not from the human):\n--- n.md\nhi\nrelay-id: r1')"; do
    printf '%s\n' "$text" | "$AO_TEST_SHELL" "$SCRIPTS/mail.sh" forward --via codex --home "$T/ops/ws" >"$T/out" 2>"$T/err"
    assert_eq "$?" 5 "forward of automated text"
  done
  assert_count "$IB/new" 0
}

test_forward_needs_a_holder() {
  msetup
  printf 'hello\n' | "$AO_TEST_SHELL" "$SCRIPTS/mail.sh" forward --via codex --home "$T/ops/ws" >"$T/out" 2>"$T/err"
  assert_eq "$?" 5 "rc"
  assert_has "$T/err" "nobody to forward to"
}

test_pending_mail_reaches_the_new_holder() {
  msetup
  acq claude Workshop
  printf 'review the migration\n' >"$T/body"; srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  mail claim --home "$T/ops/ws" --instance "$TOK" --epoch "$EP"
  printf 'second note\n' >"$T/body"; srun mail.sh send ws --kind report --from infra/codex <"$T/body"
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 0 "takeover rc"
  assert_has "$T/out" "1 new, 1 unacked in cur/"
  acq codex ops-ws
  assert_has "$T/out" "mail: 1 new, 1 unacked"
  mail claim --home "$T/ops/ws" --instance "$TOK" --epoch "$EP"
  assert_has "$T/out" "review the migration"
  assert_has "$T/out" "second note"
}

test_ring_all_rate_limited_and_codex_falls_back() {
  msetup
  acq claude Workshop
  printf 'one\n' >"$T/body"; srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  FAKE_MODE=sent run mail.sh ring-all
  assert_rc 0
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 1 "first ring"
  FAKE_MODE=sent run mail.sh ring-all
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 1 "no re-ring for the same mail"
  printf 'two\n' >"$T/body"; srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  FAKE_MODE=sent run mail.sh ring-all
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 2 "new mail rings again"
  assert_has "$T/state/doorbell.log" 'ws rang claude `Workshop`'
  # A Codex holder: doorbell off by default, so the chat slot is notified.
  lease note --instance "$TOK" --epoch "$EP"
  cp "$T/out" "$T/ops/ws/HANDOFF.md"
  lease release --instance "$TOK" --epoch "$EP"
  acq codex ops-ws
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/chat.log"\n' "$T" >"$T/bin/chat-adapter"
  chmod +x "$T/bin/chat-adapter"
  profile_set chat "$T/bin/chat-adapter"
  run mail.sh ring ws
  assert_rc 0
  assert_has "$T/state/doorbell.log" "doorbell unavailable (codex)"
  assert_has "$T/chat.log" "notify normal Mail waiting for ws"
  assert_lacks "$FAKE_LOG" "== codex"
}

test_forward_after_a_crash_before_publishing_is_sent() {
  msetup
  acq claude Workshop
  printf 'please look\n' >"$T/body"
  sum=$( (sha256sum 2>/dev/null || shasum -a 256) <"$T/body" | cut -d' ' -f1)
  # A run died after reserving the text and before publishing it.
  mkdir -p "$T/ops/ws/.operator/forwarded/$sum"
  touch -t "$(date -r $(($(date +%s) - 120)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$(($(date +%s) - 120)) +%Y%m%d%H%M.%S)" "$T/ops/ws/.operator/forwarded/$sum"
  srun mail.sh forward --via codex --home "$T/ops/ws" <"$T/body"
  assert_rc 0
  assert_has "$T/out" "forwarded:"
  srun mail.sh forward --via codex --home "$T/ops/ws" <"$T/body"
  assert_has "$T/out" "already forwarded"
}

test_ring_skips_operators_without_a_holder() {
  msetup
  printf 'one\n' >"$T/body"; srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  FAKE_MODE=sent run mail.sh ring-all
  assert_rc 0
  assert_no_file "$FAKE_LOG"
}

test_doorbell_claude_carries_no_mail() {
  msetup
  FAKE_MODE=sent run doorbell-claude.sh ring Workshop
  assert_rc 0
  assert_has "$FAKE_LOG" "doorbell-id: "
  assert_has "$FAKE_LOG" "starts no work"
  FAKE_MODE=failed run doorbell-claude.sh ring Workshop
  assert_rc 1
  run doorbell-claude.sh ring -
  assert_rc 2
  run doorbell-codex.sh ring ops-ws
  assert_rc 2
  profile_set doorbell_codex resume
  FAKE_MODE=ok run doorbell-codex.sh ring ops-ws sid-1
  assert_rc 2
  assert_has "$T/err" "doorbell_codex must be off or queue"
  assert_lacks "$FAKE_LOG" "== codex"
}

test_codex_doorbell_queues_for_the_held_session_only() {
  msetup
  lease acquire --provider codex --session "Current Workshop" --session-id sid-current
  assert_rc 0
  profile_set doorbell_codex queue
  printf 'private mailbox content\n' >"$T/body"
  srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  run mail.sh ring-all
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: sid-current"
  assert_lacks "$FAKE_LOG" "Current Workshop"
  assert_has "$FAKE_LOG" "arg: --resume"
  assert_has "$FAKE_LOG" "doorbell-id: "
  assert_has "$FAKE_LOG" "stdin: eof"
  assert_lacks "$FAKE_LOG" "== claude"
  assert_lacks "$FAKE_LOG" "private mailbox content"
  assert_has "$T/state/doorbell.log" "ws doorbell queue accepted (codex)"
  assert_count "$IB/new" 1
  run mail.sh ring-all
  assert_eq "$(grep -c '^== codex$' "$FAKE_LOG")" 1 "no repeat for the same mail"
}

test_codex_doorbell_needs_an_actual_thread_id() {
  msetup
  profile_set doorbell_codex queue
  for sid in '' - -invalid pending "$(printf 'bad\taddress')" "$(printf 'bad\naddress')"; do
    run doorbell-codex.sh ring "Display Name" "$sid"
    assert_rc 2
    assert_has "$T/err" "no addressable Codex thread"
    assert_no_file "$FAKE_LOG"
  done
  acq codex "Current Workshop"
  printf 'keep this mail\n' >"$T/body"
  srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  run mail.sh ring-all
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  assert_count "$IB/new" 1
  assert_has "$T/state/doorbell.log" "no addressable Codex thread"
  assert_has "$T/state/doorbell.log" "doorbell unavailable (codex)"
}

test_codex_doorbell_prefers_the_registered_id_and_reports_failure() {
  msetup
  profile_set doorbell_codex queue
  FAKE_MODE=queue-failed run doorbell-codex.sh ring "Example Workshop" sid-test
  assert_rc 1
  assert_has "$T/err" "queue acceptance unconfirmed"
  assert_has "$FAKE_LOG" "arg: sid-test"
  assert_lacks "$FAKE_LOG" "Example Workshop"
  assert_lacks "$FAKE_LOG" "== claude"
}

ao_test_main "$0"
