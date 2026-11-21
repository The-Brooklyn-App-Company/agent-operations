#!/bin/sh
# hygiene.sh - the nightly, model-free hygiene check (K-32): what to clean
# as you go, listed in one place.
#
# Usage: hygiene.sh [--note]
#
# Read-only. Prints one line per finding and a summary:
#   holds      a lane hold or the mailroom pause that is expired or lacks an
#              owner, expiry or reason (K-07): it is no longer obeyed
#   switches   a lane switch open for more than a day (lane.sh verify)
#   switches   an operator routine (operator.sh) open for more than a day;
#              a Codex thread marked unresponsive
#   switches   the Claude tier-1 kill switch left on
#   homes      uncommitted or untracked work in the Oracle home or an
#              operator home (K-15); an AGENTS.md over 8000 bytes (the
#              recovery digest's cap)
#   quiet      expired rows in the watchdog quiet list
#   grants     standing grants against the client's permission rules: for
#              each home, every permission rule in its Claude settings
#              (.claude/settings.json and settings.local.json,
#              permissions.allow) must appear in backticks in the Scope cell
#              of a row of MANDATE.md's "Standing grants" table, and every
#              such rule must be installed; a grant past its Expires date is
#              a finding. Codex permission rules are not read (reported
#              once).
#   mailroom   a delivered log over 5000 rows (rotate it)
# --note also writes the findings to the Oracle's inbox when there are any
# (for a daily tick hook: examples/hooks/daily/30-hygiene).
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 clean; 1 findings; 2 usage or configuration error.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"

hy() { printf -- '- %s\n' "$*" >>"$out"; }

hy_holds() {
  for _h in "$AO_STATE/holds"/* "$AO_STATE/mailroom-pause"; do
    [ -f "$_h" ] || continue
    ao_hold_active "$_h" ||
      hy "holds: ${_h##*/} is expired or lacks an owner, expiry or reason, so it is ignored: lane.sh unhold ${_h##*/} (or set it again with all three)"
  done
}

hy_switches() {
  for _s in "$AO_STATE/switch"/*; do
    [ -f "$_s" ] || continue
    _at=$(sed -n 's/^started=//p' "$_s" | tail -n 1)
    ao_is_uint "${_at:-x}" || _at=0
    [ $((AO_T_EPOCH - _at)) -lt 86400 ] || hy "switches: the switch of ${_s##*/} is open since $(ao_utc "$_at") UTC: lane.sh verify ${_s##*/}"
  done
  for _s in "$AO_STATE/routine"/*; do
    [ -f "$_s" ] || continue
    _at=$(sed -n 's/^started=//p' "$_s" | tail -n 1)
    ao_is_uint "${_at:-x}" || _at=0
    [ $((AO_T_EPOCH - _at)) -lt 86400 ] || hy "switches: the $(sed -n 's/^kind=//p' "$_s" | tail -n 1) routine of ${_s##*/} is open since $(ao_utc "$_at") UTC: operator.sh verify ${_s##*/}"
  done
  for _s in "$AO_STATE/mailroom/unhealthy"/*; do
    [ -f "$_s" ] || continue
    hy "switches: Codex thread ${_s##*/} is marked unresponsive: operator.sh list (thread recovery, docs/mailroom.md)"
  done
  _mr=$(ao_cfg_path bridge_dir "$AO_INBOX/.mailroom")
  [ ! -e "$_mr/claude/.watcher/t1-off" ] ||
    hy "switches: the Claude tier-1 kill switch is on since $(ao_utc "$(ao_mtime "$_mr/claude/.watcher/t1-off")") UTC: remove $_mr/claude/.watcher/t1-off when tier 1 is fixed"
  for _side in claude codex; do
    _lg=$_mr/$_side/delivered/log.tsv
    [ ! -f "$_lg" ] || [ "$(wc -l <"$_lg" | tr -d ' ')" -le 5000 ] ||
      hy "mailroom: $_lg has over 5000 rows: rotate it (move it aside; the supervisor reads the last 400)"
  done
}

