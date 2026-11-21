# shellcheck shell=sh disable=SC2034
# (SC2034: the OP_* globals set here are read by registry callbacks.)
# registry.sh - the operator registry, the watchdog quiet list and inboxes.
#
# Sourced after core.sh and ao_load. Registry format (TSV, `#` comments):
#   key <TAB> name <TAB> project-dir <TAB> session [<TAB> client]
# key      inbox folder name and stable id: [A-Za-z0-9._-]+
# name     the session's display name (what the relay addresses)
# session  session id, or `pending` / `-` when not known yet
# client   claude | codex | custom | file-only; empty = profile relay_default
# Empty fields are not allowed (tabs collapse); use `-`.

# EXPERIMENTAL provider handoff: a lease in <project-dir>/.operator/lease
# routes the operator to its holder (see lib/lease.sh, ao_lease_route).
# shellcheck disable=SC1091 # lib/lease.sh is followed from the scripts and checked itself
. "$AO_SCRIPTS/lib/lease.sh"

# ao_registry_each CALLBACK  Call CALLBACK once per registry row with
# OP_KEY, OP_NAME, OP_DIR, OP_SID and OP_CLIENT set (see ao_operator_resolve).
# The registry is read on fd 3 and the callback runs with fd 3 closed and
# stdin from /dev/null, so nothing it runs can swallow the remaining rows.
ao_registry_each() {
  [ -r "$AO_REGISTRY" ] || ao_die "$AO_E_USAGE" "registry not readable: $AO_REGISTRY"
  _ao_rn=0
  while IFS="$AO_TAB" read -r _ao_k _ao_nm _ao_d _ao_s _ao_c _ao_rest <&3 || [ -n "${_ao_k-}" ]; do
    _ao_rn=$((_ao_rn + 1))
    case ${_ao_k-} in '' | '#'*) continue ;; esac
    if ! ao_is_name "$_ao_k" || [ -z "${_ao_nm-}" ]; then
      ao_warn "$AO_REGISTRY:$_ao_rn: skipping malformed row"
      continue
    fi
    ao_operator_resolve "$_ao_k" "$_ao_nm" "${_ao_d:--}" "${_ao_s:--}" "${_ao_c:-}"
    "$1" 3<&- </dev/null
  done 3<"$AO_REGISTRY"
}

# ao_is_bridge_key KEY  True for the reserved mailroom bridge keys
# (EXPERIMENTAL, lib/mailroom.sh): never relayed to, watched or reviewed.
ao_is_bridge_key() {
  case $1 in mailroom-claude | mailroom-codex) return 0 ;; esac
  return 1
}

# ao_registry_has KEY  True when KEY has a registry row.
ao_registry_has() {
  [ -r "$AO_REGISTRY" ] || return 1
  awk -F'\t' -v k="$1" '$1 == k { found = 1; exit } END { exit !found }' "$AO_REGISTRY"
}

# ao_operator_resolve KEY NAME DIR SESSION CLIENT  Set the OP_* variables for
# one operator. This is the single place that decides which provider and
# session currently own an operator: the registry row, overridden by a lease
# in the operator home (OP_LEASE: none, held, released, assigned or invalid;
# OP_PROVIDER: the owning model family, also under a file-only transport;
# EXPERIMENTAL, see ao_lease_route), and its switch-in audit state
# (OP_AUDIT and friends, see ao_audit_resolve).
ao_operator_resolve() {
  OP_KEY=$1 OP_NAME=$2 OP_SID=$4
  OP_DIR=$(ao_expand_path "$3" /)
  OP_CLIENT=$(ao_cfg relay_default claude)
  [ -z "$5" ] || OP_CLIENT=$5
  case $OP_SID in pending | -) OP_SID= ;; esac
  ao_lease_route
  ao_audit_resolve
}

