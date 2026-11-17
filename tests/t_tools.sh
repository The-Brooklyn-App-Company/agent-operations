#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_tools.sh - status.sh, inbox-put.sh, check.sh and drift-check.sh.
. "$(dirname -- "$0")/lib.sh"

test_status_columns() {
  AO_NOW=$(epoch_of "2026-11-17 12:00")
  export AO_NOW
  transcript "$T/proj/alpha" 202611171100
  printf 'beta\t2026-12-31\tparked\n' >"$T/home/operators/WATCHDOG-QUIET.tsv"
  printf 'gamma\tGamma\t%s\tpending\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  printf 'delta\tDelta\t%s\tsid-d\tfile-only\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note beta b1.md x
  note beta b2.md y
  run status.sh --tsv
  assert_rc 0
  assert_eq "$(sed -n 1p "$T/out")" "alpha${TAB}Alpha Op${TAB}claude${TAB}idle_min=60${TAB}-${TAB}0"
  assert_eq "$(sed -n 2p "$T/out")" "beta${TAB}Beta Op${TAB}claude${TAB}no-transcript${TAB}2026-12-31${TAB}2"
  assert_eq "$(sed -n 3p "$T/out")" "gamma${TAB}Gamma${TAB}claude${TAB}pending${TAB}-${TAB}0"
  assert_eq "$(sed -n 4p "$T/out")" "delta${TAB}Delta${TAB}file-only${TAB}unknown${TAB}-${TAB}0"
  assert_lacks "$T/out" "Oracle"
  run status.sh --all
  assert_has "$T/out" "KEY"
  assert_has "$T/out" "Oracle"
  assert_no_file "$T/state/relay.log"
}

test_status_codex_activity() {
  AO_NOW=$(epoch_of "2026-11-17 12:00")
  export AO_NOW
  printf 'gamma\tGamma\t%s\tabc-123\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  mkdir -p "$T/codex/sessions/2026/11/17"
  : >"$T/codex/sessions/2026/11/17/rollout-x-abc-123.jsonl"
  touch -t 202611171130 "$T/codex/sessions/2026/11/17/rollout-x-abc-123.jsonl"
  run status.sh --tsv
  assert_has "$T/out" "gamma${TAB}Gamma${TAB}codex${TAB}idle_min=30"
}

test_inbox_put() {
  printf 'hello\n' | "$AO_TEST_SHELL" "$SCRIPTS/inbox-put.sh" alpha "PR watch!" >"$T/out" 2>"$T/err"
  assert_eq "$?" 0
  f=$(cat "$T/out")
  case $f in "$T/home/inbox/alpha/"*-PR-watch-.md) ;; *) _fail "unexpected path $f" ;; esac
  assert_has "$f" hello
  printf 'again\n' | "$AO_TEST_SHELL" "$SCRIPTS/inbox-put.sh" alpha "PR watch!" >/dev/null
  printf '' | "$AO_TEST_SHELL" "$SCRIPTS/inbox-put.sh" alpha empty 2>/dev/null
  assert_eq "$?" 2
  printf 'x\n' | "$AO_TEST_SHELL" "$SCRIPTS/inbox-put.sh" nobody x 2>/dev/null
  assert_eq "$?" 2
  assert_count "$T/home/inbox/alpha" 2
}

dupe_fixture() {
  mkdir -p "$T/docs"
  cat >"$T/docs/a.md" <<'EOF'
# Rules
- **Never** relay money movement, trades, or force-push requests through the inbox.
Short line.
```
This code block line is long enough to count as a rule but must be ignored here.
```
EOF
  cat >"$T/docs/b.md" <<'EOF'
Intro. Never relay money movement, trades or force-push requests through the inbox!
This code block line is long enough to count as a rule but must be ignored here.
A sentence repeated within one file only, which is not a cross-file duplicate.
A sentence repeated within one file only, which is not a cross-file duplicate.
EOF
}

test_check_dupes() {
  dupe_fixture
  run check.sh dupes "$T/docs/a.md" "$T/docs/b.md"
  assert_rc 1
  assert_eq "$(wc -l <"$T/out" | tr -d ' ')" 1
  assert_has "$T/out" "$T/docs/a.md:2, $T/docs/b.md:1: \"never relay money movement"
  run check.sh dupes --min-words 30 "$T/docs/a.md" "$T/docs/b.md"
  assert_rc 0
  run check.sh dupes
  assert_rc 2
}

