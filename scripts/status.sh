#!/bin/sh
# status.sh - one line per operator: activity, quiet-list state, inbox depth.
#
# Usage: status.sh [--tsv] [--all]
#
# Columns: key, name, client, state, quiet (until date or -), inbox (pending
# notes). State is idle_min=<n> (minutes since the session's transcript last
# changed), no-transcript, pending (no session id yet) or unknown (the client
# exposes no activity, e.g. file-only). Read-only: writes nothing.
#
# Options:
#   --tsv       tab-separated, no header (for scripts)
#   --all       include the Oracle's own row
#   -h, --help  this text
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 printed; 2 usage or configuration error.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

status_row() {
  [ -n "$all" ] || [ "$OP_KEY" != "$AO_ORACLE_KEY" ] || return 0
  _q=$(ao_quiet_until "$OP_KEY" "$OP_NAME")
  if [ -n "$tsv" ]; then _fmt='%s\t%s\t%s\t%s\t%s\t%s\n'; else _fmt='%-14s %-24s %-9s %-16s %-11s %s\n'; fi
  # shellcheck disable=SC2059 # the format is one of the two literals above
  printf "$_fmt" "$OP_KEY" "$OP_NAME" "$OP_CLIENT" "$(ao_idle_state)" "${_q:--}" "$(ao_inbox_count "$OP_KEY")"
}

main() {
  tsv='' all=''
  while [ $# -gt 0 ]; do
    case $1 in
      --tsv) tsv=1 ;;
      --all) all=1 ;;
      -h | --help) ao_usage; exit 0 ;;
      *) ao_die "$AO_E_USAGE" "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  ao_load --no-state
  [ -n "$tsv" ] || printf '%-14s %-24s %-9s %-16s %-11s %s\n' KEY NAME CLIENT STATE QUIET INBOX
  ao_registry_each status_row
}

main "$@"