# ---------------------------------------------------------------- switch-in audits
#
# When an operator moves to the other model family, the incoming family
# audits what the outgoing one left before new work (kit rule K-22). One
# mechanism, two triggers:
#   lease     a lease acquire or takeover onto another client sets
#             audit=pending in the lease itself (lease.sh, EXPERIMENTAL)
#   registry  a change of the operator's family without a lease (the
#             registry client column), seen by cross-review.sh and recorded
#             in <state_dir>/audit/<key>
# Either way cross-review.sh writes a headless report by the incoming
# family to <home>/audits/, whose first line is OP_AUDIT_HEADER; the
# incoming session triages and commits it, and `lease.sh audit-done
# --report PATH` records it (path and commit) and clears the gate.
#
# <state_dir>/audit/<key> is written only by cross-review.sh:
#   provider=  the family last seen    from=, to=  the last family change
#   change=    its number (1, 2, ...; empty: no change seen yet)
#   since=     when it was seen (UTC)
# <state_dir>/audit/<key>.done is written only by lease.sh audit-done:
#   change=    the change it audits    since=, report=, commit=, at=
# A registry audit is pending while change= is set and differs from the
# .done file's change=. Both files are flat key=value, parsed literally.

# ao_is_family CLIENT  True for a model family (claude, codex).
ao_is_family() {
  case $1 in claude | codex) return 0 ;; esac
  return 1
}

# ao_audit_file KEY [.done]  Print the path of an audit record.
ao_audit_file() {
  printf '%s/audit/%s%s\n' "$AO_STATE" "$1" "${2-}"
}

# _ao_kv_snapshot FILE KEYS PREFIX  Read FILE once and set PREFIX<key> for
# each of KEYS (other lines are ignored; never sourced). False when the file
# cannot be read or lacks one of KEYS (an empty or truncated record).
_ao_kv_snapshot() {
  for _ao_k in $2; do eval "$3$_ao_k=''"; done
  [ -r "$1" ] || return 1
  _ao_snap=$(cat "$1") || return 1
  _ao_seen=' '
  while IFS= read -r _ao_l; do
    _ao_k=${_ao_l%%=*}
    case " $2 " in *" $_ao_k "*) eval "$3$_ao_k=\${_ao_l#*=}"; _ao_seen="$_ao_seen$_ao_k " ;; esac
  done <<EOF
$_ao_snap
EOF
  for _ao_k in $2; do
    case $_ao_seen in *" $_ao_k "*) ;; *) return 1 ;; esac
  done
}

# ao_audit_read KEY  Set A_provider, A_from, A_to, A_change, A_since (the
# record) and A_done (the change= of the last recorded audit), each file
# read once. Returns 0 when read, 1 when there is no record (or no state
# dir), 2 when a record exists but is unreadable or invalid: callers fail
# closed.
ao_audit_read() {
  A_provider='' A_from='' A_to='' A_change='' A_since='' A_done=''
  _ao_d_change='' _ao_d_since='' _ao_d_report='' _ao_d_commit='' _ao_d_at=''
  [ -n "${AO_STATE:-}" ] || return 1
  _ao_af=$(ao_audit_file "$1")
  [ -e "$_ao_af" ] || return 1
  _ao_kv_snapshot "$_ao_af" "provider from to change since" A_ || return 2
  if [ -e "$_ao_af.done" ]; then
    _ao_kv_snapshot "$_ao_af.done" "change since report commit at" _ao_d_ || return 2
    A_done=$_ao_d_change
    ao_is_uint "$A_done" && [ -n "$_ao_d_report" ] && [ -n "$_ao_d_at" ] || return 2
    case $_ao_d_commit in '' | *[!0-9a-f]*) return 2 ;; esac
  fi
  [ -z "$A_provider" ] || ao_is_family "$A_provider" || return 2
  [ -n "$A_change" ] || return 0
  ao_is_uint "$A_change" && ao_is_family "$A_from" && ao_is_family "$A_to" || return 2
  case $A_since in '' | *[!0-9TZ:-]*) return 2 ;; esac
  # A completion of this change must name this change's time too.
  [ "$A_done" != "$A_change" ] || [ "$_ao_d_since" = "$A_since" ] || return 2
}

