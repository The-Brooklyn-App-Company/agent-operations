#!/bin/sh
# recover-context.sh - compaction recovery digest, for a SessionStart hook.
#
# Usage: recover-context.sh [--cap BYTES] [DIR]
#
# Register it in Claude Code as a SessionStart hook with the matcher
# `compact|resume` (templates/home/settings/README.md). It reads the hook's
# JSON on stdin and uses its "cwd" (or DIR) to pick the home:
#   the Oracle home   the rule titles, an order to read the full rules,
#                     overlays, backlog and mandate first, the backlog's open
#                     rows, the latest journal headings, the inbox depth and
#                     the next checks
#   an operator home  (a registry row's home) the rule titles, an order to
#                     read the full rules, mandate and notes first, the
#                     newest notes and the next checks
#   anywhere else     nothing
#
# Size cap: Claude Code replaces SessionStart hook output over about 10 KB
# with a 2 KB preview (observed in the desktop app, November 2026; the limit
# is not documented and may change). So this prints a digest, never whole
# files, and cuts it at BYTES (default 8000). The read-first order comes
# first, so a cut never loses it. tests/t_recover.sh fails above the cap.
#
# Environment: AO_PROFILE. Without a readable profile it prints nothing.
#
# Exit codes: always 0 (a recovery hook must never block a session), except
# 2 for a usage error.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"

KIT_RULES=$AO_SCRIPTS/../kit/KIT.md

rc_cut() { cut -c "1-${1:-200}"; }

# rc_titles FILE PREFIX  Rule IDs and titles, `K-01 Title; K-02 ...`.
rc_titles() {
  [ -r "$1" ] || return 0
  sed -n "s/^\\*\\*\\($2-[0-9][0-9]*\\) \\([^*]*\\)\\*\\*.*/\\1 \\2/p" "$1" |
    sed 's/[.]$//' | tr '\n' ';' | sed 's/;$//; s/;/; /g' | rc_cut 2400
  echo
}

rc_oracle() {
  echo "## Oracle recovery ($AO_T_DATE). The files win over any summary; if they disagree, say so."
  echo "FIRST, before any other action, read in full: $KIT_RULES, $AO_HOME/KIT.local.md, $AO_HOME/BACKLOG.md (open items) and $AO_HOME/MANDATE.md. This digest is deliberately short."
  echo "Kit rules: $(rc_titles "$KIT_RULES" K)"
  _p=$(rc_titles "$AO_HOME/KIT.local.md" P)
  [ -z "$_p" ] || echo "Personal rules: $_p"
  echo "## Backlog, open rows (first 200 characters each)"
  grep '^|' "$AO_HOME/BACKLOG.md" 2>/dev/null | sed '1,2d' | head -n 15 | rc_cut 200
  echo "## Journal, latest headings"
  grep -E '^#{2,3} ' "$AO_HOME/JOURNAL.md" 2>/dev/null | tail -n 12 | rc_cut 120
  _n=0
  for _f in "$AO_INBOX/$AO_ORACLE_KEY"/*.md; do [ -f "$_f" ] && _n=$((_n + 1)); done
  echo "## Inbox: $_n unread note(s) in $AO_INBOX/$AO_ORACLE_KEY"
  echo "Then: $AO_SCRIPTS/status.sh, $AO_SCRIPTS/mailroom.sh status, SCHEDULES.md, and each operator's product progress (K-35)."
}

rc_operator() { # KEY NAME HOME
  echo "## $2 recovery ($AO_T_DATE). The files win over any summary."
  echo "FIRST, before any other action, read in full: $KIT_RULES, $3/AGENTS.md, $3/MANDATE.md and $3/NOTES.md. This digest is deliberately short."
  echo "Kit rules: $(rc_titles "$KIT_RULES" K)"
  echo "## Newest notes ($3/NOTES.md)"
  # Notes are newest first: the lines after the first dated heading.
  awk '/^## / { n++ } n >= 1 && n <= 2' "$3/NOTES.md" 2>/dev/null | head -n 14 | rc_cut 240
  echo "Then: your inbox, your open pull requests and tasks, and the next step toward your mandate's finish line."
}

main() {
  cap=8000 dir=
  while [ $# -gt 0 ]; do
    case $1 in
      --cap)
        if [ $# -lt 2 ] || ! ao_is_uint "$2"; then ao_die "$AO_E_USAGE" "--cap needs a number"; fi
        cap=$2
        shift ;;
      -h | --help) ao_usage; exit 0 ;;
      -*) ao_die "$AO_E_USAGE" "unknown option '$1'" ;;
      *) dir=$1 ;;
    esac
    shift
  done
  if [ -z "$dir" ] && [ ! -t 0 ]; then
    _in=$(head -c 65536)
    if command -v jq >/dev/null 2>&1; then
      dir=$(printf '%s' "$_in" | jq -r '.cwd // empty' 2>/dev/null)
    else
      dir=$(printf '%s' "$_in" | tr -d '\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
  fi
  [ -n "$dir" ] || dir=$PWD
  [ -r "$(ao_profile_path)" ] || exit 0
  (ao_load --no-state) >/dev/null 2>&1 || exit 0
  ao_load --no-state 2>/dev/null
  dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || exit 0
  _home=$(CDPATH='' cd -- "$AO_HOME" && pwd -P)
  {
    _hit=
    if [ -r "$AO_REGISTRY" ]; then
      while IFS="$AO_TAB" read -r _k _nm _d _rest <&3; do
        case ${_k:-#} in '#'*) continue ;; esac
        [ "$_k" != "$AO_ORACLE_KEY" ] || continue
        _h=$(CDPATH='' cd -- "$(ao_expand_path "${_d:--}" /)" 2>/dev/null && pwd -P) || continue
        [ "$_h" != "$_home" ] || continue
        case $dir/ in "$_h"/*) rc_operator "$_k" "$_nm" "$_h"; _hit=1; break ;; esac
      done 3<"$AO_REGISTRY"
    fi
    if [ -z "$_hit" ]; then
      case $dir/ in "$_home"/*) rc_oracle ;; esac
    fi
  } 2>/dev/null | head -c "$cap"
  exit 0
}

main "$@"
