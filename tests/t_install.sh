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

repo() { # DIR ORIGIN
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init &&
    git -C "$1" remote add origin "$2"
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
  repo "$T/src/infra" ssh://git@git.example.com/j/infra
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
  repo "$T/src/infra" git@git.example.com:j/infra.git
  run install.sh --dry-run operator web --contributes git@git.example.com:j/infra.git
  assert_rc 0
  assert_has "$T/out" "would create  $T/ops/web/operator.conf"
  assert_has "$T/out" "would create  $T/src/.worktrees/web/infra (worktree, branch web/main)"
  assert_has "$T/out" "would append  $T/ops/oracle/operators/REGISTRY.tsv"
  assert_no_file "$T/ops/web"
  assert_no_file "$T/src/.worktrees"
  assert_lacks "$T/ops/oracle/operators/REGISTRY.tsv" "web"
  run install.sh --dry-run timers --launchd
  assert_rc 0
  assert_no_file "$T/user/.local/state/agent-operations"
  assert_no_file "$T/user/Library"
}

test_a_dangling_registry_link_is_left_alone() {
  fresh
  mkdir -p "$T/ops/oracle/operators"
  ln -s "$T/elsewhere/REGISTRY.tsv" "$T/ops/oracle/operators/REGISTRY.tsv"
  mkdir -p "$T/elsewhere"
  run install.sh oracle "$T/ops/oracle"
  assert_has "$T/out" "keep    $T/ops/oracle/operators/REGISTRY.tsv (exists)"
  assert_no_file "$T/elsewhere/REGISTRY.tsv"
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
  run install.sh operator web --owns ssh://git@Git.Example.com:22/j/infra
  assert_rc 2
  run install.sh operator oracle
  assert_rc 2
  run install.sh operator sent
  assert_rc 2
}

test_worktree_needs_the_right_checkout() {
  oracle_home
  repo "$T/src/infra" git@git.example.com:someone-else/infra.git
  run install.sh operator web --contributes git@git.example.com:j/infra.git
  assert_rc 1
  assert_has "$T/err" "is not a checkout of git@git.example.com:j/infra.git"
  assert_no_file "$T/src/.worktrees"
}

test_links_are_never_replaced() {
  fresh
  mkdir -p "$T/ops/oracle"
  ln -s "$T/nowhere" "$T/ops/oracle/NOTES.md"
  run install.sh oracle "$T/ops/oracle"
  assert_has "$T/out" "keep    $T/ops/oracle/NOTES.md (exists)"
  [ -L "$T/ops/oracle/NOTES.md" ] || _fail "link replaced"
}