# hy_grants HOME  Permission rules in the home's Claude settings against
# the backticked rules in its MANDATE.md standing grants.
hy_grants() {
  _rules=$(ao_tmp rules) _grants=$(ao_tmp grants)
  : >"$_rules"
  for _sf in "$1/.claude/settings.json" "$1/.claude/settings.local.json"; do
    [ -f "$_sf" ] || continue
    if ! command -v jq >/dev/null 2>&1; then hy "grants: jq not found; $1 not checked"; return 0; fi
    jq -r '(.permissions.allow // [])[]' "$_sf" >>"$_rules" 2>/dev/null ||
      hy "grants: $_sf is not readable JSON"
  done
  : >"$_grants"
  if [ -f "$1/MANDATE.md" ]; then
    awk -F'|' -v today="$AO_T_DATE" -v home="$1" '
      /^## / { in_g = ($0 ~ /^## Standing grants/); next }
      !in_g || !/^\|/ || /^\| *(Date|---)/ { next }
      {
        until = $(NF - 1); gsub(/ /, "", until)
        if (until ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && until < today)
          printf "EXPIRED\t%s\n", $0
        scope = $4
        while (match(scope, /`[^`]+`/)) { printf "RULE\t%s\n", substr(scope, RSTART + 1, RLENGTH - 2); scope = substr(scope, RSTART + RLENGTH) }
      }' "$1/MANDATE.md" >"$_grants"
  fi
  while IFS="$AO_TAB" read -r _k _v; do
    [ "$_k" = EXPIRED ] && hy "grants: $1/MANDATE.md: a standing grant is past its expiry: $(printf '%s' "$_v" | tr -s ' ' | cut -c 1-160)"
  done <"$_grants"
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    grep -qxF -- "RULE$AO_TAB$_r" "$_grants" || hy "grants: $1: permission rule \`$_r\` has no standing grant in MANDATE.md (record the human's words, or remove the rule)"
  done <"$_rules"
  while IFS="$AO_TAB" read -r _k _v; do
    [ "$_k" = RULE ] || continue
    grep -qxF -- "$_v" "$_rules" || hy "grants: $1: standing grant \`$_v\` is not in the Claude permission rules (install it, or retire the grant)"
  done <"$_grants"
}

hy_home() {
  [ -d "$1" ] || return 0
  if git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
    _n=$(git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "$_n" -eq 0 ] || hy "homes: $1 has $_n uncommitted or untracked path(s): commit, ignore or move them (K-15)"
  fi
  [ ! -f "$1/AGENTS.md" ] || [ "$(wc -c <"$1/AGENTS.md" | tr -d ' ')" -le 8000 ] ||
    hy "homes: $1/AGENTS.md is over 8000 bytes: move detail into the files it points to"
  hy_grants "$1"
}

# shellcheck disable=SC2329 # a registry callback (ao_registry_each)
_hy_row() {
  case " $_seen " in *" $OP_DIR "*) return 0 ;; esac
  _seen="$_seen $OP_DIR"
  [ "$OP_CLIENT" != codex ] || _codex=1
  hy_home "$OP_DIR"
}

main() {
  case ${1-} in
    -h | --help) ao_usage; exit 0 ;;
    --note) _note=1 ;;
    '') _note='' ;;
    *) ao_die "$AO_E_USAGE" "usage: hygiene.sh [--note]" ;;
  esac
  ao_load
  out=$(ao_tmp out)
  : >"$out"
  hy_holds
  hy_switches
  _seen="$AO_HOME" _codex=''
  hy_home "$AO_HOME"
  [ ! -r "$AO_REGISTRY" ] || ao_registry_each _hy_row
  if [ -r "$AO_QUIET" ]; then
    awk -F'\t' -v t="$AO_T_DATE" '!/^#/ && $2 ~ /^[0-9-]+$/ && $2 < t { print $1 " (until " $2 ")" }' "$AO_QUIET" |
      while IFS= read -r _q; do printf -- '- quiet: expired quiet-list row: %s\n' "$_q"; done >>"$out"
  fi
  _n=$(wc -l <"$out" | tr -d ' ')
  cat "$out"
  [ -z "$_codex" ] || echo "(Codex permission rules are not read; check Codex operators' grants by hand.)"
  printf 'hygiene %s: %s finding(s).\n' "$AO_T_DATE" "$_n"
  [ "$_n" -gt 0 ] || exit 0
  if [ -n "$_note" ]; then
    { printf 'Nightly hygiene check (hygiene.sh, automated): %s finding(s). Fix the safe ones as you go; ask the human for the rest.\n\n' "$_n"; cat "$out"; } |
      ao_inbox_put "$AO_ORACLE_KEY" hygiene >/dev/null || ao_warn "could not write the hygiene note"
  fi
  exit "$AO_E_FAIL"
}

main "$@"
