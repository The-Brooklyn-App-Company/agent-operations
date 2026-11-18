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
  assert_eq "$(sed -n 1p "$T/out")" "alpha${TAB}Alpha Op${TAB}claude${TAB}idle_min=60${TAB}-${TAB}0${TAB}-"
  assert_eq "$(sed -n 2p "$T/out")" "beta${TAB}Beta Op${TAB}claude${TAB}no-transcript${TAB}2026-12-31${TAB}2${TAB}-"
  assert_eq "$(sed -n 3p "$T/out")" "gamma${TAB}Gamma${TAB}claude${TAB}pending${TAB}-${TAB}0${TAB}-"
  assert_eq "$(sed -n 4p "$T/out")" "delta${TAB}Delta${TAB}file-only${TAB}unknown${TAB}-${TAB}0${TAB}-"
  assert_lacks "$T/out" "Oracle"
  run status.sh --all
  assert_has "$T/out" "AUDIT"
  assert_has "$T/out" "Oracle"
  assert_no_file "$T/state/relay.log"
}

test_status_prefers_exact_claude_session() {
  AO_NOW=$(epoch_of "2026-11-17 12:00")
  export AO_NOW
  transcript "$T/proj/alpha" 202611171150
  _slug=$(printf '%s' "$T/proj/alpha" | sed 's/[^A-Za-z0-9]/-/g')
  : >"$T/claude/projects/$_slug/sid-alpha.jsonl"
  touch -t 202611170800 "$T/claude/projects/$_slug/sid-alpha.jsonl"
  run status.sh --tsv
  assert_has "$T/out" "alpha${TAB}Alpha Op${TAB}claude${TAB}idle_min=240"
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

test_check_privacy_tracked_odd_names() {
  mkdir -p "$T/repo"
  (cd "$T/repo" && git init -q . && printf 'x %s\n' "dev@""fictional.zz" >'odd"name.md' && git add .) || return 0
  (cd "$T/repo" && "$AO_TEST_SHELL" "$SCRIPTS/check.sh" privacy >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  assert_has "$T/out" 'odd"name.md:1: e-mail address'
}

test_check_dupes() {
  dupe_fixture
  run check.sh dupes "$T/docs/a.md" "$T/docs/b.md"
  assert_rc 1
  assert_eq "$(wc -l <"$T/out" | tr -d ' ')" 1
  assert_has "$T/out" "$T/docs/a.md:2, $T/docs/b.md:1: \"never relay money movement"
  printf 'Never relay money movement, trades or\nforce-push requests through the inbox.\n' >"$T/docs/c.md"
  run check.sh dupes "$T/docs/a.md" "$T/docs/c.md"
  assert_rc 1
  assert_has "$T/out" "$T/docs/c.md:1"
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
  printf 'mail %s and dev@example.com\n' "ops@""fictional-co.zz" >"$T/repo/b.md"
  printf 'Codename Bluebird ships\nclean line\n' >"$T/repo/c.md"
  printf "cd '%s'\n" "/ho""me/bob" >"$T/repo/odd | name=x.md"
  printf 'x %s\n' "dev@""fictional.zz" >"$T/repo/-dash\"quote.md"
  printf '# local denylist\n\nbluebird\n' >"$T/deny"
  run check.sh privacy --denylist "$T/deny" "$T/repo"
  assert_rc 1
  assert_has "$T/out" "$T/repo/a.md:1: home path"
  assert_has "$T/out" "$T/repo/b.md:1: e-mail address"
  assert_has "$T/out" "$T/repo/c.md:1: denylist match"
  assert_has "$T/out" "$T/repo/odd | name=x.md:1: home path"
  assert_has "$T/out" "$T/repo/-dash\"quote.md:1: e-mail address"
  assert_lacks "$T/out" "c.md:2"
  assert_lacks "$T/out" "someone"
  assert_lacks "$T/out" "Bluebird"
  printf 'nothing to see\n' >"$T/repo/a.md"
  printf 'dev@example.com\n' >"$T/repo/b.md"
  printf 'clean\n' >"$T/repo/c.md"
  printf 'clean\n' >"$T/repo/odd | name=x.md"
  printf 'clean\n' >"$T/repo/-dash\"quote.md"
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
  mkdir -p "$T/home/operators/with space"
  printf 'A spaced mandate.\n' >"$T/home/operators/with space/MANDATE.md"
}

test_drift_worker_pass() {
  drift_fixture
  FAKE_OUTPUT="RULES.md:2 - duplicated - one home" run drift-check.sh
  assert_rc 0
  assert_has "$FAKE_LOG" "read-only consistency auditor"
  assert_has "$FAKE_LOG" "Canonical rules: $T/home/RULES.md"
  assert_has "$FAKE_LOG" "$T/home/operators/alpha/MANDATE.md"
  assert_has "$FAKE_LOG" "$T/proj/alpha/AGENTS.md"
  assert_has "$FAKE_LOG" "$T/home/operators/with space/MANDATE.md"
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

test_check_privacy_more_forms() {
  mkdir -p "$T/repo"
  printf 'see file://%s/x\n' "/Us""ers/alice" >"$T/repo/a.md"
  printf 'cc -I%s/inc\n' "/Us""ers/alice" >"$T/repo/b.md"
  printf 'cd %s\n' "~ali""ce/src" >"$T/repo/c.md"
  bs=$(printf '\134')
  printf 'C:%sUsers%salice\n' "$bs" "$bs" >"$T/repo/d.md"
  printf 'fine\n' >"$T/repo/bluebird-notes.md"
  printf '\000\001binary' >"$T/repo/e.bin"
  printf 'it was planned\n' >"$T/repo/f.md"
  printf 'ask Ann first\n' >"$T/repo/g.md"
  printf 'bluebird\n=ann\n' >"$T/deny"
  run check.sh privacy --denylist "$T/deny" "$T/repo"
  assert_rc 1
  assert_lacks "$T/out" "f.md"
  assert_has "$T/out" "$T/repo/g.md:1: denylist match"
  for f in a b c d; do assert_has "$T/out" "$T/repo/$f.md:1: home path"; done
  assert_has "$T/out" "bluebird-notes.md: denylist match in the file name"
  assert_has "$T/out" "$T/repo/e.bin: binary, not scanned"
}

test_check_links() {
  mkdir -p "$T/d/sub"
  printf '# Top\n## Two words, here!\n## Two words, here!\n' >"$T/d/sub/t.md"
  cat >"$T/d/a.md" <<'MD'
[ok](sub/t.md) [ok2](sub/t.md#two-words-here) [dup](sub/t.md#two-words-here-1)
[self](#local) [web](https://example.com/x) [dir](sub)
`[code](nowhere.md)`
[dead](missing.md) [badfrag](sub/t.md#nope)
```
[fenced](nowhere.md)
```
## Local
MD
  run check.sh links "$T/d/a.md"
  assert_rc 1
  assert_eq "$(wc -l <"$T/out" | tr -d ' ')" 2 "dead links"
  assert_has "$T/out" "a.md:4: missing.md"
  assert_has "$T/out" "a.md:4: sub/t.md#nope (no such heading)"
}

test_check_home() {
  mkdir -p "$T/h1" "$T/h2"
  for h in h1 h2; do printf 'x\n' >"$T/$h/AGENTS.md"; printf 'x\n' >"$T/$h/MANDATE.md"; done
  printf '@AGENTS.md\n' >"$T/h1/CLAUDE.md"
  printf 'key=web\nwork.app=git@git.example.com:o/app.git|owner\n' >"$T/h1/operator.conf"
  run check.sh home "$T/h1"
  assert_rc 0
  printf 'Read AGENTS.md and also this rule.\n' >"$T/h2/CLAUDE.md"
  printf 'key=infra\nwork.app=git@git.example.com:o/app.git|owner\nwork.x=u|boss\n' >"$T/h2/operator.conf"
  run check.sh home "$T/h1" "$T/h2"
  assert_rc 1
  assert_has "$T/out" "h2/CLAUDE.md: must contain only @AGENTS.md"
  assert_has "$T/out" "owned by more than one home: git.example.com/o/app"
  assert_has "$T/out" "h2/operator.conf:3: work value must end"
}

test_scripts_and_hooks_are_executable() {
  # Hooks and scripts call each other directly, so each must carry its
  # executable bit (and the tests otherwise run them through a shell).
  for f in "$SCRIPTS"/*.sh "$SCRIPTS"/../adapters/*.sh "$SCRIPTS"/../examples/hooks/*/* \
    "$SCRIPTS"/../examples/tracker-linear/*.sh; do
    [ -x "$f" ] || _fail "not executable: ${f#"$SCRIPTS"/}"
  done
}

ao_test_main "$0"
