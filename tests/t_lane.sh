#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_lane.sh - lane switches as a scripted checklist, holds, the Oracle lock,
# and the nightly hygiene check.
. "$(dirname -- "$0")/lib.sh"

# home_repo DIR  Make an operator home a git repository with one commit.
home_repo() {
  git -C "$1" init -q && git -C "$1" config user.email t@example.com && git -C "$1" config user.name T &&
    printf 'x\n' >"$1/NOTES.md" && git -C "$1" add NOTES.md && git -C "$1" commit -q -m init
}
commit_handoff() {
  printf 'handoff\n' >"$T/proj/alpha/HANDOFF.md"
  git -C "$T/proj/alpha" add HANDOFF.md && git -C "$T/proj/alpha" commit -q -m handoff
}
notes_named() {
  _c=0
  for _f in "$T/home/inbox/oracle"/*"$1"*; do [ -f "$_f" ] && _c=$((_c + 1)); done
  echo "$_c"
}
st() { sed -n "s/^$1=//p" "$T/state/switch/alpha" | tail -n 1; }

test_switch_walks_every_step_and_closes_only_when_all_pass() {
  home_repo "$T/proj/alpha"
  run lane.sh switch alpha --to codex --session thread-new
  assert_rc 0
  assert_file "$T/state/switch/alpha"
  assert_has "$(ls "$T/home/inbox/alpha"/*lane-switch.md)" "write a warm HANDOFF.md"
  # Nothing moves before the handoff.
  run lane.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  handoff"
  assert_has "$T/out" "WAIT  routing"
  assert_has "$T/home/operators/REGISTRY.tsv" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha"
  # The outgoing session commits its handoff: routing follows, with a note.
  sleep 1
  commit_handoff
  run lane.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  handoff"
  assert_has "$T/out" "PASS  routing      registry updated: codex thread-new"
  assert_has "$T/home/operators/REGISTRY.tsv" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}thread-new${TAB}codex"
  # The move to the other family is recorded at once: the audit is pending.
  assert_has "$T/state/audit/alpha" "from=claude"
  assert_has "$T/state/audit/alpha" "change=1"
  tok=$(st token)
  assert_has "$(ls "$T/home/inbox/alpha"/*lane-switch-in.md)" "lane.sh ack alpha $tok"
  assert_has "$T/out" "TODO  labels"
  assert_has "$T/out" "TODO  pins-claude  unpin the Claude session; move it to \"Inactive Operators\""
  assert_has "$T/out" "TODO  pins-codex   pin the Codex thread"
  assert_has "$T/out" "WAIT  switch-in"
  assert_has "$T/out" "WAIT  ack"
  # In-app steps are marked; a wrong token or the wrong thread is refused.
  run lane.sh mark alpha labels
  assert_rc 2
  for s in labels pins-claude pins-codex models; do run lane.sh mark alpha "$s" --evidence "readback ok"; assert_rc 0; done
  run lane.sh ack alpha wrong
  assert_rc 5
  CODEX_THREAD_ID=thread-other run lane.sh ack alpha "$tok"
  assert_rc 5
  CODEX_THREAD_ID=thread-new run lane.sh ack alpha "$tok"
  assert_rc 0
  assert_has "$T/out" "acknowledged from Codex thread thread-new"
  # The switch-in audit is still pending: not done yet.
  run lane.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  switch-in"
  assert_has "$T/out" "PASS  ack"
  # Recorded audit: every step passes and the switch closes.
  mkdir -p "$T/state/audit"
  printf 'provider=codex\nfrom=claude\nto=codex\nchange=1\nsince=2026-11-19T00:00:00Z\n' >"$T/state/audit/alpha"
  printf 'change=1\nsince=2026-11-19T00:00:00Z\nreport=audits/x.md\ncommit=abc123\nat=2026-11-19T00:00:00Z\n' >"$T/state/audit/alpha.done"
  run lane.sh verify alpha
  assert_rc 0
  assert_has "$T/out" "switch of alpha complete."
  assert_no_file "$T/state/switch/alpha"
  assert_count "$T/state/switch/done" 1
  assert_has "$(ls "$T/home/inbox/oracle"/*lane-switched.md)" "every step passed"
}

test_switch_refusals_cold_handoff_and_same_family() {
  run lane.sh switch oracle --to codex --session t
  assert_rc 5
  run lane.sh switch alpha --to other --session t
  assert_rc 2
  run lane.sh switch alpha --to claude --session sid-alpha
  assert_rc 5
  run lane.sh switch alpha --to claude --session sid-beta
  assert_rc 5
  assert_has "$T/err" "already leads 'beta'"
  run lane.sh switch alpha --to claude --session sid-new
  assert_rc 0
  run lane.sh switch alpha --to claude --session sid-newer
  assert_rc 5
  assert_has "$T/err" "is open since"
  # The outgoing session is gone: a cold handoff needs a reason.
  run lane.sh mark alpha handoff
  assert_rc 2
  run lane.sh mark alpha handoff --cold "session lost in a restart"
  assert_rc 0
  printf 'alpha\t2099-01-01\tbusy\n' >"$T/home/operators/WATCHDOG-QUIET.tsv"
  run lane.sh verify alpha
  assert_has "$T/out" "PASS  handoff      cold: session lost in a restart"
  assert_has "$T/out" "TODO  watchdog     a quiet-list entry silences alpha"
  assert_has "$T/out" "PASS  pins-codex   no Codex side"
  assert_has "$T/out" "PASS  switch-in    same model family"
  # A note to the Oracle that quotes the token is an ack too.
  tok=$(st token)
  printf 'got it %s\n' "$tok" | sh "$SCRIPTS/inbox-put.sh" oracle ack-note >/dev/null
  rm -f "$T/home/operators/WATCHDOG-QUIET.tsv"
  for s in labels pins-claude models; do run lane.sh mark alpha "$s" --evidence "gap: test"; done
  run lane.sh verify alpha
  assert_rc 0
  assert_has "$T/out" "PASS  ack          token quoted in"
}

test_side_check_holds_and_the_oracle_lock() {
  run lane.sh side alpha
  assert_rc 0
  assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side"
  run lane.sh check
  assert_rc 1
  assert_has "$T/out" "ok: alpha on claude (sid-alpha)"
  assert_has "$T/out" "no Oracle lock"
  run lane.sh oracle-lock take claude --session sid-oracle
  assert_rc 0
  assert_has "$T/home/operators/ORACLE-LOCK" "holder=claude"
  run lane.sh check
  assert_rc 0
  assert_has "$T/out" "oracle: claude (sid-oracle)"
  # A hold names its owner, expiry and reason, and stops the relay for the lane.
  run lane.sh hold alpha --until 2099-01-01 --reason x
  assert_rc 2
  run lane.sh hold alpha --owner ops --until 2099-01-01
  assert_rc 2
  run lane.sh hold alpha --owner ops --until 2000-01-01 --reason x
  assert_rc 2
  run lane.sh hold alpha --owner ops --until 2099-01-01 --reason "deploy freeze"
  assert_rc 0
  run lane.sh check
  assert_has "$T/out" "hold: alpha by ops until 2099-01-01 (deploy freeze)"
  note alpha a.md x
  FAKE_MODE=sent run relay.sh
  assert_no_file "$FAKE_LOG"
  assert_count "$T/home/inbox/alpha" 1
  # Expired: not obeyed, and reported.
  printf 'owner=ops\nuntil=2000-01-01\nreason=x\n' >"$T/state/holds/alpha"
  FAKE_MODE=sent run relay.sh
  assert_has "$FAKE_LOG" 'to "Alpha Op"'
  run lane.sh check
  assert_rc 1
  assert_has "$T/out" "hold not honoured"
  run hygiene.sh
  assert_rc 1
  assert_has "$T/out" "holds: alpha is expired or lacks an owner, expiry or reason"
  run lane.sh unhold alpha
  assert_rc 0
  assert_no_file "$T/state/holds/alpha"
}

test_mailroom_pause_is_a_hold_with_an_owner() {
  profile_set relay_bridge on
  run lane.sh hold mailroom --owner ops --until 2099-01-01 --reason maintenance
  assert_rc 0
  run mailroom.sh supervise
  assert_rc 0
  assert_has "$T/err" "paused by"
  printf 'until=2099-01-01\n' >"$T/state/mailroom-pause"
  run mailroom.sh supervise
  assert_lacks "$T/err" "paused by"
}

test_hygiene_diffs_grants_against_permission_rules() {
  home_repo "$T/proj/alpha"
  mkdir -p "$T/proj/alpha/.claude"
  cat >"$T/proj/alpha/MANDATE.md" <<'EOF'
# Mandate: Alpha

## Standing grants

| Date | Grant, in the human's words | Scope | Expires |
| --- | --- | --- | --- |
| 2026-11-01 | "run the tests" | `Bash(make test:*)` | - |
| 2026-11-01 | "deploy staging" | `Bash(make deploy:*)` | - |
| 2020-01-01 | "old" | none | 2020-02-01 |

## Reports to
EOF
  printf '{"permissions":{"allow":["Bash(make test:*)","Bash(rm:*)"]}}\n' >"$T/proj/alpha/.claude/settings.local.json"
  git -C "$T/proj/alpha" add -A && git -C "$T/proj/alpha" commit -q -m mandate
  run hygiene.sh
  assert_rc 1
  assert_has "$T/out" 'permission rule `Bash(rm:*)` has no standing grant'
  assert_has "$T/out" 'standing grant `Bash(make deploy:*)` is not in the Claude permission rules'
  assert_lacks "$T/out" 'Bash(make test:*)'
  assert_has "$T/out" "a standing grant is past its expiry"
  printf 'dirty\n' >"$T/proj/alpha/scratch.txt"
  run hygiene.sh --note
  assert_has "$T/out" "uncommitted or untracked path(s)"
  assert_eq "$(notes_named hygiene)" 1 "one note"
}

ao_test_main "$0"
