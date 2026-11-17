#!/bin/sh
# none.sh - the `none` adapter for every slot (see CONTRACT.md).
#
# Usage: none.sh VERB [ARG...]
#
# poll, pr-poll, status, link, review-request: nothing to report (exit 0,
# no output). notify: a note in the Oracle's inbox (needs AO_PROFILE).
# get: no secrets store, so unavailable (exit 2).
#
# Exit codes: 0 success; 2 unavailable; 3 misconfigured or unknown verb.
set -u
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
case ${1-} in
  poll | pr-poll | status | link | review-request) exit 0 ;;
  notify)
    [ $# -ge 3 ] || { echo "usage: none.sh notify URGENCY TEXT" >&2; exit 3; }
    printf '[%s] %s\n' "$2" "$3" |
      "$here/../scripts/inbox-put.sh" "${AO_ORACLE_KEY:-oracle}" notify >/dev/null || exit 3 ;;
  get) exit 2 ;;
  -h | --help) sed -n '2,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "$0" ;;
  *) echo "none.sh: unknown verb '${1-}'" >&2; exit 3 ;;
esac
