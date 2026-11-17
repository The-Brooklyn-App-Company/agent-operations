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
#           id. Then mail the Oracle (mail.sh send <oracle> --kind notice).
#   reserve ID --target T --revision R [--pid PID]
#           Under the lease lock: check the committed approval row (same
#           generation, epoch, action, target and revision; not expired; not
#           used), create a dispatch marker, mark the ask reserved; then
#           commit ASKS.md. Prints `marker: ID`. Dispatch only after this
#           succeeds. A target or revision that differs from the ask voids it.
#   done ID --marker M     After the effect: mark used, remove the marker.
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
  if ! ao_lease_is_holder "$o_instance" "$o_epoch"; then
    ao_lease_unlock
    ao_msg "not the holder: $(ao_lease_describe)"
    refuse "only the holder of $H_KEY may $verb (this session is the standby)"
  fi
}

no_audit_pending() {
  [ "$L_audit" != pending ] || { ao_lease_unlock; refuse "switch-in audit pending: finish it (lease.sh audit-brief, audit-done) before new work"; }
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
  [ ! -f "$ASKS" ] || ao_git_clean "$H_HOME" ASKS.md ||
    { ao_lease_unlock; refuse "ASKS.md has uncommitted changes; commit or restore it first"; }
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
  _n=$(awk -F'|' -v k="$H_KEY" '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { id = t($2); if (index(id, k "-") == 1) { n = substr(id, length(k) + 2); if (n ~ /^[0-9]+$/ && n + 0 > m) m = n + 0 } }
    END { print m + 1 }' "$ASKS")
  _id=$H_KEY-$_n
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | open |\n' "$_id" "$L_generation" "$L_epoch" \
    "$o_action" "$o_target" "$o_revision" "$o_risk" "$o_rollback" >>"$ASKS" || ao_die "$AO_E_FAIL" "cannot write $ASKS"
  if ! ao_git_commit "$H_HOME" "asks: $_id $o_action" ASKS.md; then
    asks_restore
    ao_die "$AO_E_FAIL" "cannot commit ASKS.md; ask not created"
  fi
  ao_lease_unlock
  echo "ask: $_id"
  echo "Now tell the Oracle: echo 'Ask $_id waiting' | mail.sh send $AO_ORACLE_KEY --kind notice --from $H_KEY/$L_provider"
}

do_approve() {
  ao_is_name "$o_id" || ao_die "$AO_E_USAGE" "approve needs an ask ID"
  [ -n "$o_words" ] || ao_die "$AO_E_USAGE" "approve needs --words: the human's verbatim answer"
  ao_load --no-state
  _key=${o_id%-*}
  if ! ao_is_uint "${o_id##*-}" || ! ao_is_name "$_key"; then
    ao_die "$AO_E_USAGE" "ask ids look like <key>-<n>"
  fi
  _expiry=$(expiry_of "$o_expires_in")
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

do_reserve() {
  ao_is_name "$o_id" || ao_die "$AO_E_USAGE" "reserve needs an ask ID"
  check_field --target "$o_target"
  check_field --revision "$o_revision"
  _pid=${o_pid:-$PPID}
  ao_is_uint "$_pid" || ao_die "$AO_E_USAGE" "--pid must be a process id"
  use_operator_home
  ao_load --no-state
  lock
  holder
  no_audit_pending
  asks_clean
  _row=$(ao_ask_row "$ASKS" "$o_id") || { ao_lease_unlock; refuse "no ask $o_id in ASKS.md"; }
  IFS=$AO_TAB read -r _ _gen _ep _act _tgt _rev _ _ _st <<EOF
$_row
EOF
  [ "$_st" = open ] || { ao_lease_unlock; refuse "ask $o_id is $_st: an approval is used once"; }
  [ "$_gen" = "$L_generation" ] && [ "$_ep" = "$L_epoch" ] || {
    ao_lease_unlock
    refuse "ask $o_id is from generation $_gen epoch $_ep; the lease is at generation $L_generation epoch $L_epoch. Approvals do not cross a takeover or restore: re-ask"
  }
  _apps=$(approvals_rows "$o_id")
  [ -n "$_apps" ] || { ao_lease_unlock; refuse "no committed approval row for $o_id in the Oracle's APPROVALS.tsv"; }
  [ "$(printf '%s\n' "$_apps" | wc -l | tr -d ' ')" -eq 1 ] || { ao_lease_unlock; refuse "more than one approval row for $o_id: ambiguous, ask the human"; }
  IFS=$AO_TAB read -r _ _agen _aep _aact _atgt _arev _aexp _ <<EOF
$_apps
EOF
  [ "$_agen" = "$L_generation" ] && [ "$_aep" = "$L_epoch" ] || {
    ao_lease_unlock
    refuse "the approval for $o_id is for generation $_agen epoch $_aep, not the current lease: dead"
  }
  [ "$_aact" = "$_act" ] && [ "$_atgt" = "$_tgt" ] && [ "$_arev" = "$_rev" ] || {
    ao_lease_unlock
    refuse "the approval row for $o_id does not match the ask (action, target or revision)"
  }
  awk -v now="$(ao_utc "$AO_T_EPOCH")" -v until="$_aexp" 'BEGIN { exit !(now "" < until "") }' || { ao_lease_unlock; refuse "the approval for $o_id expired at $_aexp"; }
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
  ao_lease_unlock
  if ! ao_git_commit "$H_HOME" "asks: $o_id reserved" ASKS.md; then
    lock
    if ! ao_ask_set_status "$ASKS" "$o_id" open || ! rm -f "$H_OP/markers/$_mk"; then
      ao_die "$AO_E_FAIL" "commit failed and the rollback failed: marker $_mk and ASKS.md need a human"
    fi
    ao_lease_unlock
    ao_die "$AO_E_FAIL" "cannot commit ASKS.md; reservation rolled back, do not dispatch"
  fi
  echo "reserved: $o_id ($_act $_tgt @ $_rev)"
  echo "marker: $_mk"
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
  _row=$(ao_ask_row "$ASKS" "$o_id") || { ao_lease_unlock; refuse "no ask $o_id"; }
  [ "$(printf '%s\n' "$_row" | cut -f9)" = reserved ] || { ao_lease_unlock; refuse "ask $o_id is not reserved"; }
  ao_ask_set_status "$ASKS" "$o_id" used || ao_die "$AO_E_FAIL" "cannot update ASKS.md"
  _ao_crash done-after-asks
  rm -f "$_mf" || ao_die "$AO_E_FAIL" "cannot remove $_mf"
  ao_lease_unlock
  ao_git_commit "$H_HOME" "asks: $o_id used" ASKS.md || ao_warn "ASKS.md updated but not committed; commit it"
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
  ao_lease_unlock
  ao_git_commit "$H_HOME" "asks: $o_id void ($o_reason)" ASKS.md || ao_die "$AO_E_FAIL" "cannot commit ASKS.md"
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
    reserve) do_reserve ;;
    done) do_done ;;
    void) do_void ;;
    list) do_list ;;
    *) ao_die "$AO_E_USAGE" "unknown verb '$verb' (see --help)" ;;
  esac
}

main "$@"