test_oracle_client_follows_the_profile_example() {
  fresh
  run install.sh oracle "$T/ops/oracle" --profile-example codex-only
  assert_rc 0
  assert_has "$T/ops/oracle/operators/REGISTRY.tsv" "pending${TAB}codex"
  assert_has "$AO_PROFILE" "relay_default=codex"
  assert_has "$AO_PROFILE" "relay_codex=queue"
  # A fresh Codex-only home queues after adding an actual app-thread ID.
  sed "s/pending${TAB}codex/sid-installed${TAB}codex/" \
    "$T/ops/oracle/operators/REGISTRY.tsv" >"$T/reg"
  mv "$T/reg" "$T/ops/oracle/operators/REGISTRY.tsv"
  # The shipped scheduled PATH must never select a real CLI in this fixture.
  printf 'state_dir=%s\nrelay_codex_cmd=%s\nrelay_bridge=off\n' "$T/state" "$T/bin/codex" >>"$AO_PROFILE"
  mkdir -p "$T/ops/oracle/inbox/oracle"
  printf 'fixture\n' >"$T/ops/oracle/inbox/oracle/setup.md"
  run relay.sh --key oracle
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: sid-installed"
  assert_count "$T/ops/oracle/inbox/sent" 1
  assert_no_file "$T/ops/oracle/inbox/oracle/setup.md"
  assert_no_file "$T/ops/oracle/inbox/oracle/.relay-pending"
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

test_sync_brings_a_second_client_up_to_date() {
  oracle_home
  run install.sh operator web --name Web
  assert_rc 0
  w=$T/ops/web
  rm "$w/CLAUDE.md" "$w/settings/handoff.md"
  git -C "$w" commit -q -am "lose pointers"
  printf 'x\tX\t%s\tpending\tclaude\n' "$T/ops/gone" >>"$T/ops/oracle/operators/REGISTRY.tsv"
  run status.sh --drift
  assert_rc 1
  assert_has "$T/out" "web: pointer: CLAUDE.md missing"
  assert_has "$T/out" "web: settings: settings/handoff.md missing"
  assert_has "$T/out" "x: home: home $T/ops/gone not found"
  run install.sh --dry-run sync codex
  assert_rc 1
  assert_has "$T/out" "would create  $w/CLAUDE.md"
  assert_has "$T/out" "would append  $w/operator.conf: session.codex=Web"
  assert_no_file "$w/CLAUDE.md"
  run install.sh sync codex
  assert_rc 1
  assert_has "$T/err" "x: home $T/ops/gone not found"
  assert_eq "$(cat "$w/CLAUDE.md")" "@AGENTS.md"
  assert_has "$w/settings/handoff.md" "lease.sh*takeover*"
  assert_has "$w/settings/handoff.md" "$KIT_DIR/scripts/lease.sh"
  assert_has "$w/operator.conf" "session.codex=Web"
  assert_has "$T/out" 'web: start a codex session in '"$w"' and name it "Web".'
  assert_has "$T/out" "status.sh --drift"
  git -C "$w" diff --quiet HEAD || _fail "sync left the home uncommitted"
  assert_file "$T/ops/oracle/settings/handoff.md"
  # A second run changes nothing.
  run install.sh sync codex
  assert_has "$T/out" "keep    $w/operator.conf (session.codex=Web)"
  # Drift: only the missing home is left.
  run status.sh --drift --tsv
  assert_rc 1
  assert_eq "$(cut -f 1,2 "$T/out" | tr '\t\n' ': ')" "x:home "
}

test_drift_names_renames_pins_and_stale_ids() {
  oracle_home
  run install.sh operator web --name Web
  run install.sh operator api --name Api
  run install.sh sync codex
  w=$T/ops/web
  run status.sh --drift
  assert_rc 0
  assert_has "$T/out" "clients in use: claude codex"
  assert_has "$T/out" "no drift"
  # A renamed session, a renamed key, a stale id, a pin behind, a client
  # the operator lacks.
  sed "s/^web${TAB}Web${TAB}\(.*\)${TAB}pending/web${TAB}Web Ops${TAB}\1${TAB}sid-gone/" "$T/ops/oracle/operators/REGISTRY.tsv" >"$T/reg"
  mv "$T/reg" "$T/ops/oracle/operators/REGISTRY.tsv"
  sed -i.bak 's/^key=web$/key=webapp/' "$w/operator.conf"
  sed -i.bak '/^session.codex=/d' "$w/operator.conf"
  sed -i.bak 's/^version: .*/version: 0.1.0/; s/^commit: .*/commit: abc1234/' "$T/ops/oracle/KIT.local.md"
  sed -i.bak 's/, version [^)]*)/, version 0.1.0)/' "$w/AGENTS.md"
  run status.sh --drift
  assert_rc 1
  assert_has "$T/out" 'web: name: registry names the claude session "Web Ops", operator.conf session.claude="Web"'
  assert_has "$T/out" "web: key: operator.conf says key=webapp"
  assert_has "$T/out" "web: client: no session name for codex"
  assert_has "$T/out" "fix: install.sh sync codex"
  assert_has "$T/out" "web: session: registered session id sid-gone has no claude transcript"
  assert_has "$T/out" "web: pin: AGENTS.md cites kit version 0.1.0, this checkout is $(cat "$KIT_DIR/VERSION")"
  assert_has "$T/out" "oracle: pin: KIT.local.md pins kit 0.1.0"
  assert_has "$T/out" "oracle: pin: KIT.local.md pins commit abc1234"
}

test_sync_leaves_a_dirty_operator_conf_alone() {
  oracle_home
  run install.sh operator web --name Web
  w=$T/ops/web
  printf 'note=local edit' >>"$w/operator.conf"
  run install.sh sync codex
  assert_rc 1
  assert_has "$T/err" "operator.conf has uncommitted changes or is untracked; not touched"
  assert_lacks "$w/operator.conf" "session.codex"
  # Committed, without a final newline: the new line is not glued on.
  git -C "$w" commit -q -am "local edit"
  run install.sh sync codex
  assert_rc 0
  assert_has "$w/operator.conf" "note=local edit"
  assert_eq "$(tail -n 1 "$w/operator.conf")" "session.codex=Web"
  git -C "$w" diff --quiet HEAD || _fail "uncommitted after sync"
  # A linked operator.conf is never written through.
  run install.sh operator api --name Api
  mv "$T/ops/api/operator.conf" "$T/api.conf"
  ln -s "$T/api.conf" "$T/ops/api/operator.conf"
  run install.sh sync codex
  assert_rc 1
  assert_has "$T/err" "operator.conf is a link or not a regular file; not touched"
  assert_lacks "$T/api.conf" "session.codex"
  # The Oracle home gets an operator.conf with both session names.
  assert_has "$T/ops/oracle/operator.conf" "key=oracle"
  assert_has "$T/ops/oracle/operator.conf" "session.claude=Oracle"
  assert_has "$T/ops/oracle/operator.conf" "session.codex=Oracle"
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
  api) case $* in
         *check-runs*) case ${FAKE_RUNS:-ok} in
             paged) echo '{"check_runs":[{"status":"completed","conclusion":"success"}]}'
                    echo '{"check_runs":[{"status":"completed","conclusion":"failure"}]}' ;;
             ok) echo '{"check_runs":[{"status":"completed","conclusion":"success","html_url":"https://ci.example.com/2"}]}' ;;
             running) echo '{"check_runs":[{"status":"in_progress","conclusion":null}]}' ;;
             failed) echo '{"check_runs":[{"status":"completed","conclusion":"failure"}]}' ;;
           esac ;;
         *) if [ -n "${FAKE_STATUS:-}" ]; then echo "$FAKE_STATUS"; else
              echo '{"state":"success","statuses":[{"state":"success","target_url":"https://ci.example.com/1"}]}'; fi ;;
       esac ;;
