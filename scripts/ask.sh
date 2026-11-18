#!/bin/sh
# ask.sh - EXPERIMENTAL: asks and the approvals ledger, bound to the lease.
#
# Usage: ask.sh VERB [OPTIONS]
#
# An operator commits an ask to ASKS.md in its home; the human answers in
# the Oracle thread; only the Oracle commits the approval row to
# APPROVALS.tsv in its home. The operator acts on THAT row, once, and only
# while its lease generation and epoch equal the row's: any acquire,
# takeover or restore starts a new epoch or generation, so no old approval
# revives. Mail is never an approval.
#
# Operator verbs (holder only; --instance T --epoch N from lease.sh acquire):
#   new --action A --target T --revision R --risk TEXT --rollback TEXT
#           Append and commit one ask (id <key>-<n>, status open); prints the
#           id, and mails the Oracle a notice (mail.sh send <oracle>).
#   reserve ID --target T --revision R (-- CMD [ARG...] | --pid PID)
#           Under the lease lock throughout: check the committed approval row
#           (same generation, epoch, action, target and revision; not
#           expired; not used), create a dispatch marker, mark the ask
#           reserved and commit ASKS.md. Prints `marker: ID`. With -- CMD it
#           then runs the effect itself (this process stays on the marker)
#           and marks it used on exit 0; a failure leaves it reserved for the
#           human to settle. With --pid, PID must be the live wrapper doing
#           the effect, which calls done afterwards. A target or revision
#           that differs from the ask voids it.
#   done ID --marker M     After the effect: mark used, remove the marker
#           (refused once the marker's process died: the human settles).
#   void ID --reason TEXT  Withdraw an open ask.
#   list                   Print the asks.
#
# Oracle verb (the Oracle's holder token, in the Oracle home's lease):
#   approve ID --words TEXT [--expires-in 24h]
#           Copy the committed ask's generation, epoch, action, target and
#           revision, with the human's verbatim words (tab, newline and
#           backslash escaped as \t \n \\), into APPROVALS.tsv and commit it.
#
# Options common to all verbs: --home DIR (operator home; default: found
# from $PWD), --instance T, --epoch N.
#
# Environment: AO_PROFILE (oracle_home locates APPROVALS.tsv; the registry
# locates operator homes).
#
# Exit codes: 0 ok; 1 failure; 2 usage; 3 lease lock busy; 5 refused.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"

APPROVALS_HEADER='# ask_id	generation	epoch	action	target	revision	expiry	words'

refuse() {
  ao_msg "refused: $*"
  exit "$AO_E_REFUSED"
}

lock() {
  ao_lease_lock || exit "$AO_E_BUSY"
}

# holder  Load the lease of H_HOME and require the presented token.
holder() {
  [ -n "$o_instance" ] && [ -n "$o_epoch" ] || ao_die "$AO_E_USAGE" "$verb needs --instance TOKEN and --epoch N"
  ao_lease_load
  if ! ao_lease_holder "$o_instance" "$o_epoch"; then
    ao_lease_unlock
    ao_msg "not the holder: $(ao_lease_describe)"
    refuse "only the holder of $H_KEY may $verb (this session is the standby)"
  fi
}

# no_audit_pending  The lease's own switch-in audit, or a registry one
# recorded by cross-review.sh (lib/registry.sh), blocks new work.
no_audit_pending() {
  [ "$L_audit" != pending ] || { ao_lease_unlock; refuse "switch-in audit pending: finish it (lease.sh audit-brief, audit-done) before new work"; }
  if ao_audit_registry_pending "$H_KEY"; then
    ao_lease_unlock
    [ -z "$A_invalid" ] || refuse "switch-in audit record $(ao_audit_file "$H_KEY") is unreadable or invalid: failing closed; a human must inspect it"
    refuse "switch-in audit pending (registry change $A_from -> $A_to): finish it (lease.sh audit-brief, audit-done) before new work"
  fi
}

