#!/bin/sh
# doorbell-claude.sh - EXPERIMENTAL: tell a Claude Code session "you have
# mail", without the mail.
#
# Usage: doorbell-claude.sh ring SESSION_NAME [SESSION_ID]
#
# Uses the relay_claude transport (lib/vendor-claude.sh): one confined
# headless run whose only job is a single built-in SendMessage call to the
# session with that display name, confirmed from the event stream. The
# message is fixed text: it never carries mail, and it starts no work (the
# session claims its mail at its next turn start). Delivered is not read.
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 delivered (confirmed); 1 delivery failed; 2 unavailable (no
# session name, Claude CLI or jq missing, or relay_claude misconfigured):
# the caller falls back to pickup at the next turn.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

main() {
  case ${1-} in -h | --help) ao_usage; exit 0 ;; ring) ;; *) ao_die "$AO_E_USAGE" "usage: doorbell-claude.sh ring SESSION_NAME [SESSION_ID]" ;; esac
  name=${2-}
  case $name in '' | - | *"$AO_NL"*) ao_msg "no addressable session name"; exit 2 ;; esac
  ao_load
  command -v jq >/dev/null 2>&1 || { ao_msg "jq missing: cannot confirm a delivery"; exit 2; }
  # A misconfigured or missing client is "unavailable", not a failure.
  (ao_role_load relay_claude claude) >/dev/null 2>&1 || { ao_msg "relay_claude unavailable"; exit 2; }
  ao_role_load relay_claude claude
  id=doorbell-$AO_T_STAMP-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
  msg=$(ao_tmp msg) out=$(ao_tmp out)
  printf 'Doorbell (automated, not from the human): you have mail. At your next turn start run mail.sh claim. This message carries no mail and starts no work.\ndoorbell-id: %s\n' "$id" >"$msg"
  if ao_role_deliver "$name" "${3:--}" "$msg" "$out" "$id"; then
    echo "rang: $name ($id)"
    exit 0
  fi
  ao_msg "doorbell failed: $(tail -c 300 "$out" | tr '\n' ' ')"
  exit 1
}

main "$@"
