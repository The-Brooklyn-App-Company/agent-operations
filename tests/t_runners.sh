#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_runners.sh - worker-run.sh and review-run.sh: invocation safety, routing,
# failure handling, missing roles.
. "$(dirname -- "$0")/lib.sh"

prompt() { printf '%s\n' "${1:-Check things. Print NOTHING if fine.}" >"$T/prompt.md"; }

test_worker_codex_invocation_is_locked_down() {
  prompt
  run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 0
  for a in plugins apps exec --ephemeral --skip-git-repo-check read-only "$T/home" small-model \
    mcp_servers.trade.enabled=false mcp_servers.ui.enabled=false "Check things. Print NOTHING if fine."; do
    assert_has "$FAKE_LOG" "arg: $a"
  done
  assert_has "$FAKE_LOG" "stdin: eof"
  assert_lacks "$FAKE_LOG" "model_reasoning_effort"
}

test_worker_codex_switches_off_every_configured_server() {
  prompt
  FAKE_MCP='[{"name":"mail-sender","enabled":true},{"name":"broker_x","enabled":false}]' \
    run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 0
  for n in mail-sender broker_x trade ui; do
    assert_has "$FAKE_LOG" "arg: mcp_servers.$n.enabled=false"
  done
}

test_worker_codex_fails_closed_without_a_server_list() {
  prompt
  FAKE_MCP=fail run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 2
  assert_no_file "$FAKE_LOG"
  assert_has "$(ls "$T/home/inbox/oracle"/*-worker-fail-audit.md)" "cannot list Codex tool servers"
  for bad in '[{"name":"bad name;x"}]' '[{"name":"two words"}]' null '{}'; do
    FAKE_MCP=$bad run worker-run.sh audit alpha "$T/prompt.md"
    assert_rc 2
    assert_no_file "$FAKE_LOG"
  done
  FAKE_MCP='[]' run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 0
}