use_operator_home() {
  _h=$(ao_home_find "$o_home") || ao_die "$AO_E_USAGE" "no operator home (operator.conf) at ${o_home:-$PWD or above}; use --home"
  ao_home_use "$_h"
  ASKS=$H_HOME/ASKS.md
}

asks_init() {
  [ ! -f "$ASKS" ] || return 0
  cat >"$ASKS" <<'EOF' || ao_die "$AO_E_FAIL" "cannot create $ASKS"
# Asks

Written by scripts/ask.sh; one row per ask. Status: open, reserved, used,
held (may have happened: verify the target), void.

| id | generation | epoch | action | target | revision | risk | rollback | status |
|---|---|---|---|---|---|---|---|---|
EOF
}

asks_clean() {
  if git -C "$H_HOME" cat-file -e HEAD:./ASKS.md 2>/dev/null; then
    if [ ! -f "$ASKS" ] || ! ao_git_clean "$H_HOME" ASKS.md; then
      ao_lease_unlock
      refuse "ASKS.md has uncommitted changes or was deleted; commit or restore it first"
    fi
  elif [ -e "$ASKS" ]; then
    ao_lease_unlock
    refuse "ASKS.md is untracked; commit it or move it aside first"
  fi
}

# asks_restore  Put ASKS.md back to HEAD after a failed commit.
asks_restore() {
  if git -C "$H_HOME" cat-file -e HEAD:./ASKS.md 2>/dev/null; then
    git -C "$H_HOME" checkout -q HEAD -- ASKS.md
  else
    rm -f "$ASKS"
  fi
}

# approvals_rows ID  Print committed APPROVALS.tsv rows for ID (HEAD only:
# a row that is not committed in the Oracle home does not exist).
approvals_rows() {
  git -C "$AO_HOME" show HEAD:./APPROVALS.tsv 2>/dev/null |
    awk -F'\t' -v id="$1" '!/^#/ && $1 == id'
}

check_field() {
  ao_text_ok "$2" || ao_die "$AO_E_USAGE" "$1 is required: one line, no tab or '|'"
}

expiry_of() {
  _v=${1:-24h}
  case $_v in *h) _n=${_v%h} _m=3600 ;; *m) _n=${_v%m} _m=60 ;; *) _n=$_v _m=3600 ;; esac
  ao_is_uint "$_n" && [ "$_n" -gt 0 ] || ao_die "$AO_E_USAGE" "--expires-in: expected Nh or Nm"
  ao_utc $((AO_T_EPOCH + _n * _m))
}

# ---------------------------------------------------------------- verbs

