#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_install.sh - install.sh (oracle, operator, skills, timers) and the
# shipped adapters.
. "$(dirname -- "$0")/lib.sh"

KIT_DIR=$(CDPATH='' cd -- "$SCRIPTS/.." && pwd)

# fresh  A new profile path and a git identity inside the sandbox.
fresh() {
  AO_PROFILE=$T/cfg/profile
  GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
  GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
  export AO_PROFILE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
}

oracle_home() {
  fresh
  run install.sh oracle "$T/ops/oracle"
  printf 'work_root=%s\n' "$T/src" >>"$AO_PROFILE"
}

repo() { # DIR
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init
}

test_dry_run_lists_everything_and_writes_nothing() {
  fresh
  run install.sh --dry-run oracle "$T/ops/oracle"
  assert_rc 0
  for f in AGENTS.md CLAUDE.md MANDATE.md NOTES.md BACKLOG.md JOURNAL.md FACTS.md \
    SCHEDULES.md KIT.local.md .gitignore operators/REGISTRY.tsv hooks/hourly/60-cross-review; do
    assert_has "$T/out" "would create  $T/ops/oracle/$f"
  done
  assert_has "$T/out" "would create  $T/cfg/profile (from profiles/both.profile)"
  assert_has "$T/out" "would commit"
  assert_no_file "$T/ops"
  assert_no_file "$T/cfg"
}

test_oracle_home_is_created_and_committed() {
  oracle_home
  assert_rc 0
  h=$T/ops/oracle
  assert_has "$h/AGENTS.md" "You are the Oracle"
  assert_lacks "$h/AGENTS.md" "@KIT_DIR@"
  assert_has "$h/KIT.local.md" "version: $(cat "$KIT_DIR/VERSION")"
  assert_has "$h/KIT.local.md" "kit: $KIT_DIR"
  assert_eq "$(cat "$h/CLAUDE.md")" "@AGENTS.md"
  assert_has "$h/operators/REGISTRY.tsv" "oracle${TAB}Oracle${TAB}$h${TAB}pending${TAB}claude"
  assert_has "$AO_PROFILE" "oracle_home=$h"
  [ -x "$h/hooks/hourly/60-cross-review" ] || _fail "hook not executable"
  assert_eq "$(find "$h/hooks/hourly/60-cross-review" -perm -0020 | wc -l | tr -d ' ')" 0 "group-writable hook"
  assert_eq "$(find "$AO_PROFILE" -perm 600 | wc -l | tr -d ' ')" 1 "profile mode 600"
  assert_has "$T/out" "Next, by hand:"
  assert_eq "$(git -C "$h" log --oneline | wc -l | tr -d ' ')" 1 "commits"
  assert_eq "$(git -C "$h" ls-files KIT.local.md)" KIT.local.md "kit pin tracked"
  assert_eq "$(git -C "$h" status --porcelain | wc -l | tr -d ' ')" 0 "uncommitted files"
  run check.sh home "$h"
  assert_rc 0
}

test_rerun_keeps_what_exists() {
  oracle_home
  printf 'My own charter.\n' >"$T/ops/oracle/MANDATE.md"
  run install.sh oracle "$T/ops/oracle"
  assert_rc 0
  assert_has "$T/out" "keep    $T/ops/oracle/MANDATE.md (exists)"
  assert_eq "$(cat "$T/ops/oracle/MANDATE.md")" "My own charter."
  assert_eq "$(grep -c '^oracle' "$T/ops/oracle/operators/REGISTRY.tsv")" 1 "oracle rows"
}

test_refusals() {
  fresh
  AO_PROFILE=$T/ops/oracle/profile
  run install.sh oracle "$T/ops/oracle"
  assert_rc 2
  assert_has "$T/err" "the profile must live outside git"
  fresh
  run install.sh oracle "$KIT_DIR/oops"
  assert_rc 2
  run install.sh oracle "$T/ops/oracle" --client robot
  assert_rc 2
  run install.sh unknown
  assert_rc 2
}

