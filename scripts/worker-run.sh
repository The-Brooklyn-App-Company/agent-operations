#!/bin/sh
# worker-run.sh - run one cheap, disposable worker job and route its result.
#
# Usage: worker-run.sh [--role PREFIX] JOB RECIPIENT PROMPT_FILE [WORKDIR]
#
# Runs the profile's worker role (or --role PREFIX) once: headless,
# read-only, ephemeral, stdin closed, hard timeout (<role>_timeout), tool
# servers per <role>_mcp_disable. Routing of the result:
#   output is exactly NOTHING, or empty   -> nothing is written
#   any other output                      -> note in RECIPIENT's inbox
#   the run fails or times out            -> note in the Oracle's inbox
#   the role is not configured            -> note in the Oracle's inbox
# The prompt must tell the model to print exactly NOTHING when there is
# nothing worth reporting.
#
# Arguments:
#   JOB          short job name ([A-Za-z0-9._-]), used in notes and logs
#   RECIPIENT    registry key whose inbox receives the result
#   PROMPT_FILE  the full prompt (max 512 KiB)
#   WORKDIR      working directory for the run (default: oracle_home)
#
# Environment: AO_PROFILE. Log: <state_dir>/worker-runs.log.
#
# Exit codes: 0 ran (result routed, or NOTHING); 2 usage or configuration
# error; 4 role not configured; 124 timed out; other non-zero: the
# client's own failure status.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

# worker_is_nothing FILE  True when FILE is empty or exactly NOTHING
# (surrounding whitespace ignored).
worker_is_nothing() {
  awk 'NF { n++; line = $0 }
    END { exit !(n == 0 || (n == 1 && line ~ /^[[:space:]]*NOTHING[[:space:]]*$/)) }' "$1"
}

worker_route() {
  _rc=$1
  ao_log "$AO_STATE/worker-runs.log" "job=$job role=$role client=$R_CLIENT rc=$_rc bytes=$(wc -c <"$out" | tr -d ' ')"
  if [ "$_rc" -ne 0 ]; then
    _why="exit $_rc"
    [ "$_rc" -ne "$AO_E_TIMEOUT" ] || _why="timed out after ${R_TIMEOUT}s"
    {
      printf 'Worker job %s failed (%s) at %s.\n\n' "\`$job\`" "$_why" "$AO_T_STAMP"
      tail -n 5 "$err"
    } | ao_inbox_put "$AO_ORACLE_KEY" "worker-fail-$job" >/dev/null
    return "$_rc"
  fi
  worker_is_nothing "$out" && return 0
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
  workdir=${4:-$AO_HOME}
  ao_registry_has "$recipient" || ao_die "$AO_E_USAGE" "recipient '$recipient' is not in the registry ($AO_REGISTRY)"
  if ! ao_role_load "$role"; then
    ao_note_oracle "role-missing-$role" "Role '$role' is not configured in $AO_PROFILE; worker job \`$job\` was skipped."
    ao_die "$AO_E_ROLE" "role '$role' is not configured; job $job skipped"
  fi
  out=$(ao_tmp out)
  err=$(ao_tmp err)
  ao_role_run "$workdir" "$prompt" "$out" "$err"
  worker_route $?
}

main "$@"
