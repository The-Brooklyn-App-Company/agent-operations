#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_bootstrap.sh - the guided first run, unattended (--yes): the Oracle
# home, the profile, the host, the toehold, the Oracle lock, and the
# checklist that ends with a test note's delivery.
. "$(dirname -- "$0")/lib.sh"

fresh() {
  AO_PROFILE=$T/cfg/profile AO_APPS_DIR=$T/Applications
  GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
  GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
  export AO_PROFILE AO_APPS_DIR GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  # Fakes: defaults and launchctl only record; the Codex app bundle holds a
  # node and the app tool server.
  mkdir -p "$T/defaults" "$T/loaded"
  cat >"$T/bin/defaults" <<EOF
#!/bin/sh
d=$T/defaults
case \$1 in
  read) [ -e "\$d/\$2" ] || exit 1; [ \$# -eq 2 ] && exit 0; cat "\$d/\$2.\$3" 2>/dev/null || exit 1 ;;
  write) : >"\$d/\$2"; echo 1 >"\$d/\$2.\$3"; echo "write \$*" >>"\$d/log" ;;
esac
EOF
  cat >"$T/bin/launchctl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/launchctl.log"
case \$1 in
  print) [ -e "$T/loaded/\${2##*/}" ] ;;
  bootstrap) f=\${3##*/}; : >"$T/loaded/\${f%.plist}" ;;
  bootout) rm -f "$T/loaded/\${2##*/}" ;;
esac
EOF
  chmod +x "$T/bin/defaults" "$T/bin/launchctl"
  r=$T/Applications/Codex.app/Contents/Resources
  mkdir -p "$r/bin" "$r/plugins/codex-app-tools"
  printf '#!/bin/sh\n' >"$r/bin/node" && chmod +x "$r/bin/node"
  : >"$r/plugins/codex-app-tools/server.mjs"
}

# The profile's PATH must find the fakes first: never the real defaults or
# launchctl (a test must not touch the real launchd domain).
SETS='--set relay_claude_model=small-c --set worker_model=small-x --set reviewer_model=big-x
--set implementer_claude_model=big-c --set implementer_codex_model=big-x
--set reviewer_claude_model=big-c --set reviewer_codex_model=big-x'

test_first_run_sets_up_everything_then_lists_the_human_steps() {
  [ "$(uname -s)" = Darwin ] || { echo "    (skipped: launchd units are macOS)"; return 0; }
  fresh
  # shellcheck disable=SC2086 # deliberate split of the option list
  run bootstrap.sh --yes --client claude --home "$T/ops/oracle" --tz Etc/UTC --set "path=$T/bin:/usr/bin:/bin" $SETS
  assert_rc 1
  assert_has "$T/launchctl.log" "bootstrap gui/"
  # The choices are printed, the home and profile exist, the host is set.
  assert_has "$T/out" "Client you start the Oracle on (claude or codex): claude"
  assert_file "$T/ops/oracle/operators/REGISTRY.tsv"
  assert_has "$AO_PROFILE" "owner_tz=Etc/UTC"
  assert_has "$AO_PROFILE" "implementer_codex_model=big-x"
  assert_has "$AO_PROFILE" "bridge_codex_server=$T/Applications/Codex.app/Contents/Resources/plugins/codex-app-tools/server.mjs"
  assert_has "$AO_PROFILE" "bridge_codex_node=$T/Applications/Codex.app/Contents/Resources/bin/node"
  assert_has "$T/defaults/log" "write com.openai.codex NSAppSleepDisabled -bool YES"
  assert_file "$T/user/Library/LaunchAgents/local.agent-operations.relay.plist"
  assert_has "$T/ops/mailroom-claude/AGENTS.md" "Mailroom (Claude): your whole duty"
  assert_has "$T/ops/oracle/operators/REGISTRY.tsv" "mailroom-codex${TAB}Mailroom${TAB}"
  # The toehold: the other client's files in every home.
  assert_has "$T/ops/oracle/operator.conf" "session.codex="
  # The checklist: what a person does, each with its check.
  assert_has "$T/out" "PASS  profile"
  assert_has "$T/out" "TODO  oracle        start a claude session in $T/ops/oracle"
  assert_has "$T/out" "TODO  oracle-lock"
  assert_has "$T/out" "TODO  sign-in"
  assert_has "$T/out" "TODO  claude-mailroom in Claude, start a session in"
  assert_has "$T/out" "TODO  codex-mailroom"
  assert_has "$T/out" "WAIT  round-trip"
  # Again, with the Oracle's session: recorded and the lock taken (unattended
  # runs take the confirmed default).
  run bootstrap.sh --yes --oracle-session sid-oracle --home "$T/ops/oracle"
  assert_rc 1
  assert_has "$T/ops/oracle/operators/ORACLE-LOCK" "holder=claude"
  assert_has "$T/out" "PASS  oracle-lock   claude"
  # The person's steps, then the proof.
  run operator.sh session mailroom-claude sid-bridge
  run operator.sh session mailroom-codex thread-bridge
  for m in sign-in restart-apps pins hooks; do run bootstrap.sh mark "$m"; assert_rc 0; done
  sleep 300 >/dev/null 2>&1 &
  live=$!
  mkdir -p "$T/ops/oracle/inbox/.mailroom/codex/.watcher"
  printf '2026-11-19T00:00:00Z %s\n' "$live" >"$T/ops/oracle/inbox/.mailroom/codex/.watcher/heartbeat"
  run bootstrap.sh status
  assert_rc 1
  assert_has "$T/out" "PASS  codex-watcher armed"
  assert_has "$T/out" "WAIT  round-trip    a test note went to the Oracle"
  ls "$T/ops/oracle/inbox/oracle"/*bootstrap-check.md >/dev/null 2>&1 || _fail "no test note"
  # Only a delivered ring that lists the test note counts.
  d=$T/ops/oracle/inbox/.mailroom/claude/delivered
  mkdir -p "$d"
  printf -- '- x-oracle-other-note.md\n' >"$d/sid-oracle--oracle-1.md"
  printf '2026-11-19T00:00:00Z\t%s\tsid-oracle--oracle-1.md\tt2-bridge\tsend\tok\t900\t-\n' "$(($(date +%s) + 5))" >>"$d/log.tsv"
  run bootstrap.sh status
  assert_has "$T/out" "WAIT  round-trip"
  tn=$(ls "$T/ops/oracle/inbox/oracle"/*bootstrap-check.md)
  tn=${tn##*/}
  printf -- '- 20261119T000000-oracle-%s\n' "$tn" >"$d/sid-oracle--oracle-2.md"
  printf '2026-11-19T00:00:00Z\t%s\tsid-oracle--oracle-2.md\tt2-bridge\tsend\tok\t900\t-\n' "$(($(date +%s) + 5))" >>"$d/log.tsv"
  run bootstrap.sh status
  kill "$live" 2>/dev/null
  assert_rc 0
  assert_has "$T/out" "PASS  round-trip    the test note reached the Oracle"
}

test_choices_are_validated_and_marks_are_fixed() {
  fresh
  run bootstrap.sh --yes --client claude --home relative/path
  assert_rc 2
  assert_no_file "$AO_PROFILE"
  run bootstrap.sh --yes --client other --home "$T/ops/oracle"
  assert_rc 2
}

ao_test_main "$0"
