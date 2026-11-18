#!/bin/sh
# worker-run.sh - run one cheap, disposable worker job and route its result.
#
# Usage: worker-run.sh [--role PREFIX] JOB RECIPIENT PROMPT_FILE [WORKDIR]
#
# Runs the profile's worker role (or --role PREFIX) once: headless,
# read-only, ephemeral, stdin closed, hard timeout (<role>_timeout), tool
# servers per <role>_mcp_disable. Routing of the result:
#   output is NOTHING (blank space, quotes,
#   backticks and a final period ignored)  -> nothing is written
#   any other output                       -> note in RECIPIENT's inbox
#   the run fails, times out, or exits 0
#   without any output                     -> note in the Oracle's inbox
#   the role is missing or misconfigured, the
#   recipient unknown, or the prompt or
#   workdir unusable                       -> note in the Oracle's inbox
# The prompt must tell the model to print exactly NOTHING when there is
# nothing worth reporting.
#
# Arguments:
#   JOB          short job name ([A-Za-z0-9._-]), used in notes and logs
#   RECIPIENT    registry key whose inbox receives the result
#   PROMPT_FILE  the full prompt (max 120000 bytes)
#   WORKDIR      working directory for the run (default: oracle_home)
#
# Environment: AO_PROFILE. Log: <state_dir>/worker-runs.log.
#
# Exit codes: 0 ran (result routed, or NOTHING); 1 empty answer; 2 usage or
# configuration error; 4 role not configured; 124 timed out; other
# non-zero: the client's own failure status.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

# worker_is_empty FILE  True when FILE holds nothing but whitespace.
worker_is_empty() {
  ! grep -q '[^[:space:]]' "$1"
}

# worker_fail SUMMARY [DETAIL_FILE]  Tell the Oracle a job did not run clean.
worker_fail() {
  {
    printf 'Worker job %s failed (%s) at %s.\n' "\`$job\`" "$1" "$AO_T_STAMP"
    if [ -n "${2-}" ] && [ -s "$2" ]; then
      printf '\n'
      tail -n 5 "$2"
    fi
  } | ao_inbox_put "$AO_ORACLE_KEY" "worker-fail-$job" >/dev/null
}

# worker_on_die CODE MESSAGE  ao_die hook: configuration and preflight
# failures of a scheduled job reach the Oracle too.
worker_on_die() {
  worker_fail "$2"
}

worker_route() {
  _rc=$1
  ao_log "$AO_STATE/worker-runs.log" "job=$job role=$role client=$R_CLIENT rc=$_rc bytes=$(wc -c <"$out" | tr -d ' ')"
  if [ "$_rc" -ne 0 ]; then
    _why="exit $_rc"
    [ "$_rc" -ne "$AO_E_TIMEOUT" ] || _why="timed out after ${R_TIMEOUT}s"
    worker_fail "$_why" "$err"
    return "$_rc"
  fi
  if worker_is_empty "$out"; then
    worker_fail "exit 0 but no answer" "$err"
    return "$AO_E_FAIL"
  fi
  ao_is_nothing "$out" && return 0
  {
    printf 'From worker job %s at %s:\n\n' "\`$job\`" "$AO_T_STAMP"
    cat "$out"
  } | ao_inbox_put "$recipient" "$job" >/dev/null
}

main() {
  role=worker
  case ${1-} in
    -h | --help) ao_usage; exit 0 ;;
    --role) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--role needs a value"; role=$2; shift 2 ;;
  esac
  [ $# -ge 3 ] && [ $# -le 4 ] || ao_die "$AO_E_USAGE" "usage: worker-run.sh [--role PREFIX] JOB RECIPIENT PROMPT_FILE [WORKDIR]"
  job=$1 recipient=$2 prompt=$3
  ao_is_name "$job" || ao_die "$AO_E_USAGE" "invalid job name '$job'"
  ao_is_name "$role" || ao_die "$AO_E_USAGE" "invalid role '$role'"
  ao_load
  AO_ON_DIE=worker_on_die
  workdir=${4:-$AO_HOME}
  ao_registry_has "$recipient" || ao_die "$AO_E_USAGE" "recipient '$recipient' is not in the registry ($AO_REGISTRY)"
  if ! ao_role_load "$role"; then
    AO_ON_DIE=
    ao_note_oracle "role-missing-$role" "Role '$role' is not configured in $AO_PROFILE; worker job \`$job\` was skipped."
    ao_die "$AO_E_ROLE" "role '$role' is not configured; job $job skipped"
  fi
  out=$(ao_tmp out)
  err=$(ao_tmp err)
  ao_role_run "$workdir" "$prompt" "$out" "$err"
  worker_route $?
}

main "$@"