# ao_audit_registry_pending KEY  True while a recorded registry switch-in
# audit is pending for KEY (A_* set), and also when its record cannot be
# trusted (A_invalid=1): fail closed.
ao_audit_registry_pending() {
  A_invalid=''
  ao_audit_read "$1"
  case $? in
    0) [ -n "$A_change" ] && [ "$A_change" != "$A_done" ] ;;
    1) return 1 ;;
    *) A_invalid=1 ;;
  esac
}

# ao_audit_legacy KEY  Print the client a 0.2.0 cross-review marker
# remembers for KEY when it is a family, else nothing.
ao_audit_legacy() {
  _ao_lf=${AO_STATE:-/nonexistent}/cross-review/$1.client
  [ -r "$_ao_lf" ] || return 0
  read -r _ao_c <"$_ao_lf" 2>/dev/null || return 0
  ! ao_is_family "${_ao_c:-}" || printf '%s\n' "$_ao_c"
}

# ao_audit_registry_tag  The stable id of the recorded registry change (A_*).
ao_audit_registry_tag() {
  printf 'registry-%s-%s\n' "$A_change" "$A_since"
}

# ao_audit_report_base TAG  The home-relative path, without .md, of the
# headless report cross-review.sh writes for a pending change.
ao_audit_report_base() {
  printf 'audits/switch-in-%s\n' "$(printf '%s' "$1" | tr -d ':')"
}

# ao_audit_registry_header KEY  The first line a registry switch-in report
# must have, from the record read by ao_audit_read.
ao_audit_registry_header() {
  printf '# Switch-in audit: %s, registry change %s at %s (%s -> %s)\n' "$1" "$A_change" "$A_since" "$A_from" "$A_to"
}

# ao_audit_resolve  Called by ao_operator_resolve after ao_lease_route. Sets
#   OP_AUDIT         pending, done, invalid (a record that cannot be
#                    trusted: a human inspects it) or - (none recorded)
#   OP_AUDIT_FROM    lease or registry (which trigger), or -
#   OP_AUDIT_TRANS   FROM -> TO of the pending change, or empty
#   OP_AUDIT_HEADER  the first line its report must have (empty while a
#                    registry change is seen but not yet recorded)
#   OP_AUDIT_TAG     a stable id of the pending change, or empty
# A pending lease audit comes first; a recorded registry change still
# pending counts even after a lease appears.
ao_audit_resolve() {
  OP_AUDIT=$OP_AUDIT_LEASE OP_AUDIT_FROM=- OP_AUDIT_TRANS='' OP_AUDIT_HEADER='' OP_AUDIT_TAG=''
  if [ "$OP_AUDIT" = pending ]; then
    OP_AUDIT_FROM=lease OP_AUDIT_TRANS=$OP_LEASE_TRANS
    OP_AUDIT_HEADER=$OP_LEASE_HEADER OP_AUDIT_TAG=$OP_LEASE_TAG
    return 0
  fi
  ao_audit_read "$OP_KEY"
  case $? in
    0) ;;
    1)
      # No record yet: a 0.2.0 marker still gives a baseline to compare.
      _ao_c=$(ao_audit_legacy "$OP_KEY")
      if [ "$OP_LEASE" = none ] && [ -n "$_ao_c" ] && ao_is_family "$OP_PROVIDER" &&
        [ "$_ao_c" != "$OP_PROVIDER" ]; then
        OP_AUDIT=pending OP_AUDIT_FROM=registry OP_AUDIT_TRANS="$_ao_c -> $OP_PROVIDER"
      fi
      return 0 ;;
    *) OP_AUDIT=invalid OP_AUDIT_FROM=registry; return 0 ;;
  esac
  if [ -n "$A_change" ] && [ "$A_change" != "$A_done" ]; then
    OP_AUDIT=pending OP_AUDIT_FROM=registry OP_AUDIT_TRANS="$A_from -> $A_to"
    OP_AUDIT_HEADER=$(ao_audit_registry_header "$OP_KEY")
    OP_AUDIT_TAG=$(ao_audit_registry_tag)
  elif [ "$OP_LEASE" = none ] && ao_is_family "$A_provider" && ao_is_family "$OP_PROVIDER" &&
    [ "$A_provider" != "$OP_PROVIDER" ]; then
    # Seen here first: cross-review.sh records it at its next run.
    OP_AUDIT=pending OP_AUDIT_FROM=registry OP_AUDIT_TRANS="$A_provider -> $OP_PROVIDER"
  elif [ "$OP_AUDIT" = - ] && [ -n "$A_change" ]; then
    OP_AUDIT="done"
  fi
}

