#!/bin/sh
# check.sh - deterministic checks: links, duplicate rule text, skill shape,
# home layout, privacy, and host settings. Needs no profile (host reads one
# when present); safe to run in CI.
#
# Usage: check.sh kit
#        check.sh links [FILE...]
#        check.sh dupes [--min-words N] FILE...
#        check.sh skills [--max-lines N] DIR...
#        check.sh home DIR...
#        check.sh privacy [--denylist FILE] [PATH...]
#        check.sh host
#
# kit      Run in a kit checkout (CI does): links over every tracked
#          Markdown file and skills over skills/ must pass, and
#          kit/KIT.md must stay within its byte budget (11000); duplicate
#          rule text across kit/, docs/ and skills/ is reported as a warning.
# links    Every relative Markdown link [text](target) in the given files
#          (default: the Markdown files git tracks here) must name an
#          existing file or directory, and a #fragment must match a heading
#          in the target (GitHub's anchor rules, ASCII). Web, mail and
#          absolute links are not checked. Output: `file:line: target`.
# dupes    One home per rule: reports any sentence of at least N words
#          (default 10) that appears in more than one of the given Markdown
#          files, after normalising case, punctuation and Markdown markup.
#          Code blocks, table rules and link targets are ignored. Output, one
#          finding per line: `file:line, file:line: "sentence..."`.
# skills   Thin skills: reports every SKILL.md under DIR longer than N lines
#          (default 60) or with no pointer into docs/ or templates/.
# home     A kit-managed operator home: AGENTS.md and MANDATE.md exist;
#          CLAUDE.md, if present, only imports AGENTS.md (`@AGENTS.md`);
#          operator.conf, if present, has only key, session.<client>,
#          model.<client>, effort.<client>, archived and
#          work.<name>=<url>|owner|contributor lines. Across all DIRs, a
#          repository URL may have only one owner.
# privacy  Reports home-directory paths (a macOS user folder anywhere; a
#          Linux home folder, a ~user path or a Windows user folder at the
#          start of a path), e-mail addresses
#          (other than the reserved example.com/.org/.net and their
#          subdomains, .example, .test, .invalid and .localhost) and every
#          case-insensitive match of the lines in the denylist (default:
#          $AO_PRIVACY_DENYLIST), in file contents and in file names. A
#          denylist line starting with `=` matches whole words only (`=ann`
#          finds "Ann" but not "planned"). Binary files are listed as not
#          scanned. Keep the denylist local and untracked. PATHs default to
#          the files git tracks in the current directory. Matching lines are
#          printed as file:line only, never with their text, so the report
#          itself leaks nothing. Git history and author metadata are out of scope.
# host     An always-on macOS host (reads the profile when there is one;
#          read-only). App Nap: every desktop app in host_apps that has run
#          here must have NSAppSleepDisabled set (fix: install.sh host, then
#          restart the app). launchd: every job in host_launchd_dirs whose
#          Label matches a host_latency_jobs pattern (default: the kit's own
#          tick and relay; add your schedulers, watchers, alert routes and
#          CI forwarders) must not set ProcessType Background (or Adaptive)
#          or LowPriorityIO: launchd throttles those. Output, one finding
#          per line: `app-nap: <bundle id>` or `launchd: <file>: <label>:
#          <setting>`. Without `defaults` the App Nap part is skipped.
#
# Exit codes: 0 clean; 1 findings, or a scan that could not complete (the
# message says which); 2 usage error.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"

# The rules file's byte budget (check.sh kit).
AO_KIT_BUDGET=11000

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
  found=$(ao_tmp found)
  awk -v minw="$min_words" '
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
    }' "$@" >"$found" || ao_die "$AO_E_USAGE" "duplicate scan failed"
  [ -s "$found" ] || return 0
  sort "$found"
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
  find "$@" -name SKILL.md -type f >"$skills.raw" || ao_die "$AO_E_USAGE" "cannot list skills"
  sort "$skills.raw" >"$skills"
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

