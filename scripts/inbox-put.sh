#!/bin/sh
# inbox-put.sh - write a note into a session's inbox, atomically.
#
# Usage: inbox-put.sh KEY SLUG < note.md
#
# Reads the note from stdin and writes <inbox_dir>/KEY/<stamp>-SLUG.md via a
# temp file and rename, so the relay never sees a partial note. Prints the
# path written. This is the interface for hooks and adapters (a tracker
# `poll`, a watch, a CI check) that need to tell a session something.
#
# Arguments:
#   KEY   registry key of the recipient
#   SLUG  short description for the file name (sanitized)
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 written; 1 write failed; 2 usage, unknown key or empty note.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"

main() {
  case ${1-} in -h | --help) ao_usage; exit 0 ;; esac
  [ $# -eq 2 ] || ao_die "$AO_E_USAGE" "usage: inbox-put.sh KEY SLUG < note.md"
  ao_load --no-state
  ao_registry_has "$1" || ao_die "$AO_E_USAGE" "'$1' is not in the registry ($AO_REGISTRY)"
  body=$(ao_tmp body)
  cat >"$body"
  [ -s "$body" ] || ao_die "$AO_E_USAGE" "empty note; nothing written"
  ao_inbox_put "$1" "$2" <"$body"
}

main "$@"
