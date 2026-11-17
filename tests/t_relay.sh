#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_relay.sh - inbox to session delivery through each transport.
. "$(dirname -- "$0")/lib.sh"

test_claude_delivery_archives_notes() {
  note alpha 001-a.md "first note"
  note alpha 002-b.md "second note"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_count "$T/home/inbox/alpha" 0
  assert_count "$T/home/inbox/sent" 2
  assert_has "$T/state/relay.log" "files=2 ok"
  assert_has "$FAKE_LOG" '== claude'
  assert_has "$FAKE_LOG" 'to "Alpha Op"'
  assert_has "$FAKE_LOG" 'Relay (automated inbox, not from the human):'
  assert_has "$FAKE_LOG" '--- 001-a.md'
  assert_has "$FAKE_LOG" 'second note'
  assert_has "$FAKE_LOG" 'arg: haiku'
  assert_has "$FAKE_LOG" 'arg: --max-turns'
  assert_has "$FAKE_LOG" 'stdin: eof'
  assert_has "$FAKE_LOG" "cwd: $T/home"
  for a in stream-json --verbose --strict-mcp-config '{"disableAllHooks":true}' \
    Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task,Skill; do
    assert_has "$FAKE_LOG" "arg: $a"
  done
  assert_has "$FAKE_LOG" "relay-id: "
}

test_receipt_is_required() {
  for mode in failed wrongto noid twice liar; do
    note alpha 001-a.md "first note"
    FAKE_MODE=$mode run relay.sh
    assert_rc 1
    assert_count "$T/home/inbox/alpha" 1
    assert_has "$T/state/relay.log" "receipt:"
  done
  assert_no_file "$T/home/inbox/sent"
}

test_large_backlog_goes_in_batches() {
  profile_set relay_max_bytes 1000
  profile_set relay_max_message_bytes 4000
  i=0
  while [ "$i" -lt 9 ]; do
    i=$((i + 1))
    note alpha "n$i.md" "$(printf '%0900d' 0)"
  done
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_count "$T/home/inbox/alpha" 0
  assert_count "$T/home/inbox/sent" 9
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 3 "deliveries"
  assert_eq "$(grep -c ' ok$' "$T/state/relay.log")" 3 "logged batches"
}

test_failed_batch_stops_the_row() {
  profile_set relay_max_bytes 1000
  profile_set relay_max_message_bytes 2500
  for n in 1 2 3 4; do note alpha "n$n.md" "$(printf '%0900d' 0)"; done
  FAKE_MODE=failed run relay.sh
  assert_rc 1
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 1 "attempts"
  assert_count "$T/home/inbox/alpha" 4
}

test_message_budget_is_validated() {
  profile_set relay_max_message_bytes 999999
  note alpha a.md x
  run relay.sh
  assert_rc 2
}

test_archive_never_overwrites() {
  mkdir -p "$T/home/inbox/sent"
  AO_NOW=$(epoch_of "2026-11-17 12:00")
  export AO_NOW
  echo "older copy" >"$T/home/inbox/sent/20261117T120000-alpha-a.md"
  note alpha a.md "new"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_eq "$(cat "$T/home/inbox/sent/20261117T120000-alpha-a.md")" "older copy"
  assert_has "$T/home/inbox/sent/20261117T120000-alpha-a-2.md" "new"
}

test_failed_delivery_keeps_notes() {
  note alpha 001-a.md "first note"
  FAKE_MODE=failed run relay.sh
  assert_rc 1
  assert_count "$T/home/inbox/alpha" 1
  assert_has "$T/state/relay.log" "to=alpha via=claude id="
  assert_has "$T/state/relay.log" "FAILED"
}

test_client_error_keeps_notes() {
  note alpha 001-a.md "first note"
  FAKE_MODE=fail run relay.sh
  assert_rc 1
  assert_count "$T/home/inbox/alpha" 1
}

test_every_row_with_notes_is_served() {
  note alpha a.md "for alpha"
  note beta b.md "for beta"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_eq "$(grep -c '^== claude' "$FAKE_LOG")" 2
  assert_count "$T/home/inbox/alpha" 0
  assert_count "$T/home/inbox/beta" 0
}

test_empty_inboxes_cost_nothing() {
  mkdir -p "$T/home/inbox/alpha"
  run relay.sh
  assert_rc 0
  assert_no_file "$FAKE_LOG"
}

test_file_only_rows_are_left_alone() {
  printf 'gamma\tGamma Op\t%s\tsid-g\tfile-only\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note gamma g.md "read me at turn start"
  run relay.sh
  assert_rc 0
  assert_count "$T/home/inbox/gamma" 1
  assert_no_file "$FAKE_LOG"
}

