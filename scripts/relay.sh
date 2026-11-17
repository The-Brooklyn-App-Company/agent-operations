#!/bin/sh
# relay.sh - deliver inbox notes to the sessions that own them.
#
# Usage: relay.sh [--dry-run] [--key KEY]
#
# For every registry row whose inbox (<inbox_dir>/<key>/*.md) has notes, the
# notes are bundled into messages of at most relay_max_message_bytes,
# labelled as automated (relay_label), tagged with a unique relay id, and
# handed to the row's client transport: claude, codex (experimental) or
# custom. Rows whose client is `file-only` are left alone: that session
# reads its inbox at turn start. Notes are first claimed (renamed into the
# inbox's hidden .claimed/ folder), so a note rewritten during delivery is
# never archived unsent. Each confirmed batch moves to <sent_dir> as
# <stamp>-<key>-<name> (never overwriting); on a failed batch every claimed
# note returns to the inbox for the next run. Notes left claimed by an
# interrupted run are returned first. Delivery is at-least-once. The relay is
# transport only: it never interprets, filters or acts on notes.
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
# Exit codes: 0 delivered or nothing to do; 1 a delivery or archive failed;
# 2 usage or configuration error; 3 another relay is running.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

dry_run=
only_key=
failures=0
batch_no=0
# Room for a note's header and cut pointer on top of relay_max_bytes.
NOTE_OVERHEAD=512

relay_sent_base() {
  printf '%s/%s-%s-%s\n' "$AO_SENT" "$AO_T_STAMP" "$OP_KEY" "${1##*/}"
}

# relay_append NOTE  Add one note to the message being built. The note joins
# the batch only once its whole part was read and written; an unreadable
# note is left claimed (returned to the inbox at the end) and counted.
relay_append() {
  if ! _size=$(wc -c <"$1" 2>/dev/null | tr -d ' ') || ! ao_is_uint "$_size" ||
    ! _body=$(head -c "$max_bytes" "$1" 2>/dev/null && echo x); then
    ao_log "$log" "to=$OP_KEY FAILED: cannot read ${1##*/}; left for the next run"
    failures=$((failures + 1))
    return 0
  fi
  _body=${_body%x}
  _part=$(printf -- '--- %s\n%s' "${1##*/}" "$_body"; echo x)
  _part=${_part%x}
  if [ "$_size" -gt "$max_bytes" ]; then
    _part=$_part$(printf '\n[cut at %s of %s bytes; full note: %s]' "$max_bytes" "$_size" "$(relay_sent_base "$1")")
  fi
  printf '%s\n' "$_part" >>"$msg" || ao_die "$AO_E_FAIL" "cannot write the relay message"
  printf '%s\n' "$1" >>"$batch" || ao_die "$AO_E_FAIL" "cannot write the relay batch list"
}

relay_start() {
  printf '%s\n' "$label" >"$msg"
  : >"$batch"
}

# relay_archive LIST  Move delivered notes (paths in LIST) to the sent
# archive; returns 1 if any could not be moved.
relay_archive() {
  mkdir -p "$AO_SENT" || return 1
  _ok=0
  while IFS= read -r _f; do
    [ -f "$_f" ] || continue
    _base=$(relay_sent_base "$_f")
    ao_place "$_f" "${_base%.md}" .md >/dev/null || { ao_warn "delivered but not archived: $_f"; _ok=1; }
  done <"$1"
  return "$_ok"
}