# check_links [FILE...]  Report dead relative links and fragments.
check_links() {
  if [ $# -eq 0 ]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      ao_die "$AO_E_USAGE" "not a git checkout; pass files explicitly"
    _list=$(ao_tmp mdlist)
    git ls-files -z -- '*.md' >"$_list" || ao_die "$AO_E_USAGE" "git ls-files failed"
    [ -s "$_list" ] || return 0
    xargs -0 "$AO_SCRIPTS/check.sh" links <"$_list"
    return
  fi
  _bad=0
  for _f in "$@"; do
    [ -r "$_f" ] || ao_die "$AO_E_USAGE" "not readable: $_f"
    _dir=$(dirname -- "$_f")
    # One line per link: LINE<TAB>TARGET (code blocks and spans skipped).
    check_link_targets "$_f" >"$AO_TMPDIR/links" || ao_die "$AO_E_FAIL" "cannot read links in $_f"
    while IFS="$AO_TAB" read -r _ln _t; do
      case $_t in
        '' | http:* | https:* | mailto:* | /*) continue ;;
        '#'*) _path=$_f _frag=${_t#\#} ;;
        *'#'*) _path=$_dir/${_t%%#*} _frag=${_t#*#} ;;
        *) _path=$_dir/$_t _frag= ;;
      esac
      if [ ! -e "$_path" ]; then
        printf '%s:%s: %s\n' "$_f" "$_ln" "$_t"
        _bad=1
      elif [ -n "$_frag" ] && [ -f "$_path" ] && ! check_link_anchors "$_path" | grep -Fxq -- "$_frag"; then
        printf '%s:%s: %s (no such heading)\n' "$_f" "$_ln" "$_t"
        _bad=1
      fi
    done <"$AO_TMPDIR/links"
  done
  [ "$_bad" -eq 0 ] || return "$AO_E_FAIL"
}

check_link_targets() {
  case $1 in /*) _op=$1 ;; *) _op=./$1 ;; esac
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      while (match(line, /\]\([^)[:space:]]+\)/)) {
        t = substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
        print FNR "\t" t
      }
    }' "$_op"
}

# check_link_anchors FILE  Print the GitHub anchor of every heading.
check_link_anchors() {
  case $1 in /*) _op=$1 ;; *) _op=./$1 ;; esac
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^#+[[:space:]]/ {
      h = $0
      sub(/^#+[[:space:]]+/, "", h)
      sub(/[[:space:]]+#+[[:space:]]*$/, "", h)
      h = tolower(h)
      gsub(/[^a-z0-9 _-]/, "", h)
      gsub(/ /, "-", h)
      if (h in seen) { n = seen[h]++; print h "-" n } else { seen[h] = 1; print h }
    }' "$_op"
}

# check_home DIR...  Kit-managed home layout and single ownership.
check_home() {
  [ $# -gt 0 ] || ao_die "$AO_E_USAGE" "home needs at least one directory"
  _bad=0
  _owners=$(ao_tmp owners)
  for _h in "$@"; do
    [ -d "$_h" ] || ao_die "$AO_E_USAGE" "not a directory: $_h"
    for _req in AGENTS.md MANDATE.md; do
      [ -f "$_h/$_req" ] || { printf '%s: missing %s\n' "$_h" "$_req"; _bad=1; }
    done
    if [ -f "$_h/CLAUDE.md" ] && [ "$(grep -v '^[[:space:]]*$' "$_h/CLAUDE.md")" != "@AGENTS.md" ]; then
      printf '%s/CLAUDE.md: must contain only @AGENTS.md\n' "$_h"
      _bad=1
    fi
    [ -f "$_h/operator.conf" ] || continue
    _n=0
    while IFS= read -r _l || [ -n "$_l" ]; do
      _n=$((_n + 1))
      case $_l in '' | '#'*) continue ;; esac
      _k=${_l%%=*} _v=${_l#*=}
      case $_k in
        key) ao_is_name "$_v" || { printf '%s/operator.conf:%s: invalid key\n' "$_h" "$_n"; _bad=1; } ;;
        session.claude | session.codex | session.custom | session.file-only) ;;
        model.claude | model.codex | effort.claude | effort.codex)
          case $_v in '' | *[!A-Za-z0-9._:-]*) printf '%s/operator.conf:%s: %s must be one word\n' "$_h" "$_n" "$_k"; _bad=1 ;; esac ;;
        archived) ;;
        work.*)
          case $_v in
            *'|owner') printf '%s\t%s\n' "$(ao_repo_key "${_v%|owner}")" "$_h" >>"$_owners" ;;
            *'|contributor') ;;
            *) printf '%s/operator.conf:%s: work value must end in |owner or |contributor\n' "$_h" "$_n"; _bad=1 ;;
          esac ;;
        *) printf '%s/operator.conf:%s: unknown key %s\n' "$_h" "$_n" "$_k"; _bad=1 ;;
      esac
    done <"$_h/operator.conf"
  done
  _dups=$(cut -f 1 "$_owners" | sort | uniq -d)
  if [ -n "$_dups" ]; then
    printf '%s\n' "$_dups" | while IFS= read -r _u; do printf 'owned by more than one home: %s\n' "$_u"; done
    _bad=1
  fi
  [ "$_bad" -eq 0 ] || return "$AO_E_FAIL"
}

# check_kit  The kit repository's own gate.
check_kit() {
  [ -f kit/KIT.md ] && [ -d skills ] || ao_die "$AO_E_USAGE" "run check.sh kit at the root of a kit checkout"
  _rc=0
  check_links || _rc=$AO_E_FAIL
  check_skills skills || _rc=$AO_E_FAIL
  # The rules stay readable in one sitting: a new rule replaces words, it
  # does not add them (K-32).
  _kb=$(wc -c <kit/KIT.md | tr -d ' ')
  if [ "$_kb" -gt "$AO_KIT_BUDGET" ]; then
    printf 'kit/KIT.md is %s bytes, over its budget of %s: replace rather than add (K-32)\n' "$_kb" "$AO_KIT_BUDGET"
    _rc=$AO_E_FAIL
  fi
  set -- kit/KIT.md docs/*.md skills/*/SKILL.md
  if ! _d=$(check_dupes "$@"); then
    printf 'warning: duplicated rule text (keep one home, point to it):\n%s\n' "$_d"
  fi
  return "$_rc"
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
    check_privacy_name "$_f" "$_pat"
    # grep: 0 text, 1 binary or empty, 2 error (fail).
    grep -qI . -- "$_f" 2>/dev/null
    case $? in
      0) ;;
      1) [ ! -s "$_f" ] || printf '%s: binary, not scanned\n' "$_f"; continue ;;
      *) ao_warn "cannot read $_f"; _rc=2; continue ;;
    esac
    check_privacy_scan "$_f" "$_pat" || { ao_warn "could not scan $_f"; _rc=2; }
  done
  return "$_rc"
}