esac
exit 0
EOF
  chmod +x "$T/bin/gh"
  "$KIT_DIR/adapters/git-gh.sh" pr-poll o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$?" 0 "pr-poll"
  assert_eq "$(cat "$T/out")" "7${TAB}abc123${TAB}OPEN${TAB}NONE${TAB}https://git.example.com/o/r/pull/7"
  "$KIT_DIR/adapters/git-gh.sh" status abc123 o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$(cat "$T/out")" "abc123${TAB}success${TAB}https://ci.example.com/1"
  FAKE_RUNS=running "$KIT_DIR/adapters/git-gh.sh" status abc123 o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$(cut -f 2 "$T/out")" pending "a running check"
  FAKE_RUNS=failed "$KIT_DIR/adapters/git-gh.sh" status abc123 o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$(cut -f 2 "$T/out")" failure "a failed check"
  FAKE_RUNS=paged "$KIT_DIR/adapters/git-gh.sh" status abc123 o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$(cut -f 2 "$T/out")" failure "a failure on a later page"
  FAKE_STATUS='{"state":"failure","total_count":120,"statuses":[{"state":"success"}]}' \
    "$KIT_DIR/adapters/git-gh.sh" status abc123 o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$(cut -f 2 "$T/out")" failure "the combined status counts"
  FAKE_STATUS='{"state":"pending","statuses":[]}' "$KIT_DIR/adapters/git-gh.sh" status abc123 o/r </dev/null >"$T/out" 2>"$T/err"
  assert_eq "$(cut -f 2,3 "$T/out")" "success${TAB}https://ci.example.com/2" "actions-only commit"
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

test_the_relay_unit_watches_every_inbox_and_runs_standard() {
  oracle_home
  run install.sh operator web --embedded
  run install.sh timers --launchd
  assert_rc 0
  r=$T/user/Library/LaunchAgents/local.agent-operations.relay.plist
  t=$T/user/Library/LaunchAgents/local.agent-operations.tick.plist
  assert_has "$r" "<string>$KIT_DIR/scripts/mailroom.sh</string><string>cycle</string>"
  assert_has "$r" "<string>$T/ops/oracle/inbox/oracle</string>"
  assert_has "$r" "<string>$T/ops/oracle/inbox/web</string>"
  assert_lacks "$r" "@WATCH_PATHS@"
  for p in "$r" "$t"; do
    assert_has "$p" "<key>ProcessType</key><string>Standard</string>"
    assert_has "$p" "<key>RunAtLoad</key><true/>"
  done
  printf 'host_launchd_dirs=%s\n' "$T/user/Library/LaunchAgents" >>"$AO_PROFILE"
  run check.sh host
  assert_rc 0
  run install.sh --dry-run timers --systemd
  assert_has "$T/out" "would create  $T/user/.config/systemd/user/agent-operations-relay.timer"
}

# fake_defaults  A `defaults` that keeps values under $T/defaults.
fake_defaults() {
  mkdir -p "$T/defaults"
  cat >"$T/bin/defaults" <<EOF
#!/bin/sh
d=$T/defaults
case \$1 in
  read) [ -e "\$d/\$2" ] || exit 1; [ \$# -eq 2 ] && exit 0; cat "\$d/\$2.\$3" 2>/dev/null || exit 1 ;;
  write) : >"\$d/\$2"; echo 1 >"\$d/\$2.\$3"; echo "write \$*" >>"\$d/log" ;;