# relay_flush  Deliver the message built so far; archive it on success.
relay_flush() {
  batch_no=$((batch_no + 1))
  _id=$AO_T_STAMP-$OP_KEY-$$-$batch_no
  _count=$(wc -l <"$batch" | tr -d ' ')
  printf 'relay-id: %s\n' "$_id" >>"$msg"
  : >"$out"
  # The subshell keeps one transport's configuration error from stopping
  # delivery to the other rows.
  if ! (ao_role_load "relay_$OP_CLIENT" "$OP_CLIENT" && ao_role_deliver "$OP_NAME" "$OP_SID" "$msg" "$out" "$_id"); then
    ao_log "$log" "to=$OP_KEY via=$OP_CLIENT id=$_id FAILED: $(tail -c 300 "$out" | tr '\n' ' ')"
    failures=$((failures + 1))
    return 1
  fi
  # Record the acknowledgement first, so a failed archive is finished later
  # without sending the batch again.
  cat "$batch" >>"$claim/.acked"
  if relay_archive "$batch"; then
    ao_log "$log" "to=$OP_KEY via=$OP_CLIENT id=$_id files=$_count ok"
  else
    ao_log "$log" "to=$OP_KEY via=$OP_CLIENT id=$_id files=$_count delivered, ARCHIVE FAILED (archiving retried next run, not re-sent)"
    failures=$((failures + 1))
  fi
}

# relay_unclaim  Finish archiving notes already acknowledged (listed in
# .claimed/.acked), and return every other claimed note to the inbox
# (never overwriting).
relay_unclaim() {
  if [ -f "$claim/.acked" ]; then
    relay_archive "$claim/.acked" || failures=$((failures + 1))
  fi
  for _c in "$claim"/*.md; do
    [ -f "$_c" ] || continue
    # Acknowledged but not yet archived: keep it claimed, never re-send.
    if [ -f "$claim/.acked" ] && grep -Fxq -- "$_c" "$claim/.acked"; then continue; fi
    _n=${_c##*/}
    ao_place "$_c" "$AO_INBOX/$OP_KEY/${_n%.md}" .md >/dev/null ||
      ao_warn "cannot return claimed note $_c to the inbox"
  done
  set -- "$claim"/*.md
  [ -f "$1" ] || rm -f "$claim/.acked"
}

# relay_row  Registry callback: deliver one operator's inbox, if non-empty.
relay_row() {
  [ -z "$only_key" ] || [ "$OP_KEY" = "$only_key" ] || return 0
  claim=$AO_INBOX/$OP_KEY/.claimed
  if [ -z "$dry_run" ] && [ -d "$claim" ]; then
    relay_unclaim
    rmdir "$claim" 2>/dev/null
  fi
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
  mkdir -p "$claim" || { ao_log "$log" "to=$OP_KEY FAILED: cannot create $claim"; failures=$((failures + 1)); return 0; }
  for _note in "$@"; do
    case $_note in *"$AO_NL"*) ao_warn "skipping note with a newline in its name: $_note"; continue ;; esac
    mv "$_note" "$claim/" 2>/dev/null || ao_warn "could not claim $_note; it stays for the next run"
  done
  relay_start
  for _note in "$claim"/*.md; do
    [ -f "$_note" ] || continue
    if [ -s "$batch" ] && [ $(($(wc -c <"$msg") + max_bytes + NOTE_OVERHEAD)) -gt "$budget" ]; then
      relay_flush || { relay_unclaim; return 0; }
      relay_start
    fi
    relay_append "$_note"
  done
  if [ -s "$batch" ]; then relay_flush || relay_unclaim; fi
  relay_unclaim
  rmdir "$claim" 2>/dev/null
  return 0
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
  budget=$(ao_cfg_uint relay_max_message_bytes 100000) || exit
  [ "$budget" -le "$AO_ARG_MAX_BYTES" ] ||
    ao_die "$AO_E_USAGE" "relay_max_message_bytes must be at most $AO_ARG_MAX_BYTES (one argument)"
  [ $((max_bytes + NOTE_OVERHEAD + ${#label} + 100)) -le "$budget" ] ||
    ao_die "$AO_E_USAGE" "relay_max_bytes is too large for relay_max_message_bytes"
  log=$AO_STATE/relay.log
  msg=$(ao_tmp msg) out=$(ao_tmp out) batch=$(ao_tmp batch)
  ao_registry_each relay_row
  [ "$failures" -eq 0 ] || exit "$AO_E_FAIL"
}

main "$@"