# check_privacy_name FILE PATTERNS  Report a denylist match in the path.
check_privacy_name() {
  AO_F=$1 AO_P=$2 awk 'BEGIN {
    f = ENVIRON["AO_F"]; low = tolower(f)
    while ((getline p < ENVIRON["AO_P"]) > 0) {
      p = tolower(p); w = 0
      if (substr(p, 1, 1) == "=") { p = substr(p, 2); w = 1 }
      if (p == "") continue
      if (w ? wordin(low, p) : index(low, p)) { print f ": denylist match in the file name"; exit }
    }
  }
  '"$CHECK_AWK_WORDIN"
}

# Shared awk: wordin(text, word) is true when word occurs in text with no
# letter or digit on either side.
CHECK_AWK_WORDIN='
  function wordin(t, w,   i, b, a) {
    while ((i = index(t, w)) > 0) {
      b = i > 1 ? substr(t, i - 1, 1) : ""
      a = substr(t, i + length(w), 1)
      if (b !~ /[a-z0-9]/ && a !~ /[a-z0-9]/) return 1
      t = substr(t, i + 1)
    }
    return 0
  }'


# check_privacy_scan FILE PATTERNS  Print `FILE:LINE: kind` for each finding.
# File names travel through the environment, never through program text.
check_privacy_scan() {
  case $1 in /*) _op=$1 ;; *) _op=./$1 ;; esac
  AO_F=$1 AO_P=$2 awk '
    BEGIN {
      f = ENVIRON["AO_F"]
      while ((getline p < ENVIRON["AO_P"]) > 0) {
        p = tolower(p); w = 0
        if (substr(p, 1, 1) == "=") { p = substr(p, 2); w = 1 }
        if (p != "") { deny[++nd] = p; word[nd] = w }
      }
    }
    {
      if ($0 ~ /\/Users\/[A-Za-z0-9._-]+/ || $0 ~ /(^|[^A-Za-z0-9_}.$-])\/home\/[A-Za-z0-9._-]+/ || $0 ~ /(^|[^A-Za-z0-9])~[a-z][a-z0-9_-]*\// || $0 ~ /[A-Za-z]:(\\)+Users(\\)+/) print f ":" FNR ": home path"
      rest = $0
      while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/)) {
        addr = tolower(substr(rest, RSTART, RLENGTH))
        rest = substr(rest, RSTART + RLENGTH)
        if (addr !~ /@([a-z0-9-]+\.)*(example\.(com|org|net)|example|test|invalid|localhost)$/) {
          print f ":" FNR ": e-mail address"
          break
        }
      }
      low = tolower($0)
      for (i = 1; i <= nd; i++) if (word[i] ? wordin(low, deny[i]) : index(low, deny[i])) { print f ":" FNR ": denylist match"; break }
    }
    '"$CHECK_AWK_WORDIN" "$_op"
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
    inventory=$(ao_tmp inventory)
    git ls-files -z >"$inventory" || ao_die "$AO_E_USAGE" "git ls-files failed"
    if [ -s "$inventory" ]; then
      xargs -0 "$AO_SCRIPTS/check.sh" __scan "$patterns" <"$inventory" >"$hits" || _err=1
    fi
  else
    for _p in "$@"; do [ -e "$_p" ] || ao_die "$AO_E_USAGE" "no such path: $_p"; done
    for _p in "$@"; do
      case $_p in -*) _p=./$_p ;; esac
      find "$_p" -type f ! -path '*/.git/*' -exec "$AO_SCRIPTS/check.sh" __scan "$patterns" {} + >>"$hits" || _err=1
    done
  fi
  _hits=$(sort -u "$hits") || _err=1
  if [ "$_err" -ne 0 ]; then
    [ -z "$_hits" ] || printf '%s\n' "$_hits"
    ao_msg "privacy scan incomplete: some files could not be read"
    return "$AO_E_FAIL"
  fi
  [ -z "$_hits" ] && return 0
  printf '%s\n' "$_hits"
  return "$AO_E_FAIL"
}

# check_host  App Nap and launchd priority on an always-on host.
check_host() {
  [ $# -eq 0 ] || ao_die "$AO_E_USAGE" "usage: check.sh host"
  _pf=$(ao_profile_path)
  [ ! -r "$_pf" ] || ao_profile_parse "$_pf"
  _apps=$(ao_cfg host_apps "$AO_HOST_APPS")
  _jobs=$(ao_cfg host_latency_jobs "$AO_HOST_LATENCY_JOBS")
  _dirs=$(ao_cfg host_launchd_dirs "$AO_HOST_LAUNCHD_DIRS")
  _hits=$(ao_tmp host-hits)
  if command -v defaults >/dev/null 2>&1 && [ "$_apps" != none ]; then
    for _id in $_apps; do
      # Only apps that have run here (their defaults domain exists).
      defaults read "$_id" >/dev/null 2>&1 || continue
      [ "$(defaults read "$_id" NSAppSleepDisabled 2>/dev/null)" = 1 ] ||
        printf 'app-nap: %s (fix: install.sh host, then restart the app)\n' "$_id" >>"$_hits"
    done
  fi
  [ "$_jobs" != none ] || _dirs=
  set -f
  for _d in $_dirs; do
    set +f
    _d=$(ao_expand_path "$_d" /)
    for _p in "$_d"/*.plist; do
      [ -f "$_p" ] || continue
      check_host_plist "$_p" "$_jobs" >>"$_hits"
    done
    set -f
  done
  set +f
  [ -s "$_hits" ] || return 0
  cat "$_hits"
  return "$AO_E_FAIL"
}

# check_host_plist FILE PATTERNS  Print a finding for a latency-sensitive
# job that launchd would throttle. Binary plists are read through plutil.
check_host_plist() {
  if command -v plutil >/dev/null 2>&1; then
    _xml=$(plutil -convert xml1 -o - "$1" 2>/dev/null) || _xml=$(cat "$1")
  else
    _xml=$(cat "$1")
  fi
  # Top-level keys of the outer <dict> only (nested dictionaries such as
  # EnvironmentVariables never count): `key type value` per line.
  _kv=$(printf '%s\n' "$_xml" | tr -d '\n\t' | sed 's|<|\
<|g' | awk '
    /^<dict>/ { depth++; if (depth > 1) k = ""; next }
    /^<\/dict>/ { depth--; next }
    /^<array>/ { depth++; k = ""; next }
    /^<\/array>/ { depth--; next }
    depth != 1 { next }
    /^<key>/ { k = substr($0, 6); next }
    k != "" && /^<[a-z]+\/?>/ {
      t = $0; sub(/^</, "", t); v = t; sub(/[\/]?>.*/, "", t); sub(/^[^>]*>/, "", v)
      print k, t, v; k = ""
    }')
  _label=$(printf '%s\n' "$_kv" | awk '$1 == "Label" { print $3; exit }')
  [ -n "$_label" ] || return 0
  _hit=
  set -f
  for _pat in $2; do
    # shellcheck disable=SC2254 # the pattern is a glob on purpose
    case $_label in $_pat) _hit=1 ;; esac
  done
  set +f
  [ -n "$_hit" ] || return 0
  _pt=$(printf '%s\n' "$_kv" | awk '$1 == "ProcessType" { print $3; exit }')
  case $_pt in Background | Adaptive) printf 'launchd: %s: %s: ProcessType %s (use Standard or leave it unset)\n' "$1" "$_label" "$_pt" ;; esac
  printf '%s\n' "$_kv" | awk '$1 == "LowPriorityIO" && $2 == "true" { f = 1 } END { exit !f }' &&
    printf 'launchd: %s: %s: LowPriorityIO true (remove it)\n' "$1" "$_label"
  return 0
}

main() {
  case ${1-} in
    kit) shift; check_kit "$@" ;;
    links) shift; check_links "$@" ;;
    home) shift; check_home "$@" ;;
    dupes) shift; check_dupes "$@" ;;
    skills) shift; check_skills "$@" ;;
    privacy) shift; check_privacy "$@" ;;
    host) shift; check_host "$@" ;;
    __scan) shift; check_privacy_each "$@" ;;
    -h | --help) ao_usage; exit 0 ;;
    *) ao_die "$AO_E_USAGE" "usage: check.sh kit|links|dupes|skills|home|privacy|host ... (see --help)" ;;
  esac
}

main "$@"