test_dry_run_moves_nothing() {
  note alpha a.md "x"
  run relay.sh --dry-run
  assert_rc 0
  assert_has "$T/out" "would relay 1 note(s) to alpha via claude"
  assert_count "$T/home/inbox/alpha" 1
  assert_no_file "$FAKE_LOG"
}

test_key_filter() {
  note alpha a.md "x"
  note beta b.md "y"
  FAKE_MODE=sent run relay.sh --key beta
  assert_count "$T/home/inbox/alpha" 1
  assert_count "$T/home/inbox/beta" 0
}

test_long_notes_are_cut_with_pointer() {
  profile_set relay_max_bytes 10
  note alpha long.md "0123456789ABCDEFGHIJ"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_has "$FAKE_LOG" "0123456789"
  assert_lacks "$FAKE_LOG" "ABCDEFGHIJ"
  assert_has "$FAKE_LOG" "[cut at 10 of 21 bytes; full note: $T/home/inbox/sent/"
}

test_partial_and_hidden_files_are_ignored() {
  note alpha .tmp.abc "being written"
  note alpha draft.txt "not markdown"
  run relay.sh
  assert_no_file "$FAKE_LOG"
}

test_gate_can_hold_delivery() {
  mkdir -p "$T/home/hooks"
  printf '#!/bin/sh\n[ "$2" != alpha ]\n' >"$T/home/hooks/gate"
  chmod +x "$T/home/hooks/gate"
  note alpha a.md "held"
  note beta b.md "passes"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_count "$T/home/inbox/alpha" 1
  assert_count "$T/home/inbox/beta" 0
  assert_has "$T/state/relay.log" "to=alpha held by gate"
}

test_custom_label_and_token() {
  profile_set relay_label "Relay (automated, not from the owner):"
  profile_set relay_claude_token_secret tok
  printf '#!/bin/sh\n[ "$1" = get ] && [ "$2" = tok ] && echo secret-value\n' >"$T/bin/secrets"
  chmod +x "$T/bin/secrets"
  profile_set secrets "$T/bin/secrets"
  note alpha a.md "x"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_has "$FAKE_LOG" "Relay (automated, not from the owner):"
  assert_has "$FAKE_LOG" "token: secret-value"
}

test_codex_transport_resumes_session() {
  printf 'gamma\tGamma Op\t%s\tsid-g\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note gamma g.md "hello codex"
  run relay.sh
  assert_rc 0
  assert_count "$T/home/inbox/gamma" 0
  assert_has "$FAKE_LOG" "== codex"
  assert_has "$FAKE_LOG" "arg: resume"
  assert_has "$FAKE_LOG" "arg: sid-g"
  assert_has "$FAKE_LOG" 'arg: sandbox_mode="read-only"'
  assert_lacks "$FAKE_LOG" "mcp_servers"
  profile_set relay_codex_mcp_disable trade,ui
  note gamma g2.md "again"
  run relay.sh
  assert_has "$FAKE_LOG" "arg: mcp_servers.trade.enabled=false"
  assert_has "$FAKE_LOG" "arg: mcp_servers.ui.enabled=false"
}

test_codex_transport_needs_session() {
  printf 'gamma\tGamma Op\t%s\tpending\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note gamma g.md "hello codex"
  run relay.sh
  assert_rc 1
  assert_count "$T/home/inbox/gamma" 1
  assert_has "$T/state/relay.log" "needs a session id"
}

test_custom_transport() {
  profile_set relay_custom_cmd "$T/bin/agent"
  printf 'gamma\tGamma Op\t%s\tsid-g\tcustom\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note gamma g.md "hello custom"
  run relay.sh
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: deliver"
  assert_has "$FAKE_LOG" "arg: Gamma Op"
  assert_has "$FAKE_LOG" "arg: sid-g"
  assert_has "$FAKE_LOG" "env: AO_ROLE=relay_custom"
  assert_eq "$(grep -c '^arg: ' "$FAKE_LOG")" 5 "custom deliver argc"
}

test_broken_transport_does_not_block_others() {
  profile_set relay_codex_cmd /nonexistent/codex
  printf 'gamma\tGamma Op\t%s\tsid-g\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note alpha a.md "x"
  note gamma g.md "y"
  FAKE_MODE=sent run relay.sh
  assert_rc 1
  assert_count "$T/home/inbox/alpha" 0
  assert_count "$T/home/inbox/gamma" 1
}

test_busy_lock_skips() {
  mkdir -p "$T/state/locks/relay.lock"
  echo $$ >"$T/state/locks/relay.lock/pid"
  note alpha a.md "x"
  run relay.sh
  assert_rc 3
  assert_count "$T/home/inbox/alpha" 1
}

ao_test_main "$0"
