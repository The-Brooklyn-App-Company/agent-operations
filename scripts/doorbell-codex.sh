#!/bin/sh
# doorbell-codex.sh - EXPERIMENTAL: tell a Codex session "you have mail".
#
# Usage: doorbell-codex.sh ring SESSION_NAME [SESSION_ID]
#
# Unavailable in this version: always exits 2, so mail is picked up at the
# session's next turn and mail.sh notifies the human through the chat slot.
# The kit has no Codex delivery transport (lib/vendor-codex.sh has no
# deliver; registry rows on codex read their inbox at turn start). Codex
# offers no notification-only path the kit may use: a headless
# `codex exec resume` is a full agent turn in that thread, unverified to
# reach a desktop-app thread the human sees, and `codex queue` goes through
# the local app server, which the kit does not use by rule.
#
# The profile key doorbell_codex is reserved for a later transport; `off`
# (the default) is the only value today.
#
# Environment: AO_PROFILE.
#
# Exit codes: 2 unavailable, or a usage error.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"

main() {
  case ${1-} in -h | --help) ao_usage; exit 0 ;; ring) ;; *) ao_die "$AO_E_USAGE" "usage: doorbell-codex.sh ring SESSION_NAME [SESSION_ID]" ;; esac
  ao_load --no-state
  mode=$(ao_cfg doorbell_codex off)
  case $mode in
    off) ao_msg "codex doorbell is off (doorbell_codex=off)" ;;
    *) ao_msg "doorbell_codex=$mode is not supported: this kit has no Codex delivery transport (only 'off')" ;;
  esac
  exit 2
}

main "$@"
