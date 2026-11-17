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
  # awk would read an operand like `a=b` as an assignment; ./ prevents it.
  for _f in "$@"; do
    case $_f in /*) set -- "$@" "$_f" ;; *) set -- "$@" "./$_f" ;; esac
    shift
  done
  # Sentences are taken from whole paragraphs (consecutive non-blank lines;
  # each heading, list item, quote or table row starts a new one), so a rule
  # wrapped differently in two files still matches. Locations are the
  # paragraph's first line.
  _found=$(awk -v minw="$min_words" '
    function flush(   t, n, i, s, parts, words) {
      if (buf == "") return
      t = tolower(buf)
      buf = ""
      gsub(/<!--[^>]*-->/, " ", t)
      gsub(/\]\([^)]*\)/, "]", t)
      n = split(t, parts, /[.!?;]([[:space:]]+|$)|[|]/)
      for (i = 1; i <= n; i++) {
        s = parts[i]
        gsub(/[^a-z0-9]+/, " ", s)
        gsub(/^ +| +$/, "", s)
        if (split(s, words, " ") < minw) continue
        if ((s, file) in seen) continue
        seen[s, file] = 1
        count[s]++
        where[s] = where[s] (where[s] == "" ? "" : ", ") file ":" start
      }
    }
    FNR == 1 { flush(); fence = 0; file = FILENAME }
    /^[[:space:]]*(```|~~~)/ { flush(); fence = !fence; next }
    fence { next }
    /^[[:space:]|:-]*$/ { flush(); next }
    /^[[:space:]]*([#>|]|[-*+][[:space:]]|[0-9]+[.)][[:space:]])/ { flush() }
    {
      if (buf == "") start = FNR
      buf = buf " " $0
    }
    END {
      flush()
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

# check_privacy_each PATTERNS FILE...  Scan each text file (internal entry
# point, run through xargs -0 / find -exec so any file name is safe). Exits
# 2 if a file cannot be read.
check_privacy_each() {
  _pat=$1
  shift
  _rc=0
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    [ -r "$_f" ] || { ao_warn "cannot read $_f"; _rc=2; continue; }
    grep -qI . -- "$_f" 2>/dev/null || continue
    check_privacy_scan "$_f" "$_pat" || { ao_warn "could not scan $_f"; _rc=2; }
  done
  return "$_rc"
}

# check_privacy_scan FILE PATTERNS  Print `FILE:LINE: kind` for each finding.
# File names travel through the environment, never through program text.
check_privacy_scan() {
  case $1 in /*) _op=$1 ;; *) _op=./$1 ;; esac
  AO_F=$1 AO_P=$2 awk '
    BEGIN {
      f = ENVIRON["AO_F"]
      while ((getline p < ENVIRON["AO_P"]) > 0) if (p != "") deny[++nd] = tolower(p)
    }
    {
      if ($0 ~ /(^|[[:space:]"\047=:(`])(\/Users|\/home)\/[A-Za-z0-9._-]+/) print f ":" FNR ": home path"
      rest = $0
      while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/)) {
        addr = tolower(substr(rest, RSTART, RLENGTH))
        rest = substr(rest, RSTART + RLENGTH)
        if (addr !~ /@(example\.(com|org|net)|[a-z0-9.-]*\.(example|test|invalid|localhost))$/) {
          print f ":" FNR ": e-mail address"
          break
        }
      }
      low = tolower($0)
      for (i = 1; i <= nd; i++) if (index(low, deny[i])) { print f ":" FNR ": denylist match"; break }
    }' "$_op"
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
  hits=$(ao_tmp hits)
  _err=0
  if [ $# -eq 0 ]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      ao_die "$AO_E_USAGE" "not a git checkout; pass paths explicitly"
    # NUL-delimited, so tracked names with quotes or newlines are scanned too.
    git ls-files -z | xargs -0 "$AO_SCRIPTS/check.sh" __scan "$patterns" >"$hits" || _err=1
  else
    for _p in "$@"; do [ -e "$_p" ] || ao_die "$AO_E_USAGE" "no such path: $_p"; done
    for _p in "$@"; do
      case $_p in -*) _p=./$_p ;; esac
      find "$_p" -type f ! -path '*/.git/*' -exec "$AO_SCRIPTS/check.sh" __scan "$patterns" {} + >>"$hits" || _err=1
    done
  fi
  _hits=$(sort -u "$hits")
  [ "$_err" -eq 0 ] || { [ -n "$_hits" ] && printf '%s\n' "$_hits"; return "$AO_E_FAIL"; }
  [ -z "$_hits" ] && return 0
  printf '%s\n' "$_hits"
  return "$AO_E_FAIL"
}

main() {
  case ${1-} in
    dupes) shift; check_dupes "$@" ;;
    skills) shift; check_skills "$@" ;;
    privacy) shift; check_privacy "$@" ;;
    __scan) shift; check_privacy_each "$@" ;;
    -h | --help) ao_usage; exit 0 ;;
    *) ao_die "$AO_E_USAGE" "usage: check.sh dupes|skills|privacy ... (see --help)" ;;
  esac
}

main "$@"