esac
EOF
  chmod +x "$T/bin/defaults"
  # And a launchctl that only records: tests never touch the real launchd.
  mkdir -p "$T/loaded"
  cat >"$T/bin/launchctl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/launchctl.log"
case \$1 in
  print) [ -e "$T/loaded/\${2##*/}" ] ;;
  bootstrap) f=\${3##*/}; : >"$T/loaded/\${f%.plist}" ;;
  bootout) rm -f "$T/loaded/\${2##*/}" ;;
esac
EOF
  chmod +x "$T/bin/launchctl"
}

test_host_sets_app_nap_off_once_and_reports_a_table() {
  oracle_home
  fake_defaults
  # The profile's scheduled PATH would find the real defaults: never here.
  printf 'host_launchd_dirs=%s\npath=%s\n' "$T/none" "$T/bin:/usr/bin:/bin" >>"$AO_PROFILE"
  run install.sh --dry-run host
  assert_has "$T/out" "would set"
  assert_no_file "$T/defaults/log"
  run install.sh host
  grep -Eq '^app-nap com.anthropic.claudefordesktop +set \(restart needed\)' "$T/out" || _fail "App Nap not set"
  assert_has "$T/out" "app-nap com.openai.codex"
  assert_has "$T/defaults/log" "write com.openai.codex NSAppSleepDisabled -bool YES"
  assert_has "$T/out" "bridge claude home"
  assert_has "$T/out" "install.sh host --apply"
  assert_has "$T/out" "In the apps (once; a person does these):"
  assert_no_file "$T/launchctl.log"
  run install.sh host
  grep -Eq '^app-nap com.openai.codex +ok' "$T/out" || _fail "second run: App Nap not reported ok"
  assert_eq "$(grep -c write "$T/defaults/log")" 2 "written once per app"
  run check.sh host
  assert_rc 0
}

test_host_apply_is_turnkey_and_ends_with_the_in_app_steps() {
  [ "$(uname -s)" = Darwin ] || { echo "    (skipped: launchd units are macOS)"; return 0; }
  oracle_home
  fake_defaults
  printf 'host_launchd_dirs=%s\npath=%s\n' "$T/none" "$T/bin:/usr/bin:/bin" >>"$AO_PROFILE"
  mkdir -p "$T/state/mailroom-probe"
  printf 'state_dir=%s\n' "$T/state" >>"$AO_PROFILE"
  run install.sh host --apply
  la=$T/user/Library/LaunchAgents
  assert_file "$la/local.agent-operations.tick.plist"
  assert_has "$la/local.agent-operations.relay.plist" "<string>$T/ops/oracle/inbox/oracle</string>"
  grep -Eq '^unit relay +installed and loaded' "$T/out" || _fail "relay unit not installed"
  assert_has "$T/launchctl.log" "bootstrap gui/"
  assert_has "$T/ops/mailroom-claude/AGENTS.md" "Mailroom (Claude): your whole duty"
  assert_has "$T/ops/mailroom-codex/AGENTS.md" "Mailroom (Codex): your whole duty"
  assert_has "$T/ops/oracle/operators/REGISTRY.tsv" "mailroom-codex${TAB}Mailroom${TAB}"
  grep -Eq '^bridge claude id +pending' "$T/out" || _fail "bridge id not reported pending"
  grep -Eq '^retired hourly probes +removed' "$T/out" || _fail "probe state not removed"
  grep -Eq '^oracle lock +missing' "$T/out" || _fail "no lock row"
  assert_has "$T/out" '[to do] Claude: the Mailroom session'
  assert_has "$T/out" 'a section named "Inactive Operators"'
  assert_has "$T/out" '[to do] Quit and reopen both desktop apps'
  # Again: nothing left to set; a stale relay unit and duty file are fixed.
  run install.sh host --apply
  grep -Eq '^unit relay +ok \(loaded\)' "$T/out" || _fail "second run: relay unit not ok"
  grep -Eq '^bridge claude duty file +ok' "$T/out" || _fail "second run: duty file not ok"
  run install.sh operator web --embedded
  printf 'old duty\n' >"$T/ops/mailroom-claude/AGENTS.md"
  run install.sh host
  grep -Eq '^unit relay +stale' "$T/out" || _fail "stale relay unit not reported"
  run install.sh host --apply
  grep -Eq '^unit relay +updated and reloaded' "$T/out" || _fail "relay unit not updated"
  assert_has "$la/local.agent-operations.relay.plist" "<string>$T/ops/oracle/inbox/web</string>"
  grep -Eq '^bridge claude duty file +updated' "$T/out" || _fail "duty file not updated"
  [ "$(find "$T/state/backup" -name 'AGENTS.md.*' | wc -l | tr -d ' ')" = 1 ] || _fail "no duty file backup"
  # A dry run never loads a unit, even with --apply.
  rm -f "$T/loaded/local.agent-operations.relay"
  n=$(grep -c bootstrap "$T/launchctl.log")
  run install.sh --dry-run host --apply
  assert_eq "$(grep -c bootstrap "$T/launchctl.log")" "$n" "no launchctl bootstrap on a dry run"
  grep -Eq '^unit relay +not loaded' "$T/out" || _fail "dry run does not say the unit is not loaded"
  : >"$T/loaded/local.agent-operations.relay"
  # A recorded bridge id marks its in-app step done.
  sed "s/^mailroom-claude\(${TAB}[^${TAB}]*${TAB}[^${TAB}]*${TAB}\)pending/mailroom-claude\1sid-b/" \
    "$T/ops/oracle/operators/REGISTRY.tsv" >"$T/reg" && mv "$T/reg" "$T/ops/oracle/operators/REGISTRY.tsv"
  run install.sh host
  assert_has "$T/out" '[done]  Claude: the Mailroom session'
}