test_worker_result_goes_to_recipient() {
  prompt
  FAKE_OUTPUT="finding one" run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 0
  assert_count "$T/home/inbox/alpha" 1
  f=$(ls "$T/home/inbox/alpha"/*-audit.md)
  assert_has "$f" 'From worker job `audit` at'
  assert_has "$f" "finding one"
  assert_has "$T/state/worker-runs.log" "job=audit role=worker client=codex rc=0"
}

test_worker_nothing_writes_nothing() {
  prompt
  FAKE_MODE=nothing run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 0
  assert_no_file "$T/home/inbox/alpha"
}

test_worker_empty_answer_is_a_failure() {
  prompt
  FAKE_MODE=empty run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 1
  assert_no_file "$T/home/inbox/alpha"
  assert_has "$(ls "$T/home/inbox/oracle"/*-worker-fail-audit.md)" "exit 0 but no answer"
}

test_worker_preflight_failures_reach_oracle() {
  prompt
  profile_set worker_cmd /nonexistent/codex
  run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 2
  assert_has "$(ls "$T/home/inbox/oracle"/*-worker-fail-audit.md)" "not executable"
  rm -f "$T/home/inbox/oracle"/*
  profile_set worker_cmd codex
  run worker-run.sh audit alpha "$T/missing.md"
  assert_rc 2
  assert_has "$(ls "$T/home/inbox/oracle"/*-worker-fail-audit.md)" "prompt file not readable"
  rm -f "$T/home/inbox/oracle"/*
  profile_set worker_timeout soon
  run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 2
  assert_count "$T/home/inbox/oracle" 1
}

test_worker_nothing_tolerates_decoration_only() {
  prompt
  FAKE_OUTPUT="NOTHING
but also one finding" run worker-run.sh audit alpha "$T/prompt.md"
  assert_count "$T/home/inbox/alpha" 1
  FAKE_OUTPUT="  \`NOTHING.\`" run worker-run.sh audit2 alpha "$T/prompt.md"
  assert_count "$T/home/inbox/alpha" 1
}

test_worker_unknown_recipient_reaches_oracle() {
  prompt
  run worker-run.sh audit nobody "$T/prompt.md"
  assert_rc 2
  assert_has "$(ls "$T/home/inbox/oracle"/*-worker-fail-audit.md)" "not in the registry"
}

test_worker_failure_goes_to_oracle() {
  prompt
  FAKE_MODE=fail run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 7
  assert_no_file "$T/home/inbox/alpha"
  f=$(ls "$T/home/inbox/oracle"/*-worker-fail-audit.md)
  assert_has "$f" 'Worker job `audit` failed (exit 7)'
  assert_has "$f" "fake failure: model unavailable"
}

test_worker_timeout() {
  prompt
  profile_set worker_timeout 1
  AO_TIMEOUT_BIN=none FAKE_MODE=hang run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 124
  assert_has "$(ls "$T/home/inbox/oracle"/*-worker-fail-audit.md)" "timed out after 1s"
}

test_worker_role_missing_degrades_loudly() {
  prompt
  profile_set worker_client none
  run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 4
  assert_has "$(ls "$T/home/inbox/oracle"/*-role-missing-worker.md)" "Role 'worker' is not configured"
  assert_no_file "$FAKE_LOG"
}

test_worker_rejects_unknown_recipient_and_bad_job() {
  prompt
  run worker-run.sh "../evil" alpha "$T/prompt.md"
  assert_rc 2
  assert_no_file "$FAKE_LOG"
}

test_worker_claude_invocation() {
  profile_set worker_client claude
  profile_set worker_model haiku
  prompt "-starts with a dash"
  run worker-run.sh audit alpha "$T/prompt.md" "$T/proj/alpha"
  assert_rc 0
  assert_has "$FAKE_LOG" "== claude"
  assert_has "$FAKE_LOG" "cwd: $T/proj/alpha"
  assert_has "$FAKE_LOG" "arg:  -starts with a dash"
  for a in -p --no-session-persistence --restricted --strict-mcp-config --tools Read,Grep,Glob haiku \
    '{"disableAllHooks":true}'; do
    assert_has "$FAKE_LOG" "arg: $a"
  done
  # The prompt is the first argument after -p, ahead of variadic options.
  assert_eq "$(sed -n '/^arg: -p$/{n;p;}' "$FAKE_LOG")" "arg:  -starts with a dash"
}

test_claude_runs_accept_only_read_only_tools() {
  profile_set worker_client claude
  profile_set worker_model haiku
  prompt
  for tools in default SendMessage Read,Bash; do
    profile_set worker_tools "$tools"
    run worker-run.sh audit alpha "$T/prompt.md"
    assert_rc 2
    assert_no_file "$FAKE_LOG"
  done
  set -- "$T/home/inbox/oracle"/*-worker-fail-audit*.md
  assert_has "$1" "is not read-only"
  profile_set worker_tools Read
  run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: Read"
}

test_codex_lists_servers_from_the_run_directory() {
  prompt
  mv "$T/bin/codex" "$T/bin/codex.real"
  printf '#!/bin/sh\ncase " $* " in *" mcp list "*) pwd -P >"$FAKE_LOG.mcpdir"; echo "[]"; exit 0 ;; esac\nexec "%s" "$@"\n' "$T/bin/codex.real" >"$T/bin/codex"
  chmod +x "$T/bin/codex"
  run worker-run.sh audit alpha "$T/prompt.md" "$T/proj/alpha"
  assert_rc 0
  assert_eq "$(cat "$FAKE_LOG.mcpdir")" "$T/proj/alpha" "listing directory"
}

test_worker_custom_contract() {
  profile_set worker_client custom
  profile_set worker_cmd "$T/bin/agent"
  prompt
  FAKE_OUTPUT="custom finding" run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: run"
  assert_has "$FAKE_LOG" "env: AO_ROLE=worker AO_MODEL=small-model"
  assert_has "$(ls "$T/home/inbox/alpha"/*-audit.md)" "custom finding"
}

test_worker_alternate_role() {
  prompt
  run worker-run.sh --role reviewer audit alpha "$T/prompt.md"
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: big-model"
}

test_worker_rejects_bad_profile_values() {
  profile_set worker_model 'bad model;rm'
  prompt
  run worker-run.sh audit alpha "$T/prompt.md"
  assert_rc 2
  assert_has "$T/err" "invalid model id"
  assert_no_file "$FAKE_LOG"
}

test_review_writes_output() {
  prompt "Review this diff."
  FAKE_OUTPUT="verdict: clean" run review-run.sh "$T/prompt.md" "$T/review.md" "$T/proj/alpha"
  assert_rc 0
  assert_has "$T/review.md" "verdict: clean"
  assert_has "$FAKE_LOG" 'arg: model_reasoning_effort="high"'
  assert_has "$FAKE_LOG" "arg: big-model"
  assert_has "$FAKE_LOG" "arg: $T/proj/alpha"
  assert_has "$T/err" "review_family=cross"
}

test_review_overrides_effort_and_timeout() {
  prompt
  run review-run.sh "$T/prompt.md" "$T/review.md" "$T/proj/alpha" xhigh 30
  assert_rc 0
  assert_has "$FAKE_LOG" 'arg: model_reasoning_effort="xhigh"'
  run review-run.sh "$T/prompt.md" "$T/review.md" "$T/proj/alpha" 'x"y' 30
  assert_rc 2
}

test_review_failure_leaves_old_output() {
  prompt
  echo "old verdict" >"$T/review.md"
  FAKE_MODE=fail run review-run.sh "$T/prompt.md" "$T/review.md"
  assert_rc 7
  assert_eq "$(cat "$T/review.md")" "old verdict"
  FAKE_MODE=empty run review-run.sh "$T/prompt.md" "$T/review.md"
  assert_rc 1
  assert_eq "$(cat "$T/review.md")" "old verdict"
}

test_review_timeout() {
  prompt
  FAKE_MODE=hang run review-run.sh "$T/prompt.md" "$T/review.md" "$T" high 1
  assert_rc 124
  assert_has "$T/err" "timed out after 1s"
  assert_no_file "$T/review.md"
}

test_review_per_family_role() {
  profile_set reviewer_claude_model strong-claude
  printf 'Review this.\n' >"$T/packet.md"
  run review-run.sh --role reviewer_claude "$T/packet.md" "$T/review.md" "$T/proj/alpha"
  assert_rc 0
  assert_has "$FAKE_LOG" "== claude"
  assert_has "$FAKE_LOG" "arg: strong-claude"
  assert_has "$FAKE_LOG" "arg: --restricted"
  assert_has "$T/err" "role=reviewer_claude client=claude"
}

test_review_role_missing() {
  profile_set reviewer_client none
  prompt
  run review-run.sh "$T/prompt.md" "$T/review.md"
  assert_rc 4
}

ao_test_main "$0"