# ao_audit_observe  Record a registry family change for the current row
# (cross-review.sh only, under its lock). The baseline is the last model
# family seen (a file-only or custom transport leaves it alone). A move to
# the other family starts a pending audit, unless a lease audits that very
# move (its previous provider is the baseline); otherwise the baseline just
# follows. A row's first sighting takes its baseline from a 0.2.0
# cross-review client marker when there is one. An invalid record is never
# overwritten (returns 1). Then re-resolves the audit state.
ao_audit_observe() {
  _ao_af=$(ao_audit_file "$OP_KEY")
  _ao_old=$AO_STATE/cross-review/$OP_KEY.client
  ao_audit_read "$OP_KEY"
  case $? in
    0) ;;
    1)
      A_provider=$(ao_audit_legacy "$OP_KEY")
      [ -n "$A_provider" ] || ! ao_is_family "$OP_PROVIDER" || A_provider=$OP_PROVIDER
      _ao_audit_put "$_ao_af" || return 1 ;;
    *) ao_audit_resolve; return 1 ;;
  esac
  rm -f "$_ao_old" "$AO_STATE/cross-review/$OP_KEY.switch-held"
  if ao_is_family "$OP_PROVIDER" && [ "$OP_LEASE" != invalid ] && [ "$A_provider" != "$OP_PROVIDER" ]; then
    if ao_is_family "$A_provider" && [ "$OP_LEASE_PREV" != "$A_provider" ]; then
      A_from=$A_provider A_to=$OP_PROVIDER A_since=$(ao_utc "$AO_T_EPOCH")
      A_change=$((${A_change:-0} + 1))
    fi
    A_provider=$OP_PROVIDER
    _ao_audit_put "$_ao_af" || return 1
  fi
  ao_audit_resolve
}

_ao_audit_put() {
  printf 'provider=%s\nfrom=%s\nto=%s\nchange=%s\nsince=%s\n' "$A_provider" "$A_from" "$A_to" "$A_change" "$A_since" |
    ao_write_atomic "$1"
}

# ao_hold_active FILE  True while FILE is a hold that names its owner,
# expiry and reason (K-07) and has not expired: lines owner=WHO,
# until=YYYY-MM-DD (inclusive) or until=YYYY-MM-DDTHH:MM (local time),
# reason=TEXT. Sets AO_H_OWNER, AO_H_UNTIL and AO_H_REASON. A hold missing
# any of the three, or past its expiry, is not honoured (hygiene.sh
# reports it).
# Written by `lane.sh hold`.
ao_hold_active() {
  AO_H_OWNER='' AO_H_UNTIL='' AO_H_REASON=''
  [ -f "$1" ] || return 1
  while IFS= read -r _ao_hl || [ -n "$_ao_hl" ]; do
    case $_ao_hl in
      owner=*) AO_H_OWNER=${_ao_hl#owner=} ;;
      until=*) AO_H_UNTIL=${_ao_hl#until=} ;;
      reason=*) AO_H_REASON=${_ao_hl#reason=} ;;
    esac
  done <"$1"
  [ -n "$AO_H_OWNER" ] && [ -n "$AO_H_REASON" ] || return 1
  case $AO_H_UNTIL in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _ao_hnow=$AO_T_DATE ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]) _ao_hnow=$(printf '%s' "$AO_T_ISO" | cut -c 1-16) ;;
    *) return 1 ;;
  esac
  [ "$(printf '%s\n%s\n' "$_ao_hnow" "$AO_H_UNTIL" | sort | tail -n 1)" = "$AO_H_UNTIL" ]
}