test_check_host_flags_app_nap_and_throttled_latency_jobs() {
  fresh
  fake_defaults
  : >"$T/defaults/com.openai.codex"
  mkdir -p "$T/agents"
  printf '<plist><dict><key>Label</key><string>local.agent-operations.relay</string><key>ProcessType</key><string>Background</string></dict></plist>\n' >"$T/agents/a.plist"
  printf '<plist><dict><key>Label</key><string>org.example.ci-forwarder</string><key>LowPriorityIO</key><true/></dict></plist>\n' >"$T/agents/b.plist"
  printf '<plist><dict><key>Label</key><string>org.example.backup</string><key>ProcessType</key><string>Background</string></dict></plist>\n' >"$T/agents/c.plist"
  printf '<plist><dict><key>Label</key><string>local.agent-operations.tick</string><key>EnvironmentVariables</key><dict><key>ProcessType</key><string>Standard</string></dict><key>ProcessType</key><string>Background</string></dict></plist>\n' >"$T/agents/d.plist"
  printf '<plist><dict><key>Label</key><string>local.agent-operations.x</string><key>EnvironmentVariables</key><dict><key>ProcessType</key><string>Background</string></dict></dict></plist>\n' >"$T/agents/e.plist"
  mkdir -p "$T/cfg"
  printf 'host_launchd_dirs=%s\nhost_latency_jobs=*agent-operations* org.example.ci-*\n' "$T/agents" >"$T/cfg/profile"
  run check.sh host
  assert_rc 1
  assert_has "$T/out" "app-nap: com.openai.codex"
  assert_lacks "$T/out" "claudefordesktop"
  assert_has "$T/out" "a.plist: local.agent-operations.relay: ProcessType Background"
  assert_has "$T/out" "b.plist: org.example.ci-forwarder: LowPriorityIO true"
  assert_lacks "$T/out" "org.example.backup"
  assert_has "$T/out" "d.plist: local.agent-operations.tick: ProcessType Background"
  assert_lacks "$T/out" "e.plist"
}

test_bridge_gets_its_own_home_and_a_reserved_registry_row() {
  oracle_home
  run install.sh bridge claude
  assert_rc 0
  assert_has "$T/ops/mailroom-claude/AGENTS.md" "mailroom.sh file claude --wait"
  assert_has "$T/ops/mailroom-claude/CLAUDE.md" "@AGENTS.md"
  assert_has "$T/ops/oracle/operators/REGISTRY.tsv" "mailroom-claude${TAB}Mailroom${TAB}"
  run install.sh bridge codex --home "$T/ops/bridge-x"
  assert_rc 0
  assert_has "$T/ops/bridge-x/AGENTS.md" "mailroom.sh arm-codex"
  assert_no_file "$T/ops/bridge-x/CLAUDE.md"
  run install.sh operator mailroom-codex
  assert_rc 2
  assert_has "$T/err" "reserved for a mailroom bridge"
  ln -s "$KIT_DIR" "$T/kitlink"
  run install.sh bridge claude --home "$T/kitlink/private-bridge"
  assert_rc 2
  assert_has "$T/err" "outside the kit checkout"
  assert_no_file "$KIT_DIR/private-bridge"
}

ao_test_main "$0"
