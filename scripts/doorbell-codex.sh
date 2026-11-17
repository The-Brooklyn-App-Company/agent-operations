#!/bin/sh
# doorbell-codex.sh - EXPERIMENTAL: tell a Codex session "you have mail".
#
# Usage: doorbell-codex.sh ring SESSION_NAME [SESSION_ID]
#
# Off by default: exits 2 (unavailable), so mail is picked up at the
# session's next turn and the caller notifies the human through the chat
# slot. Codex offers no notification-only path the kit may use: a headless
# `codex exec resume` is a full agent turn in that thread, unverified to
# reach a desktop-app thread the human sees, and `codex queue` goes through
# the local app server, which the kit does not use by rule.
#
# With the profile key doorbell_codex=resume, one read-only
# `codex exec resume <SESSION_ID or name>` turn carries the fixed doorbell
# text (relay_codex transport). Experimental and unverified.
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 the resume turn completed; 1 it failed; 2 unavailable.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

main() {
  case ${1-} in -h | --help) ao_usage; exit 0 ;; ring) ;; *) ao_die "$AO_E_USAGE" "usage: doorbell-codex.sh ring SESSION_NAME [SESSION_ID]" ;; esac
  ao_load
  mode=$(ao_cfg doorbell_codex off)
  [ "$mode" = resume ] || { ao_msg "codex doorbell is off (doorbell_codex=$mode)"; exit 2; }
  target=${3:--}
  [ "$target" != - ] || target=${2:--}
  ao_is_name "$target" || { ao_msg "no addressable codex session"; exit 2; }
  (ao_role_load relay_codex codex) >/dev/null 2>&1 || { ao_msg "relay_codex unavailable"; exit 2; }
  ao_role_load relay_codex codex
  id=doorbell-$AO_T_STAMP-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
  msg=$(ao_tmp msg) out=$(ao_tmp out)
  printf 'Doorbell (automated, not from the human): you have mail. Do nothing now; claim it at your next turn start with mail.sh claim. This message carries no mail and starts no work.\ndoorbell-id: %s\n' "$id" >"$msg"
  if ao_role_deliver "${2:--}" "$target" "$msg" "$out" "$id"; then
    echo "rang: $target ($id)"
    exit 0
  fi
  ao_msg "doorbell failed: $(tail -c 300 "$out" | tr '\n' ' ')"
  exit 1
}

main "$@"