# ao_gate ACTION  Ask the optional `<hooks_dir>/gate` executable whether an
# action on the current operator may proceed. Called as
#   gate <action> <key> <client> <session>
# with exit 0 = proceed, non-zero (or no answer within 30 s) = skip this
# operator for now. Absent gate: always proceed. Actions today: relay,
# watchdog, doorbell. An active hold (<state_dir>/holds/<key>,
# ao_hold_active) skips the operator before the gate is asked.
ao_gate() {
  # A lease that names no holder (released, assigned, unreadable) holds the
  # operator: nobody to deliver to, nothing to watch.
  case ${OP_LEASE:-none} in none | held) ;; *) return 1 ;; esac
  ! ao_hold_active "$AO_STATE/holds/$OP_KEY" || return 1
  [ -x "$AO_HOOKS/gate" ] || return 0
  ao_timeout 30 "$AO_HOOKS/gate" "$1" "$OP_KEY" "$OP_CLIENT" "${OP_SID:--}" </dev/null >/dev/null 2>&1
}

# ao_quiet_until KEY NAME  Print the end date of an active quiet-list entry
# for this operator (matched by key or name), or nothing. Rows:
#   key-or-name <TAB> until (YYYY-MM-DD, inclusive) <TAB> reason
ao_quiet_until() {
  [ -r "$AO_QUIET" ] || return 0
  awk -F'\t' -v k="$1" -v n="$2" -v today="$AO_T_DATE" '
    /^#/ { next }
    ($1 == k || $1 == n) && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && ($2 "") >= (today "") {
      print $2; exit
    }' "$AO_QUIET"
}

# ao_inbox_put KEY SLUG  Write stdin as a new Markdown note in KEY's inbox,
# named <stamp>-<slug>.md (or -2, -3... if taken). The note is written to a
# hidden temp file first and published with ao_place, so readers never see a
# partial note and concurrent writers never overwrite each other. Prints the
# path written.
ao_inbox_put() {
  ao_is_name "$1" || ao_die "$AO_E_USAGE" "invalid inbox key '$1'"
  _ao_slug=$(ao_slug "$2")
  _ao_dir=$AO_INBOX/$1
  mkdir -p "$_ao_dir" || ao_die "$AO_E_FAIL" "cannot create $_ao_dir"
  _ao_tmp=$(mktemp "$_ao_dir/.tmp.XXXXXX") || ao_die "$AO_E_FAIL" "cannot write in $_ao_dir"
  if ! cat >"$_ao_tmp" || ! ao_place "$_ao_tmp" "$_ao_dir/$AO_T_STAMP-${_ao_slug:-note}" .md; then
    rm -f "$_ao_tmp"
    ao_die "$AO_E_FAIL" "cannot write a note in $_ao_dir"
  fi
}

# ao_note_oracle SLUG TEXT...  One-paragraph note to the Oracle's inbox.
# Returns non-zero (with the reason on stderr) instead of exiting, so a
# scheduled run can count the failure and carry on.
ao_note_oracle() {
  _ao_ns=$1
  shift
  printf '%s\n' "$*" | (ao_inbox_put "$AO_ORACLE_KEY" "$_ao_ns") >/dev/null
}

# ao_inbox_count KEY  Print the number of pending notes in KEY's inbox.
ao_inbox_count() {
  _ao_cnt=0
  for _ao_f in "$AO_INBOX/$1"/*.md; do
    [ -f "$_ao_f" ] && _ao_cnt=$((_ao_cnt + 1))
  done
  printf '%s\n' "$_ao_cnt"
}
