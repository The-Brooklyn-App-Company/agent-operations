#!/bin/sh
# status.sh - one line per operator: activity, quiet-list state, inbox depth.
#
# Usage: status.sh [--tsv] [--all]
#        status.sh --drift [--tsv]
#
# Columns: key, name, client, state, quiet (until date or -), inbox (pending
# notes), audit. State is idle_min=<n> (minutes since the session's
# transcript last changed), no-transcript, pending (no session id yet) or
# unknown (the client exposes no activity, e.g. file-only). Audit is the
# switch-in audit after a move to the other model family (kit rule K-22,
# lib/registry.sh): pending (no new work until the incoming session records
# its report with `lease.sh audit-done`), done, invalid (its record cannot
# be read: a human inspects it) or - (none seen). Read-only: writes nothing.
#
# --drift compares, across clients, the registry, the lease holders, each
# home's instruction pointers and operator.conf, and the kit pin, and prints
# one line per mismatch with its fix (key, kind, detail, fix); nothing when
# all agree. Kinds: home (missing home), pointer (AGENTS.md or CLAUDE.md
# missing or not importing AGENTS.md), settings (settings/handoff.md
# missing), config (operator.conf missing), client (an operator has no session name for a client others
# use), name (registry, operator.conf and lease name the session
# differently), key (operator.conf key differs from the registry key),
# session (a registered session id with no transcript), lease (unreadable),
# pin (KIT.local.md or AGENTS.md cites another kit version than this
# checkout).
#
# Options:
#   --tsv       tab-separated, no header (for scripts)
#   --all       include the Oracle's own row
#   --drift     report drift instead of the status table
#   -h, --help  this text
#
# Environment: AO_PROFILE.
#
# Warnings about the profile (such as single-family cross-review) and a
# mailroom bridge whose watcher is not armed go to stderr.
#
# Exit codes: 0 printed (with --drift: no drift); 1 drift found (--drift);
# 2 usage or configuration error.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"
. "$AO_SCRIPTS/lib/mailroom.sh"

status_row() {
  [ -n "$all" ] || [ "$OP_KEY" != "$AO_ORACLE_KEY" ] || return 0
  _q=$(ao_quiet_until "$OP_KEY" "$OP_NAME")
  if [ -n "$tsv" ]; then _fmt='%s\t%s\t%s\t%s\t%s\t%s\t%s\n'; else _fmt='%-14s %-24s %-9s %-16s %-11s %-5s %s\n'; fi
  # shellcheck disable=SC2059 # the format is one of the two literals above
  printf "$_fmt" "$OP_KEY" "$OP_NAME" "$OP_CLIENT" "$(ao_idle_state)" "${_q:--}" "$(ao_inbox_count "$OP_KEY")" "$OP_AUDIT"
}

# ---------------------------------------------------------------- drift

# drift KIND DETAIL FIX  Report one mismatch for the current operator.
drift() {
  drifted=$((drifted + 1))
  if [ -n "$tsv" ]; then
    printf '%s\t%s\t%s\t%s\n' "$OP_KEY" "$1" "$2" "$3"
  else
    printf '%s: %s: %s\n    fix: %s\n' "$OP_KEY" "$1" "$2" "$3"
  fi
}

# drift_clients_row  Registry callback: collect the clients in use (registry
# client, operator.conf session.<client> lines, lease providers).
drift_clients_row() {
  for _c in "$OP_PROVIDER" $(sed -n 's/^[[:space:]]*session\.\([a-z]*\)=.*/\1/p' "$OP_DIR/operator.conf" 2>/dev/null); do
    ao_is_family "$_c" || continue
    case " $clients " in *" $_c "*) ;; *) clients="$clients $_c" ;; esac
  done
}

