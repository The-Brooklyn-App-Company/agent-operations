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

# ao_registry_has KEY  True when KEY has a registry row.
ao_registry_has() {
  [ -r "$AO_REGISTRY" ] || return 1
  awk -F'\t' -v k="$1" '$1 == k { found = 1; exit } END { exit !found }' "$AO_REGISTRY"
}

# ao_operator_resolve KEY NAME DIR SESSION CLIENT  Set the OP_* variables for
# one operator. This is the single place that decides which provider and
# session currently own an operator. v0.2 reads the registry row; a later
# provider-handoff lease (for example `<operator-home>/.operator/lease`) can
# override OP_CLIENT and OP_SID here without touching any caller.
ao_operator_resolve() {
  OP_KEY=$1 OP_NAME=$2 OP_SID=$4
  OP_DIR=$(ao_expand_path "$3" /)
  OP_CLIENT=$(ao_cfg relay_default claude)
  [ -z "$5" ] || OP_CLIENT=$5
  case $OP_SID in pending | -) OP_SID= ;; esac
}

# ao_gate ACTION  Ask the optional `<hooks_dir>/gate` executable whether an
# action on the current operator may proceed. Called as
#   gate <action> <key> <client> <session>
# with exit 0 = proceed, non-zero (or no answer within 30 s) = skip this
# operator for now. Absent gate: always proceed. Actions today: relay,
# watchdog. A provider-handoff lease check belongs here.
ao_gate() {
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