test_operator_home_row_conf_and_worktree() {
  oracle_home
  repo "$T/src/infra"
  run install.sh operator web --name "[OPS] Web" \
    --owns git@git.example.com:j/app-web.git --contributes git@git.example.com:j/infra.git
  assert_rc 0
  h=$T/ops/web
  assert_has "$h/operator.conf" "key=web"
  assert_has "$h/operator.conf" "session.claude=[OPS] Web"
  assert_has "$h/operator.conf" "work.app-web=git@git.example.com:j/app-web.git|owner"
  assert_has "$h/operator.conf" "work.infra=git@git.example.com:j/infra.git|contributor"
  assert_has "$h/AGENTS.md" 'You are the operator `web`'
  assert_has "$T/ops/oracle/operators/REGISTRY.tsv" "web${TAB}[OPS] Web${TAB}$h${TAB}pending${TAB}claude"
  assert_eq "$(git -C "$T/src/.worktrees/web/infra" rev-parse --abbrev-ref HEAD)" "web/main" "worktree branch"
  assert_has "$T/out" "git clone git@git.example.com:j/app-web.git $T/src/app-web"
  assert_eq "$(git -C "$h" log --oneline | wc -l | tr -d ' ')" 1 "operator home commits"
  assert_eq "$(git -C "$T/ops/oracle" status --porcelain | wc -l | tr -d ' ')" 0 "oracle home clean"
  run check.sh home "$T/ops/oracle" "$h"
  assert_rc 0
}

test_operator_dry_run_writes_nothing() {
  oracle_home
  repo "$T/src/infra"
  run install.sh --dry-run operator web --contributes git@git.example.com:j/infra.git
  assert_rc 0
  assert_has "$T/out" "would create  $T/ops/web/operator.conf"
  assert_has "$T/out" "would create  $T/src/.worktrees/web/infra (worktree, branch web/main)"
  assert_has "$T/out" "would append  $T/ops/oracle/operators/REGISTRY.tsv"
  assert_no_file "$T/ops/web"
  assert_no_file "$T/src/.worktrees"
  assert_lacks "$T/ops/oracle/operators/REGISTRY.tsv" "web"
}

test_one_owner_per_repository() {
  oracle_home
  run install.sh operator infra --embedded --client codex --owns git@git.example.com:j/infra.git
  assert_rc 0
  assert_file "$T/ops/oracle/operators/infra/operator.conf"
  assert_has "$T/ops/oracle/operators/REGISTRY.tsv" "infra${TAB}infra${TAB}$T/ops/oracle/operators/infra${TAB}pending${TAB}codex"
  run install.sh operator web --owns git@git.example.com:j/infra.git
  assert_rc 2
  assert_has "$T/err" "already owned by operator 'infra'"
  assert_no_file "$T/ops/web"
  run install.sh operator web --owns git@git.example.com:j/infra/
  assert_rc 2
  run install.sh operator oracle
  assert_rc 2
  run install.sh operator sent
  assert_rc 2
}

test_commits_only_what_it_created() {
  oracle_home
  printf 'private\n' >"$T/ops/oracle/private.txt"
  git -C "$T/ops/oracle" add private.txt
  run install.sh operator web --embedded
  assert_rc 0
  git -C "$T/ops/oracle" show --format= --name-only HEAD >"$T/files"
  assert_lacks "$T/files" "private.txt"
  assert_has "$T/files" "operators/web/AGENTS.md"
  assert_eq "$(git -C "$T/ops/oracle" diff --cached --name-only)" "private.txt" "still staged"
}

test_skills_are_linked_never_replaced() {
  fresh
  mkdir -p "$T/skills/review-handoff"
  run install.sh skills --target "$T/skills"
  assert_rc 1
  assert_has "$T/err" "review-handoff exists and is not this kit's link"
  [ -L "$T/skills/operator-setup" ] || _fail "operator-setup not linked"
  assert_eq "$(readlink "$T/skills/operator-setup")" "$KIT_DIR/skills/operator-setup"
  rmdir "$T/skills/review-handoff"
  run install.sh skills --target "$T/skills"
  assert_rc 0
  assert_has "$T/out" "keep    $T/skills/operator-setup (already linked)"
}