do_new() {
  for _f in action target revision risk rollback; do
    eval "check_field --$_f \"\$o_$_f\""
  done
  use_operator_home
  ao_load --no-state
  lock
  holder
  no_audit_pending
  asks_clean
  asks_init
  # The next number after every id this operator ever used: in ASKS.md and
  # in the Oracle's committed approvals, so an id (and its approval) is
  # never reused.
  _n=$({
    awk -F'|' '{ print $2 }' "$ASKS"
    git -C "$AO_HOME" show HEAD:./APPROVALS.tsv 2>/dev/null | awk -F'\t' '!/^#/ { print $1 }'
  } | awk -v k="$H_KEY" '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { id = t($0); if (index(id, k "-") == 1) { n = substr(id, length(k) + 2); if (n ~ /^[0-9]+$/ && n + 0 > m) m = n + 0 } }
    END { print m + 1 }')
  _id=$H_KEY-$_n
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | open |\n' "$_id" "$L_generation" "$L_epoch" \
    "$o_action" "$o_target" "$o_revision" "$o_risk" "$o_rollback" >>"$ASKS" || ao_die "$AO_E_FAIL" "cannot write $ASKS"
  if ! ao_git_commit "$H_HOME" "asks: $_id $o_action" ASKS.md; then
    asks_restore
    ao_die "$AO_E_FAIL" "cannot commit ASKS.md; ask not created"
  fi
  ao_lease_unlock
  echo "ask: $_id"
  # Tell the Oracle (a notification; the human answers in the Oracle thread).
  if printf 'Ask %s waiting for approval: %s %s at %s (risk: %s; rollback: %s)\n' "$_id" "$o_action" "$o_target" "$o_revision" "$o_risk" "$o_rollback" |
    "$AO_SCRIPTS/mail.sh" send "$AO_ORACLE_KEY" --kind notice --from "$H_KEY/$L_provider" >/dev/null; then
    echo "mailed: $AO_ORACLE_KEY"
  else
    ao_warn "ask $_id committed, but mailing the Oracle failed: tell it yourself"
  fi
}

do_approve() {
  ao_is_name "$o_id" || ao_die "$AO_E_USAGE" "approve needs an ask ID"
  [ -n "$o_words" ] || ao_die "$AO_E_USAGE" "approve needs --words: the human's verbatim answer"
  ao_load --no-state
  _key=${o_id%-*}
  if ! ao_is_uint "${o_id##*-}" || ! ao_is_name "$_key"; then
    ao_die "$AO_E_USAGE" "ask ids look like <key>-<n>"
  fi
  _expiry=$(expiry_of "$o_expires_in") || exit "$AO_E_USAGE"
  # The operator's ask, as committed.
  _ophome=
  _want=$_key
  ao_registry_each find_row
  [ -n "$_ophome" ] || ao_die "$AO_E_USAGE" "'$_key' is not in the registry"
  _row=$(git -C "$_ophome" show HEAD:./ASKS.md 2>/dev/null | ao_ask_row /dev/stdin "$o_id") ||
    refuse "no committed ask $o_id in $_ophome/ASKS.md"
  _st=$(printf '%s\n' "$_row" | cut -f9)
  [ "$_st" = open ] || refuse "ask $o_id is $_st, not open"
  # The Oracle's own lease: only its holder writes the ledger.
  ao_home_use "$AO_HOME"
  [ "$H_KEY" = "$AO_ORACLE_KEY" ] || ao_die "$AO_E_USAGE" "$AO_HOME/operator.conf key is '$H_KEY', not the oracle_key '$AO_ORACLE_KEY'"
  lock
  holder
  [ -z "$(approvals_rows "$o_id")" ] || { ao_lease_unlock; refuse "$o_id already has an approval row"; }
  ao_git_clean "$AO_HOME" APPROVALS.tsv || [ ! -f "$AO_HOME/APPROVALS.tsv" ] ||
    { ao_lease_unlock; refuse "APPROVALS.tsv has uncommitted changes"; }
  [ -f "$AO_HOME/APPROVALS.tsv" ] || printf '%s\n' "$APPROVALS_HEADER" >"$AO_HOME/APPROVALS.tsv"
  _words=$(printf '%s' "$o_words" | awk '{ gsub(/\\/, "\\\\"); gsub(/\t/, "\\t"); if (NR > 1) printf "\\n"; printf "%s", $0 }')
  printf '%s\t%s\n' "$(printf '%s\n' "$_row" | cut -f1-6)" "$_expiry$AO_TAB$_words" >>"$AO_HOME/APPROVALS.tsv" ||
    ao_die "$AO_E_FAIL" "cannot write APPROVALS.tsv"
  if ! ao_git_commit "$AO_HOME" "approvals: $o_id" APPROVALS.tsv; then
    git -C "$AO_HOME" checkout -q HEAD -- APPROVALS.tsv 2>/dev/null || ao_warn "restore APPROVALS.tsv by hand"
    ao_die "$AO_E_FAIL" "cannot commit APPROVALS.tsv; not approved"
  fi
  ao_lease_unlock
  echo "approved: $o_id until $_expiry (generation $(printf '%s\n' "$_row" | cut -f2), epoch $(printf '%s\n' "$_row" | cut -f3))"
}

find_row() {
  [ "$OP_KEY" = "$_want" ] && _ophome=$OP_DIR
  return 0
}

# reserve_rollback MARKER  Undo an uncommitted reservation (under the lock).
reserve_rollback() {
  if ! asks_restore || ! rm -f "$H_OP/markers/$1"; then
    ao_die "$AO_E_FAIL" "rollback failed: marker $1 and ASKS.md need a human"
  fi
}

# finish_used MARKER  Mark the reserved ask used and remove its marker, then
# commit; under the lock throughout.
finish_used() {
  ao_ask_set_status "$ASKS" "$o_id" used || ao_die "$AO_E_FAIL" "cannot update ASKS.md"
  _ao_crash done-after-asks
  rm -f "$H_OP/markers/$1" || ao_die "$AO_E_FAIL" "cannot remove marker $1"
  ao_git_commit "$H_HOME" "asks: $o_id used" ASKS.md || ao_warn "ASKS.md says used but is not committed; commit it"
}

do_reserve() {
  ao_is_name "$o_id" || ao_die "$AO_E_USAGE" "reserve needs an ask ID"
  check_field --target "$o_target"
  check_field --revision "$o_revision"
  # The marker must name a process that lives for the whole effect: this
  # one when reserve runs the command itself, else a live wrapper's --pid.
  if [ $# -gt 0 ]; then
    _pid=$$
  else
    ao_is_uint "$o_pid" || ao_die "$AO_E_USAGE" "reserve needs -- CMD [ARG...] (recommended) or --pid PID of the live process doing the effect"
    [ "$(ao_proc_state "$o_pid")" = live ] || ao_die "$AO_E_USAGE" "--pid $o_pid is not a running process (or its state cannot be read)"
    _pid=$o_pid
  fi
  use_operator_home
  ao_load --no-state
  lock
  # Read the clock under the lock, so a wait for the lock cannot stretch an
  # approval past its expiry.
  ao_clock
  holder
  no_audit_pending
  asks_clean
  _row=$(ao_ask_row "$ASKS" "$o_id") || { ao_lease_unlock; refuse "no ask $o_id in ASKS.md"; }
  # cut keeps empty fields in place (read with IFS=tab would shift them).
  _gen=$(printf '%s\n' "$_row" | cut -f2) _ep=$(printf '%s\n' "$_row" | cut -f3)
  _act=$(printf '%s\n' "$_row" | cut -f4) _tgt=$(printf '%s\n' "$_row" | cut -f5)
  _rev=$(printf '%s\n' "$_row" | cut -f6) _st=$(printf '%s\n' "$_row" | cut -f9)
  [ "$_st" = open ] || { ao_lease_unlock; refuse "ask $o_id is $_st: an approval is used once"; }
  [ "$_gen" = "$L_generation" ] && [ "$_ep" = "$L_epoch" ] || {
    ao_lease_unlock
    refuse "ask $o_id is from generation $_gen epoch $_ep; the lease is at generation $L_generation epoch $L_epoch. Approvals do not cross a takeover or restore: re-ask"
  }
  _apps=$(approvals_rows "$o_id")
  [ -n "$_apps" ] || { ao_lease_unlock; refuse "no committed approval row for $o_id in the Oracle's APPROVALS.tsv"; }
  [ "$(printf '%s\n' "$_apps" | wc -l | tr -d ' ')" -eq 1 ] || { ao_lease_unlock; refuse "more than one approval row for $o_id: ambiguous, ask the human"; }
  printf '%s\n' "$_apps" | awk -F'\t' 'NF == 8 && $2 != "" && $3 ~ /^[0-9]+$/ && $7 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { ok = 1 } END { exit !ok }' || {
    ao_lease_unlock
    refuse "the approval row for $o_id is malformed (8 tab-separated fields, a UTC expiry): ask the human"
  }
  _agen=$(printf '%s\n' "$_apps" | cut -f2) _aep=$(printf '%s\n' "$_apps" | cut -f3)
  _aact=$(printf '%s\n' "$_apps" | cut -f4) _atgt=$(printf '%s\n' "$_apps" | cut -f5)
  _arev=$(printf '%s\n' "$_apps" | cut -f6) _aexp=$(printf '%s\n' "$_apps" | cut -f7)
  [ "$_agen" = "$L_generation" ] && [ "$_aep" = "$L_epoch" ] || {
    ao_lease_unlock
    refuse "the approval for $o_id is for generation $_agen epoch $_aep, not the current lease: dead"
  }
  [ "$_aact" = "$_act" ] && [ "$_atgt" = "$_tgt" ] && [ "$_arev" = "$_rev" ] || {
    ao_lease_unlock
    refuse "the approval row for $o_id does not match the ask (action, target or revision)"
  }
  unexpired "$_aexp" || { ao_lease_unlock; refuse "the approval for $o_id expired at $_aexp"; }
  if [ "$o_target" != "$_tgt" ] || [ "$o_revision" != "$_rev" ]; then
    ao_ask_set_status "$ASKS" "$o_id" void || ao_die "$AO_E_FAIL" "cannot update ASKS.md"
    ao_git_commit "$H_HOME" "asks: $o_id void (target or revision changed)" ASKS.md || ao_warn "ASKS.md voided but not committed"
    ao_lease_unlock
    refuse "target or revision differs from the approved ask ($_tgt @ $_rev): $o_id is void; re-ask"
  fi
  _mk=$(ao_marker_create ask "$_act $_tgt @ $_rev" "$o_id" "$_pid") || ao_die "$AO_E_FAIL" "cannot create a dispatch marker"
  _ao_crash reserve-after-marker
  ao_ask_set_status "$ASKS" "$o_id" reserved || ao_die "$AO_E_FAIL" "cannot update ASKS.md (marker $_mk left: settle it)"
  _ao_crash reserve-after-asks
  # Committed under the lock: nothing (settle, takeover) can change the ask
  # between the reservation and the permission to dispatch.
  if ! ao_git_commit "$H_HOME" "asks: $o_id reserved" ASKS.md; then
    reserve_rollback "$_mk"
    ao_die "$AO_E_FAIL" "cannot commit ASKS.md; reservation rolled back, do not dispatch"
  fi
  ao_clock
  if ! unexpired "$_aexp"; then
    ao_ask_set_status "$ASKS" "$o_id" void && rm -f "$H_OP/markers/$_mk"
    ao_git_commit "$H_HOME" "asks: $o_id void (approval expired during reservation)" ASKS.md || ao_warn "ASKS.md voided but not committed"
    ao_lease_unlock
    refuse "the approval for $o_id expired while reserving: void, re-ask; do not dispatch"
  fi
  ao_lease_unlock
  echo "reserved: $o_id ($_act $_tgt @ $_rev)"
  echo "marker: $_mk"
  [ $# -gt 0 ] || return 0
  # Run the effect with this process on the marker; mark used on exit 0.
  "$@"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    ao_msg "the command failed (exit $_rc): its effect is unknown. $o_id stays reserved and marker $_mk open until the human checks the target and settles it"
    exit "$_rc"
  fi
  lock
  finish_used "$_mk"
  ao_lease_unlock
  echo "used: $o_id"
}

unexpired() {
  awk -v now="$(ao_utc "$AO_T_EPOCH")" -v until="$1" 'BEGIN { exit !(now "" < until "") }'
}

do_done() {
  ao_is_name "$o_id" || ao_die "$AO_E_USAGE" "done needs an ask ID"
  ao_is_name "$o_marker" || ao_die "$AO_E_USAGE" "done needs --marker M (from reserve)"
  use_operator_home
  ao_load --no-state
  lock
  holder
  _mf=$H_OP/markers/$o_marker
  [ -f "$_mf" ] && [ "$(ao_marker_get "$_mf" ask)" = "$o_id" ] || { ao_lease_unlock; refuse "no open marker $o_marker for $o_id"; }
  [ "$(ao_marker_get "$_mf" instance)" = "$L_instance" ] && [ "$(ao_marker_get "$_mf" epoch)" = "$L_epoch" ] ||
    { ao_lease_unlock; refuse "marker $o_marker belongs to another holder or epoch"; }
  _mst=$(ao_proc_state "$(ao_marker_get "$_mf" pid)" "$(ao_marker_get "$_mf" pid_start)")
  if [ "$_mst" != live ]; then
    ao_lease_unlock
    refuse "marker $o_marker's process is $_mst: the effect is unknown until a human checks the target and settles it (lease.sh settle)"
  fi
  _row=$(ao_ask_row "$ASKS" "$o_id") || { ao_lease_unlock; refuse "no ask $o_id"; }
  [ "$(printf '%s\n' "$_row" | cut -f9)" = reserved ] || { ao_lease_unlock; refuse "ask $o_id is not reserved"; }
  finish_used "$o_marker"
  ao_lease_unlock
  echo "used: $o_id"
}

do_void() {
  ao_is_name "$o_id" || ao_die "$AO_E_USAGE" "void needs an ask ID"
  check_field --reason "$o_reason"
  use_operator_home
  ao_load --no-state
  lock
  holder
  asks_clean
  _row=$(ao_ask_row "$ASKS" "$o_id") || { ao_lease_unlock; refuse "no ask $o_id"; }
  [ "$(printf '%s\n' "$_row" | cut -f9)" = open ] || { ao_lease_unlock; refuse "only an open ask can be voided"; }
  ao_ask_set_status "$ASKS" "$o_id" void || ao_die "$AO_E_FAIL" "cannot update ASKS.md"
  if ! ao_git_commit "$H_HOME" "asks: $o_id void ($o_reason)" ASKS.md; then
    asks_restore
    ao_die "$AO_E_FAIL" "cannot commit ASKS.md; ask unchanged"
  fi
  ao_lease_unlock
  echo "void: $o_id"
}

do_list() {
  use_operator_home
  [ -f "$ASKS" ] || { echo "no asks"; return 0; }
  ao_asks_with_status "$ASKS" open reserved used held void
}

main() {
  case ${1-} in -h | --help | '') ao_usage; [ $# -gt 0 ] || exit "$AO_E_USAGE"; exit 0 ;; esac
  verb=$1
  shift
  o_home='' o_instance='' o_epoch='' o_id='' o_action='' o_target='' o_revision='' o_risk=''
  o_rollback='' o_words='' o_expires_in='' o_pid='' o_marker='' o_reason=''
  while [ $# -gt 0 ]; do
    case $1 in
      --home | --instance | --epoch | --action | --target | --revision | --risk | --rollback | \
        --words | --expires-in | --pid | --marker | --reason)
        [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "$1 needs a value"
        _var=o_$(printf '%s' "${1#--}" | tr - _)
        eval "$_var=\$2"
        shift ;;
      --) shift; break ;;
      -h | --help) ao_usage; exit 0 ;;
      -*) ao_die "$AO_E_USAGE" "unknown option '$1' (see --help)" ;;
      *) [ -z "$o_id" ] || ao_die "$AO_E_USAGE" "one ask ID only"; o_id=$1 ;;
    esac
    shift
  done
  ao_lease_traps
  case $verb in
    new) do_new ;;
    approve) do_approve ;;
    reserve) do_reserve "$@" ;;
    done) do_done ;;
    void) do_void ;;
    list) do_list ;;
    *) ao_die "$AO_E_USAGE" "unknown verb '$verb' (see --help)" ;;
  esac
}

main "$@"
