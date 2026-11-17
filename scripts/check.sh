#!/bin/sh
# check.sh - deterministic repository checks: duplicate rule text, skill
# shape, privacy. Needs no profile; safe to run in CI.
#
# Usage: check.sh dupes [--min-words N] FILE...
#        check.sh skills [--max-lines N] DIR...
#        check.sh privacy [--denylist FILE] [PATH...]
#
# dupes    One home per rule: reports any sentence of at least N words
#          (default 10) that appears in more than one of the given Markdown
#          files, after normalising case, punctuation and Markdown markup.
#          Code blocks, table rules and link targets are ignored. Output, one
#          finding per line: `file:line, file:line: "sentence..."`.
# skills   Thin skills: reports every SKILL.md under DIR longer than N lines
#          (default 60) or with no pointer into docs/ or templates/.
# privacy  Reports home-directory paths, e-mail addresses (other than the
#          reserved example.com/.org/.net, .example, .test, .invalid and
#          .localhost domains) and every case-insensitive match of the lines
#          in the denylist (default: $AO_PRIVACY_DENYLIST). Keep the denylist
#          local and untracked. PATHs default to the files git tracks in the
#          current directory. Matching lines are printed as file:line only,
#          never with their text, so the report itself leaks nothing.
#
# Exit codes: 0 clean; 1 findings; 2 usage error.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"

# check_need_number OPTION VALUE...  Die unless VALUE is an integer.
check_need_number() {
  if [ $# -lt 2 ] || ! ao_is_uint "$2"; then
    ao_die "$AO_E_USAGE" "$1 needs a number"
  fi
}

check_dupes() {
  min_words=10
  if [ "${1-}" = --min-words ]; then
    check_need_number "$@"
    min_words=$2
    shift 2
  fi
  [ $# -gt 0 ] || ao_die "$AO_E_USAGE" "dupes needs at least one file"
  for _f in "$@"; do [ -r "$_f" ] || ao_die "$AO_E_USAGE" "not readable: $_f"; done
  _found=$(awk -v minw="$min_words" '
    FNR == 1 { fence = 0 }
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^[[:space:]|:-]*$/ { next }
    {
      t = tolower($0)
      gsub(/<!--[^>]*-->/, " ", t)
      gsub(/\]\([^)]*\)/, "]", t)
      n = split(t, parts, /[.!?;][[:space:]]+|[|]/)
      for (i = 1; i <= n; i++) {
        s = parts[i]
        gsub(/[^a-z0-9]+/, " ", s)
        gsub(/^ +| +$/, "", s)
        if (split(s, words, " ") < minw) continue
        if ((s, FILENAME) in seen) continue
        seen[s, FILENAME] = 1
        count[s]++
        where[s] = where[s] (where[s] == "" ? "" : ", ") FILENAME ":" FNR
      }
    }
    END {
      for (s in count) if (count[s] > 1) printf "%s: \"%s\"\n", where[s], substr(s, 1, 90)
    }' "$@" | sort)
  [ -z "$_found" ] && return 0
  printf '%s\n' "$_found"
  return "$AO_E_FAIL"
}

check_skills() {
  max_lines=60
  if [ "${1-}" = --max-lines ]; then
    check_need_number "$@"
    max_lines=$2
    shift 2
  fi
  [ $# -gt 0 ] || ao_die "$AO_E_USAGE" "skills needs at least one directory"
  for _d in "$@"; do [ -d "$_d" ] || ao_die "$AO_E_USAGE" "not a directory: $_d"; done
  skills=$(ao_tmp skills)
  find "$@" -name SKILL.md -type f | sort >"$skills"
  _bad=0
  while IFS= read -r _s; do
    _n=$(wc -l <"$_s" | tr -d ' ')
    if [ "$_n" -gt "$max_lines" ]; then
      printf '%s: %s lines (cap %s)\n' "$_s" "$_n" "$max_lines"
      _bad=1
    fi
    if ! grep -Eq '(docs|templates)/' "$_s"; then
      printf '%s: no pointer into docs/ or templates/\n' "$_s"
      _bad=1
    fi
  done <"$skills"
  [ "$_bad" -eq 0 ] || return "$AO_E_FAIL"
}

# check_privacy_files PATH...  List the files to scan, one per line.
check_privacy_files() {
  if [ $# -eq 0 ]; then
    git ls-files 2>/dev/null || ao_die "$AO_E_USAGE" "not a git checkout; pass paths explicitly"
    return
  fi
  for _p in "$@"; do
    [ -e "$_p" ] || ao_die "$AO_E_USAGE" "no such path: $_p"
    find "$_p" -type f ! -path '*/.git/*'
  done
}

check_privacy() {
  denylist=${AO_PRIVACY_DENYLIST:-}
  if [ "${1-}" = --denylist ]; then
    [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--denylist needs a file"
    denylist=$2
    shift 2
  fi
  patterns=$(ao_tmp patterns)
  if [ -n "$denylist" ]; then
    [ -r "$denylist" ] || ao_die "$AO_E_USAGE" "denylist not readable: $denylist"
    # Blank lines would match everything; # lines are comments.
    grep -v -e '^[[:space:]]*$' -e '^#' "$denylist" >"$patterns"
  fi
  files=$(ao_tmp files)
  check_privacy_files "$@" >"$files" || exit "$AO_E_USAGE"
  _hits=$(
    while IFS= read -r _f; do
      [ -f "$_f" ] || continue
      grep -EnI "(^|[[:space:]\"'=:(\`])(/Users|/home)/[A-Za-z0-9._-]+" "$_f" | cut -d: -f1 | sed "s|^|$_f:|; s|\$|: home path|"
      grep -EnoI '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$_f" |
        grep -Eiv '@(example\.(com|org|net)|[a-z0-9.-]*\.(example|test|invalid|localhost))$' | cut -d: -f1 | sed "s|^|$_f:|; s|\$|: e-mail address|"
      if [ -s "$patterns" ]; then
        grep -FinI -f "$patterns" "$_f" | cut -d: -f1 | sed "s|^|$_f:|; s|\$|: denylist match|"
      fi
    done <"$files" | sort -u
  )
  [ -z "$_hits" ] && return 0
  printf '%s\n' "$_hits"
  return "$AO_E_FAIL"
}

main() {
  case ${1-} in
    dupes) shift; check_dupes "$@" ;;
    skills) shift; check_skills "$@" ;;
    privacy) shift; check_privacy "$@" ;;
    -h | --help) ao_usage; exit 0 ;;
    *) ao_die "$AO_E_USAGE" "usage: check.sh dupes|skills|privacy ... (see --help)" ;;
  esac
}

main "$@"