drift_row() {
  _h=$OP_DIR
  if [ ! -d "$_h" ]; then
    drift home "home $_h not found" "install.sh operator $OP_KEY --home $_h (or remove the row from the registry)"
    return 0
  fi
  [ -f "$_h/AGENTS.md" ] || drift pointer "AGENTS.md missing (Codex reads it; CLAUDE.md imports it)" "install.sh sync <client>"
  if [ ! -f "$_h/CLAUDE.md" ]; then
    drift pointer "CLAUDE.md missing (Claude Code reads it)" "install.sh sync claude"
  elif ! grep -qxF '@AGENTS.md' "$_h/CLAUDE.md"; then
    drift pointer "CLAUDE.md does not import @AGENTS.md: the two clients read different instructions" "add the line @AGENTS.md to $_h/CLAUDE.md"
  fi
  [ -f "$_h/settings/handoff.md" ] || drift settings "settings/handoff.md missing" "install.sh sync <client>, then apply it to each client yourself"
  _conf=$_h/operator.conf
  if [ ! -f "$_conf" ]; then
    drift config "operator.conf missing: no session names, no lease" "install.sh sync <client>"
  else
    _k=$(ao_conf_get "$_h" key) || _k=
    if [ -z "$_k" ]; then
      drift key "operator.conf has no key= line" "add key=$OP_KEY to $_conf"
    elif [ "$_k" != "$OP_KEY" ]; then
      drift key "operator.conf says key=$_k, the registry says $OP_KEY (renamed?)" "make them agree: rename the registry row or the key= line (and the inbox folder)"
    fi
    for _c in $clients; do
      _sn=$(ao_conf_get "$_h" "session.$_c") || _sn=
      if [ -z "$_sn" ]; then
        drift client "no session name for $_c (the other client does not know this operator)" "install.sh sync $_c, then start and name the $_c session"
        continue
      fi
      # The registry row names the session on its own client.
      if [ "$OP_LEASE" = none ] && [ "$_c" = "$OP_PROVIDER" ] && [ "$_sn" != "$OP_NAME" ]; then
        drift name "registry names the $_c session \"$OP_NAME\", operator.conf session.$_c=\"$_sn\"" "rename one so they agree (the relay addresses the registry name)"
      fi
      if [ "$OP_LEASE" = held ] && [ "$_c" = "$OP_PROVIDER" ] && [ "$_sn" != "$OP_NAME" ]; then
        drift name "the lease holder is $_c \"$OP_NAME\", operator.conf session.$_c=\"$_sn\"" "rename the session or the session.$_c line so they agree"
      fi
    done
  fi
  case $OP_LEASE in
    invalid) drift lease "the lease in $_h/.operator/lease is unreadable or invalid (held for every action)" "inspect it; lease.sh --home $_h status" ;;
  esac
  if [ "$OP_LEASE" = none ] && [ -n "$OP_SID" ] && [ "$(ao_idle_state)" = no-transcript ]; then
    drift session "registered session id $OP_SID has no $OP_CLIENT transcript (stale or from another machine)" "put the current session id, or pending, in the registry row"
  fi
  # shellcheck disable=SC2016 # the backticks are literal Markdown
  _av=$(sed -n 's/.*Agent Operations kit (`[^`]*`, version \([^)]*\)).*/\1/p' "$_h/AGENTS.md" 2>/dev/null | head -n 1)
  [ -z "$_av" ] || [ -z "$kit_version" ] || [ "$_av" = "$kit_version" ] ||
    drift pin "AGENTS.md cites kit version $_av, this checkout is $kit_version" "read CHANGELOG.md for the difference, then update the version in $_h/AGENTS.md"
}

# drift_main  The --drift report.
drift_main() {
  drifted=0 clients=''
  kit_version=$(cat "$AO_SCRIPTS/../VERSION" 2>/dev/null) || kit_version=
  ao_registry_each drift_clients_row
  [ -n "$tsv" ] || printf 'clients in use:%s; kit %s\n' "${clients:- none}" "${kit_version:-unknown}"
  ao_registry_each drift_row
  OP_KEY=$AO_ORACLE_KEY
  _pin=$(sed -n 's/^version: *//p' "$AO_HOME/KIT.local.md" 2>/dev/null | head -n 1)
  [ -z "$_pin" ] || [ -z "$kit_version" ] || [ "$_pin" = "$kit_version" ] ||
    drift pin "KIT.local.md pins kit $_pin, this checkout is $kit_version" "read CHANGELOG.md, then update version: and commit: in $AO_HOME/KIT.local.md (or check out the pinned kit)"
  _pc=$(sed -n 's/^commit: *//p' "$AO_HOME/KIT.local.md" 2>/dev/null | head -n 1)
  _kit=$AO_SCRIPTS/..
  case $_pc in '' | unknown | *[!0-9a-f]*) ;; *)
    if _head=$(git -C "$_kit" rev-parse -q --verify HEAD 2>/dev/null); then
      _full=$(git -C "$_kit" rev-parse -q --verify "$_pc^{commit}" 2>/dev/null) || _full=
      [ "$_full" = "$_head" ] ||
        drift pin "KIT.local.md pins commit $_pc, this checkout is at $(printf '%s' "$_head" | cut -c1-12)" "read the kit's log since the pin, then update commit: (and version:) in $AO_HOME/KIT.local.md"
    fi ;;
  esac
  [ -n "$tsv" ] || [ "$drifted" -gt 0 ] || echo "no drift"
  [ "$drifted" -eq 0 ] || exit "$AO_E_FAIL"
}

main() {
  tsv='' all='' drift_mode=''
  while [ $# -gt 0 ]; do
    case $1 in
      --tsv) tsv=1 ;;
      --all) all=1 ;;
      --drift) drift_mode=1 ;;
      -h | --help) ao_usage; exit 0 ;;
      *) ao_die "$AO_E_USAGE" "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  ao_load --no-state
  if [ -n "$drift_mode" ]; then drift_main; return; fi
  [ -n "$tsv" ] || printf '%-14s %-24s %-9s %-16s %-11s %-5s %s\n' KEY NAME CLIENT STATE QUIET INBOX AUDIT
  ao_registry_each status_row
  status_warnings
}

# status_warnings  Profile problems worth seeing every time (stderr).
status_warnings() {
  ao_mr_init
  if [ "$AO_MR_ON" = on ]; then
    for _s in claude codex; do
      ! ao_mr_bridge "$_s" || ao_mr_watcher_up "$_s" ||
        ao_warn "mailroom: the $_s bridge watcher is not armed (mailroom.sh status; docs/mailroom.md)"
    done
  fi
  [ "$(ao_cfg cross_review on)" != off ] || return 0
  if [ -z "$(ao_cfg reviewer_claude_model '')" ] || [ -z "$(ao_cfg reviewer_codex_model '')" ]; then
    ao_warn "cross-review is single-family: set reviewer_claude_model and reviewer_codex_model for cross-family review (kit rule K-22); same-family reviews are marked as such"
  fi
}

main "$@"
