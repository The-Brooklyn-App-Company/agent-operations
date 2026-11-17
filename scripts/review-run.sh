#!/bin/sh
# review-run.sh - one independent review pass by the profile's reviewer role.
#
# Usage: review-run.sh [--role PREFIX] PROMPT_FILE OUT_FILE [WORKDIR] [EFFORT] [TIMEOUT]
#
# Runs the reviewer role (or --role PREFIX; reviewer_claude and
# reviewer_codex fix their client by name) once with the same safety as worker-run.sh:
# headless, read-only, ephemeral, stdin closed, hard timeout, tool servers
# per reviewer_mcp_disable. The prompt file is the neutral review packet:
# the brief plus the diff or the paths to read, never the implementer's
# reasoning. The reviewer's final answer is written to OUT_FILE only when
# the run succeeds; on failure OUT_FILE is left untouched, so a stale file
# from an earlier round is never mistaken for a new verdict.
#
# Arguments:
#   PROMPT_FILE  the review packet (max 120000 bytes)
#   OUT_FILE     where the review is written
#   WORKDIR      repository or worktree to review (default: current dir)
#   EFFORT       overrides reviewer_effort for this run (e.g. high)
#   TIMEOUT      overrides reviewer_timeout, in seconds
#
# The profile's review_family (cross | same-family | single-model) is
# printed to stderr so it can be recorded with the result.
#
# Environment: AO_PROFILE. No inbox notes: the caller is interactive.
#
# Exit codes: 0 review written; 1 empty answer or write error; 2 usage or
# configuration error; 4 reviewer role not configured; 124 timed out; other
# non-zero: the client's own status.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

main() {
  role=reviewer
  case ${1-} in
    -h | --help) ao_usage; exit 0 ;;
    --role) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--role needs a value"; role=$2; shift 2 ;;
  esac
  [ $# -ge 2 ] && [ $# -le 5 ] || ao_die "$AO_E_USAGE" "usage: review-run.sh [--role PREFIX] PROMPT_FILE OUT_FILE [WORKDIR] [EFFORT] [TIMEOUT]"
  ao_is_name "$role" || ao_die "$AO_E_USAGE" "invalid role '$role'"
  prompt=$1 dest=$2 workdir=${3:-$PWD}
  ao_load --no-state
  fixed=
  case $role in *_claude) fixed=claude ;; *_codex) fixed=codex ;; esac
  ao_role_load "$role" ${fixed:+"$fixed"} || ao_die "$AO_E_ROLE" "role $role is not configured in $AO_PROFILE"
  [ -z "${4-}" ] || R_EFFORT=$4
  [ -z "${5-}" ] || R_TIMEOUT=$5
  case $R_EFFORT in *[!a-z]*) ao_die "$AO_E_USAGE" "effort must be a lowercase word, got '$R_EFFORT'" ;; esac
  ao_is_uint "$R_TIMEOUT" || ao_die "$AO_E_USAGE" "timeout must be an integer, got '$R_TIMEOUT'"
  family=$(ao_cfg review_family cross)
  ao_msg "reviewer role=$role client=$R_CLIENT model=${R_MODEL:-default} effort=${R_EFFORT:-default} review_family=$family"
  out=$(ao_tmp out)
  err=$(ao_tmp err)
  ao_role_run "$workdir" "$prompt" "$out" "$err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -ne "$AO_E_TIMEOUT" ] || ao_msg "timed out after ${R_TIMEOUT}s"
    tail -n 5 "$err" >&2
    exit "$rc"
  fi
  [ -s "$out" ] || ao_die "$AO_E_FAIL" "reviewer exited 0 but wrote no answer; $dest left untouched"
  ao_write_atomic "$dest" <"$out" || ao_die "$AO_E_FAIL" "cannot write $dest"
}

main "$@"
