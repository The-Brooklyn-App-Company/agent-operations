# shellcheck shell=sh
# guide.sh - helpers for the guided scripts (bootstrap.sh, operator.sh):
# explain a step, ask for a choice, confirm, and keep a checklist's state.
#
# Sourced after core.sh. A guided script asks only when a person is at the
# terminal (stdin is a tty) and --yes was not given; otherwise every choice
# takes its flag or default, is printed, and must be valid, so the same
# script runs unattended and in tests.

AO_GUIDED=

# ao_guide_init [YES]  Guided when stdin is a terminal and YES is empty.
ao_guide_init() {
  AO_GUIDED=
  [ -n "${1-}" ] || { [ -t 0 ] && AO_GUIDED=1; }
  return 0
}

# ao_explain TITLE LINE...  Say what the next step does and why.
ao_explain() {
  printf '\n== %s\n' "$1"
  shift
  for _g_l in "$@"; do printf '   %s\n' "$_g_l"; done
}

# ao_ask VAR PROMPT DEFAULT [CHECK]  Set VAR (a fixed identifier chosen by
# the caller) to the person's answer, or DEFAULT. CHECK is a function that
# must accept the value; unattended, an invalid value is a usage error.
ao_ask() {
  _g_val=$3
  if [ -n "$AO_GUIDED" ]; then
    while :; do
      printf '   %s [%s]: ' "$2" "$3" >&2
      IFS= read -r _g_in || _g_in=
      [ -n "$_g_in" ] || _g_in=$3
      if [ -z "${4-}" ] || "$4" "$_g_in"; then _g_val=$_g_in; break; fi
      printf '   "%s" is not valid here; try again.\n' "$_g_in" >&2
    done
  else
    if [ -n "${4-}" ] && ! "$4" "$_g_val"; then
      ao_die "$AO_E_USAGE" "$2: '$_g_val' is not valid (give it as an option)"
    fi
    printf '   %s: %s\n' "$2" "$_g_val"
  fi
  eval "$1=\$_g_val"
}

# ao_confirm PROMPT  Ask yes or no (default yes); unattended: yes.
ao_confirm() {
  [ -n "$AO_GUIDED" ] || return 0
  printf '   %s [Y/n]: ' "$1" >&2
  IFS= read -r _g_in || _g_in=
  case $_g_in in [Nn]*) return 1 ;; esac
  return 0
}

# ao_pause TEXT  Guided only: wait for Enter (q stops). Returns 1 on q.
ao_pause() {
  [ -n "$AO_GUIDED" ] || return 1
  printf '   %s (Enter to check again, q to stop): ' "$1" >&2
  IFS= read -r _g_in || return 1
  case $_g_in in [Qq]*) return 1 ;; esac
  return 0
}

# ao_unlock  Release this process's kit lock early (before running another
# kit script that takes the same lock).
ao_unlock() {
  if [ -n "$AO_LOCK_FD" ]; then exec 9>&-
  elif [ -n "$AO_LOCK" ] && [ "$(cat "$AO_LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$AO_LOCK"; fi
  AO_LOCK='' AO_LOCK_FD=''
}

# Value checks for ao_ask.
ao_is_client() { case $1 in claude | codex) return 0 ;; esac; return 1; }
ao_is_word() { case $1 in '' | *[!A-Za-z0-9._:-]*) return 1 ;; esac; return 0; }
ao_is_effort() { case $1 in '' | *[!a-z]*) return 1 ;; esac; return 0; }
ao_is_line() { case $1 in '' | *"$AO_TAB"* | *"$AO_NL"*) return 1 ;; esac; return 0; }
# shellcheck disable=SC2088 # a literal ~/ prefix, expanded later
ao_is_dir_path() { case $1 in /* | '~/'*) ao_is_line "$1" ;; *) return 1 ;; esac; }

# ao_st_get FILE KEY / ao_st_set FILE KEY VALUE  key=value checklist state,
# last line wins; written atomically.
ao_st_get() { [ -r "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n 1; }
ao_st_set() {
  mkdir -p "${1%/*}" || ao_die "$AO_E_FAIL" "cannot create ${1%/*}"
  { [ ! -r "$1" ] || grep -v "^$2=" "$1"; printf '%s=%s\n' "$2" "$3"; } | ao_write_atomic "$1" ||
    ao_die "$AO_E_FAIL" "cannot write $1"
}

# ao_step STATE STEP TEXT  One checklist line; anything but PASS counts in
# AO_STEPS_LEFT.
AO_STEPS_LEFT=0
ao_step() {
  printf '%-5s %-13s %s\n' "$1" "$2" "$3"
  [ "$1" = PASS ] || AO_STEPS_LEFT=$((AO_STEPS_LEFT + 1))
}

# ao_conf_get FILE KEY / ao_conf_set FILE KEY VALUE  operator.conf lines
# (parsed literally, never sourced).
ao_conf_get() { [ -r "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n 1; }
ao_conf_set() {
  { [ ! -r "$1" ] || grep -v "^$2=" "$1"; printf '%s=%s\n' "$2" "$3"; } | ao_write_atomic "$1"
}

# ao_registry_session KEY SESSION [CLIENT]  Write SESSION (and CLIENT) into
# KEY's registry row.
ao_registry_session() {
  _g_tmp=$(ao_tmp registry)
  awk -F'\t' -v OFS='\t' -v k="$1" -v s="$2" -v c="${3-}" '
    $1 == k { $4 = s; if (c != "") $5 = c }
    { print }' "$AO_REGISTRY" >"$_g_tmp" && ao_write_atomic "$AO_REGISTRY" <"$_g_tmp"
}

# ao_git_commit DIR MESSAGE PATH...  Commit PATHs in DIR's repository if it
# is one; quiet when there is nothing to commit.
ao_git_commit() {
  _g_d=$1 _g_m=$2
  shift 2
  git -C "$_g_d" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$_g_d" add -- "$@" >/dev/null 2>&1 || return 1
  git -C "$_g_d" diff --cached --quiet 2>/dev/null && return 0
  git -C "$_g_d" commit -q -m "$_g_m" >/dev/null 2>&1
}