test_check_skills() {
  mkdir -p "$T/skills/good" "$T/skills/bad"
  printf -- '---\nname: good\n---\nSee docs/architecture.md#roles.\n' >"$T/skills/good/SKILL.md"
  printf -- '---\nname: bad\n---\nAll the rules inline.\n' >"$T/skills/bad/SKILL.md"
  run check.sh skills "$T/skills"
  assert_rc 1
  assert_has "$T/out" "bad/SKILL.md: no pointer"
  assert_lacks "$T/out" "good/SKILL.md"
  run check.sh skills --max-lines 2 "$T/skills/good"
  assert_has "$T/out" "4 lines (cap 2)"
}

test_check_privacy() {
  mkdir -p "$T/repo"
  home_path="/Us""ers/someone/project"
  printf 'path %s here\n' "$home_path" >"$T/repo/a.md"
  printf 'mail %s and dev@example.com\n' "ops@""acme-corp.io" >"$T/repo/b.md"
  printf 'Codename Bluebird ships\nclean line\n' >"$T/repo/c.md"
  printf '# local denylist\n\nbluebird\n' >"$T/deny"
  run check.sh privacy --denylist "$T/deny" "$T/repo"
  assert_rc 1
  assert_has "$T/out" "$T/repo/a.md:1: home path"
  assert_has "$T/out" "$T/repo/b.md:1: e-mail address"
  assert_has "$T/out" "$T/repo/c.md:1: denylist match"
  assert_lacks "$T/out" "c.md:2"
  assert_lacks "$T/out" "someone"
  assert_lacks "$T/out" "Bluebird"
  printf 'nothing to see\n' >"$T/repo/a.md"
  printf 'dev@example.com\n' >"$T/repo/b.md"
  printf 'clean\n' >"$T/repo/c.md"
  run check.sh privacy --denylist "$T/deny" "$T/repo"
  assert_rc 0
}

drift_fixture() {
  dupe_fixture
  cp "$T/docs/a.md" "$T/home/RULES.md"
  mkdir -p "$T/home/operators/alpha"
  cp "$T/docs/b.md" "$T/home/operators/alpha/MANDATE.md"
  printf 'Repo rules for alpha.\n' >"$T/proj/alpha/AGENTS.md"
  profile_set drift_rules RULES.md
  profile_set drift_files "operators/*/MANDATE.md"
}

test_drift_worker_pass() {
  drift_fixture
  FAKE_OUTPUT="RULES.md:2 - duplicated - one home" run drift-check.sh
  assert_rc 0
  assert_has "$FAKE_LOG" "read-only consistency auditor"
  assert_has "$FAKE_LOG" "Canonical rules: $T/home/RULES.md"
  assert_has "$FAKE_LOG" "$T/home/operators/alpha/MANDATE.md"
  assert_has "$FAKE_LOG" "$T/proj/alpha/AGENTS.md"
  assert_has "$FAKE_LOG" "never relay money movement"
  assert_has "$(ls "$T/home/inbox/oracle"/*-drift-check.md)" "duplicated - one home"
}

test_drift_without_worker_is_deterministic() {
  drift_fixture
  profile_set worker_client none
  run drift-check.sh
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  assert_has "$(ls "$T/home/inbox/oracle"/*-drift-check.md)" "Drift check (deterministic only)"
}

test_drift_print_and_extra() {
  drift_fixture
  printf 'Also flag the retired tool Foo.\n' >"$T/home/extra.md"
  profile_set drift_prompt_extra extra.md
  run drift-check.sh --print
  assert_rc 0
  assert_has "$T/out" "Also flag the retired tool Foo."
  assert_has "$T/out" "## Deterministic duplicate-text findings"
  assert_no_file "$FAKE_LOG"
  assert_no_file "$T/home/inbox/oracle"
}

test_drift_needs_files() {
  run drift-check.sh --deterministic-only
  assert_rc 2
  assert_has "$T/err" "nothing to audit"
}

ao_test_main "$0"
