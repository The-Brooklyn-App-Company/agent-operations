#!/bin/sh
# relay.sh - deliver inbox notes to the sessions that own them.
#
# Usage: relay.sh [--dry-run] [--key KEY]
#
# For every registry row whose inbox (<inbox_dir>/<key>/*.md) has notes, the
# notes are bundled into one message, labelled as automated (relay_label),
# and handed to the row's client transport: claude, codex (experimental) or
# custom. Rows whose client is `file-only` are left alone: that session reads
# its inbox at turn start. Delivered notes move to <sent_dir> as
# <stamp>-<key>-<name>; failed deliveries stay put and retry next run. The
# relay is transport only: it never interprets, filters or acts on notes.
#
# Options:
#   --dry-run   show what would be delivered; deliver and move nothing
#   --key KEY   only this registry key
#   -h, --help  this text
#
# Writers must create notes atomically (write elsewhere, then mv), or use
# inbox-put.sh. Each note is cut at relay_max_bytes (default 4000) in the
# message, with a pointer to the archived full text.
#
# Environment: AO_PROFILE (profile path). Log: <state_dir>/relay.log.
#
# Exit codes: 0 delivered or nothing to do; 1 a delivery failed; 2 usage or
# configuration error; 3 another relay is running.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

dry_run=
only_key=
failures=0

# relay_compose MSG_FILE NOTE...  Write the bundled message for one inbox.
relay_compose() {
  _msg=$1
  shift
  {
    printf '%s\n' "$label"
    for _f in "$@"; do
      _size=$(wc -c <"$_f" | tr -d ' ')
      printf -- '--- %s\n' "${_f##*/}"
      head -c "$max_bytes" "$_f"
      if [ "$_size" -gt "$max_bytes" ]; then
        printf '\n[cut at %s of %s bytes; full note: %s]' "$max_bytes" "$_size" "$(relay_sent_path "$_f")"
      fi
      printf '\n'
    done
  } >"$_msg"
}

relay_sent_path() {
  printf '%s/%s-%s-%s\n' "$AO_SENT" "$AO_T_STAMP" "$OP_KEY" "${1##*/}"
}

# relay_archive NOTE...  Move delivered notes to the sent archive.
relay_archive() {
  mkdir -p "$AO_SENT" || return 1
  for _f in "$@"; do
    mv -f "$_f" "$(relay_sent_path "$_f")" || ao_warn "delivered but could not archive $_f"
  done
}

# relay_row  Registry callback: deliver one operator's inbox, if non-empty.
relay_row() {
  [ -z "$only_key" ] || [ "$OP_KEY" = "$only_key" ] || return 0
  set -- "$AO_INBOX/$OP_KEY"/*.md
  [ -f "$1" ] || return 0
  case $OP_CLIENT in
    file-only) return 0 ;;
    claude | codex | custom) ;;
    *) ao_log "$log" "to=$OP_KEY FAILED: unknown client '$OP_CLIENT'"; failures=$((failures + 1)); return 0 ;;
  esac
  if ! ao_gate relay; then
    ao_log "$log" "to=$OP_KEY held by gate"
    return 0
  fi
  if [ -n "$dry_run" ]; then
    printf 'would relay %s note(s) to %s via %s\n' "$#" "$OP_KEY" "$OP_CLIENT"
    return 0
  fi
  relay_compose "$msg" "$@"
  : >"$out"
  # The subshell keeps one transport's configuration error from stopping
  # delivery to the other rows.
  if (ao_role_load "relay_$OP_CLIENT" "$OP_CLIENT" && ao_role_deliver "$OP_NAME" "$OP_SID" "$msg" "$out"); then
    relay_archive "$@"
    ao_log "$log" "to=$OP_KEY via=$OP_CLIENT files=$# ok"
  else
    ao_log "$log" "to=$OP_KEY via=$OP_CLIENT FAILED: $(tail -c 300 "$out" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry_run=1 ;;
      --key) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--key needs a value"; only_key=$2; shift ;;
      -h | --help) ao_usage; exit 0 ;;
      *) ao_die "$AO_E_USAGE" "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  ao_load
  ao_lock relay || { ao_msg "another relay is running; skipping"; exit "$AO_E_BUSY"; }
  label=$(ao_cfg relay_label 'Relay (automated inbox, not from the human):')
  max_bytes=$(ao_cfg_uint relay_max_bytes 4000) || exit
  log=$AO_STATE/relay.log
  msg=$(ao_tmp msg)
  out=$(ao_tmp out)
  ao_registry_each relay_row
  [ "$failures" -eq 0 ] || exit "$AO_E_FAIL"
}

main "$@"