test_timers_are_rendered_not_loaded() {
  oracle_home
  run install.sh timers --launchd
  assert_rc 0
  p=$T/user/Library/LaunchAgents/local.agent-operations.tick.plist
  assert_has "$p" "$KIT_DIR/scripts/tick.sh"
  assert_has "$p" "<string>$AO_PROFILE</string>"
  assert_eq "$(grep -cE '@(LABEL|KIT_DIR|PROFILE|LOG_DIR)@' "$p")" 0 "placeholders left"
  assert_has "$T/out" "launchctl bootstrap gui/"
  run install.sh --dry-run timers --systemd
  assert_has "$T/out" "would create  $T/user/.config/systemd/user/agent-operations-tick.service"
  assert_has "$T/out" "would create  $T/user/.config/systemd/user/agent-operations-tick.timer"
  assert_no_file "$T/user/.config/systemd"
}

test_none_adapter() {
  for v in poll pr-poll status link review-request; do
    "$KIT_DIR/adapters/none.sh" "$v" a b </dev/null >"$T/out" 2>&1
    assert_eq "$?:$(wc -c <"$T/out" | tr -d ' ')" "0:0" "none.sh $v"
  done
  "$KIT_DIR/adapters/none.sh" get x </dev/null
  assert_eq "$?" 2 "none.sh get"
  "$KIT_DIR/adapters/none.sh" notify high "disk almost full" </dev/null
  assert_eq "$?" 0 "none.sh notify"
  assert_has "$(ls "$T/home/inbox/oracle"/*-notify.md)" "[high] disk almost full"
  "$KIT_DIR/adapters/none.sh" bogus </dev/null 2>/dev/null
  assert_eq "$?" 3 "none.sh bogus"
}

test_gh_adapter() {
  cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
case ${FAKE_GH:-ok} in
  down) echo "error connecting to api.github.com" >&2; exit 1 ;;
  auth) echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4 ;;
esac
case $1 in
  pr) [ "$2" = list ] && echo '[{"number":7,"headRefOid":"abc123","state":"OPEN","reviewDecision":null,"url":"https://git.example.com/o/r/pull/7"}]' ;;
  api) echo '{"state":"success","statuses":[{"target_url":"https://ci.example.com/1"}]}' ;;
esac
exit 0
EOF
  chmod +x "$T/bin/gh"
  "$KIT_DIR/adapters/git-gh.sh" pr-poll o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$?" 0 "pr-poll"
  assert_eq "$(cat "$T/out")" "7${TAB}abc123${TAB}OPEN${TAB}NONE${TAB}https://git.example.com/o/r/pull/7"
  "$KIT_DIR/adapters/git-gh.sh" status abc123 o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$(cat "$T/out")" "abc123${TAB}success${TAB}https://ci.example.com/1"
  "$KIT_DIR/adapters/git-gh.sh" review-request 7 sam o/r </dev/null
  assert_eq "$?" 0 "review-request"
  assert_has "$FAKE_LOG" "pr edit 7 --add-reviewer sam --repo o/r"
  FAKE_GH=down "$KIT_DIR/adapters/git-gh.sh" pr-poll o/r </dev/null >"$T/out" 2>/dev/null
  assert_eq "$?:$(wc -c <"$T/out" | tr -d ' ')" "2:0" "unavailable is not empty"
  FAKE_GH=auth "$KIT_DIR/adapters/git-gh.sh" pr-poll o/r </dev/null 2>/dev/null
  assert_eq "$?" 3 "signed out is misconfigured"
  "$KIT_DIR/adapters/git-gh.sh" status 'not-a-sha' o/r </dev/null 2>/dev/null
  assert_eq "$?" 3 "bad sha"
}

ao_test_main "$0"
