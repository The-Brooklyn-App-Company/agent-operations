#!/bin/sh
# pr-watch.sh - poll one repository and write a change-only inbox note.
#
# Usage: pr-watch.sh --key KEY --repo OWNER/REPO
#
# Run from a tick hook. Set githost=gh in AO_PROFILE to use the bundled
# GitHub adapter, or set githost to an executable adapter path (relative
# to the Oracle home or absolute) that implements pr-watch-poll REPO.
# The adapter runs once with a 30-second timeout.
#
# The first successful poll establishes a baseline, even if empty. It is
# silent unless recovering from a failed poll.
# Later polls report newly listed PRs and changes to heads, review
# decisions, checks, submitted reviews and top-level comments. The bundled
# adapter covers up to 100 recently updated open PRs, with up to 100 check
# contexts and the last 20 submitted reviews and 20 top-level comments
# per PR. Coverage excludes inline review threads, PRs leaving the list
# and changes that occur entirely between polls.
#
# Each changed poll writes one note to KEY for delivery by the relay.
# State lives under <state_dir>/pr-watch/KEY/OWNER/. Poll failures preserve
# the last good REPO.tsv, record the latest failure class in REPO.tsv.error
# and write one note per new failure signature. A valid poll writes a
# recovery note that includes any PR changes. An interruption between
# publishing a note and saving state can cause a repeated note.
#
# Exit codes are 0 for success, a recorded outage or an overlapping run,
# 1 for a state or inbox failure, and 2 for usage or configuration preflight.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"

# Validate before touching the previous snapshot. Normalize review values
# with no decision, and keep provider-controlled text out of the notes.
watch_snapshot() {
  awk -F '\t' '
    {
      if (NR > 100 || NF != 7 || $1 !~ /^[1-9][0-9]*$/ || length($1) > 12 || seen[$1]++ ||
          $2 !~ /^[0-9a-fA-F]+$/ || (length($2) != 40 && length($2) != 64) ||
          $3 !~ /^[A-Za-z0-9_-]+$/ || length($3) > 40 ||
          $7 !~ /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]+)?\/[A-Za-z0-9._~\/%+-]+$/ ||
          length($7) > 512) exit 1
      for (i = 4; i <= 6; i++) {
        if ($i !~ /^[[:print:]]+$/ || length($i) > 32768) exit 1
      }
      print $1, tolower($2), toupper($3), $4, $5, $6, $7
    }
  ' OFS="$AO_TAB" "$1" >"$AO_TMPDIR/validated" || return 1
  sort -t "$AO_TAB" -k1,1n "$AO_TMPDIR/validated"
}

# Use FILENAME rather than NR == FNR so an empty baseline works too.
watch_changes() {
  awk -F '\t' '
    function add(text) { change = change (change == "" ? "" : "; ") text }
    BEGIN { field[4] = "checks"; field[5] = "submitted reviews"; field[6] = "top-level comments" }
    FILENAME == ARGV[1] {
      head[$1] = $2
      review[$1] = $3
      for (i = 4; i <= 6; i++) previous[$1, i] = $i
      next
    }
    {
      change = ""
      if (!($1 in head)) {
        change = "newly listed (head `" $2 "`, review `" $3 "`)"
      } else {
        if ("s" head[$1] != "s" $2) add("head `" head[$1] "` → `" $2 "`")
        if ("s" review[$1] != "s" $3) add("review decision `" review[$1] "` → `" $3 "`")
        for (i = 4; i <= 6; i++) {
          if ("s" previous[$1, i] != "s" $i) add(field[i] " changed")
        }
      }
      if (change != "") printf "- PR #%s <%s> — %s\n", $1, $7, change
    }
  ' "$1" "$2"
}

watch_problem() {
  ao_msg "$2"
  if [ "$previous_error" != "$1" ]; then
    {
      # shellcheck disable=SC2016 # literal Markdown backticks
      printf '# Pull request watch for `%s` failed\n\n' "$repo"
      printf '%s\n' "$2"
    } | "$AO_SCRIPTS/inbox-put.sh" "$key" pr-watch-failed 9>&- ||
      ao_die "$AO_E_FAIL" "cannot publish PR watch failure for $repo"
    printf '%s\n' "$1" | ao_write_atomic "$error_state" ||
      ao_die "$AO_E_FAIL" "cannot save PR watch failure for $repo"
  fi
}

main() {
  key='' repo=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      -h | --help) ao_usage; exit 0 ;;
      --key) [ "$#" -ge 2 ] || ao_die "$AO_E_USAGE" "--key needs a value"; key=$2; shift ;;
      --repo) [ "$#" -ge 2 ] || ao_die "$AO_E_USAGE" "--repo needs a value"; repo=$2; shift ;;
      *) ao_die "$AO_E_USAGE" "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  ao_is_name "$key" || ao_die "$AO_E_USAGE" "expected a registry key (see --help)"
  case $repo in
    -* | */-* | .* | */.* | */*/* | */ | /* | *[!A-Za-z0-9_./-]*)
      ao_die "$AO_E_USAGE" "expected repository in OWNER/REPO form" ;;
    */*) ;;
    *) ao_die "$AO_E_USAGE" "expected repository in OWNER/REPO form" ;;
  esac

  ao_load
  ao_registry_has "$key" || ao_die "$AO_E_USAGE" "'$key' is not in the registry ($AO_REGISTRY)"
  adapter=$(ao_cfg githost none)
  case $adapter in
    none) ao_die "$AO_E_USAGE" "configure githost=gh or an executable adapter path in AO_PROFILE" ;;
    gh) adapter=$AO_SCRIPTS/../adapters/git-gh.sh ;;
    *) adapter=$(ao_expand_path "$adapter") ;;
  esac
  [ -f "$adapter" ] && [ -x "$adapter" ] ||
    ao_die "$AO_E_USAGE" "git-host adapter is not executable: $adapter"

  ao_lock "pr-watch-$key" || {
    status=$?
    [ "$status" -ne "$AO_E_BUSY" ] || exit 0
    ao_die "$status" "cannot lock PR watch for '$key'"
  }
  snapshot=$AO_STATE/pr-watch/$key/$repo.tsv
  error_state=$snapshot.error
  previous_error=''
  if [ -e "$error_state" ]; then
    [ -f "$error_state" ] && IFS= read -r previous_error <"$error_state" && [ -n "$previous_error" ] ||
      ao_die "$AO_E_FAIL" "cannot read PR watch failure state for $repo"
  fi
  if [ -e "$snapshot" ]; then
    [ -f "$snapshot" ] && [ -r "$snapshot" ] || ao_die "$AO_E_FAIL" "cannot read PR snapshot for $repo"
  fi
  next=$AO_TMPDIR/next
  changes=$AO_TMPDIR/changes
  : >"$changes" || ao_die "$AO_E_FAIL" "cannot create PR changes file"
  GH_PROMPT_DISABLED=1 ao_timeout 30 "$adapter" pr-watch-poll "$repo" >"$AO_TMPDIR/raw" 2>/dev/null || {
    status=$?
    case $status in
      "$AO_E_TIMEOUT") watch_problem timeout "pr-watch-poll timed out for $repo" ;;
      3) watch_problem configuration "pr-watch-poll is misconfigured for $repo (adapter exit $status)" ;;
      *) watch_problem "adapter-$status" "pr-watch-poll failed for $repo (adapter exit $status)" ;;
    esac
    return 0
  }
  if ! watch_snapshot "$AO_TMPDIR/raw" >"$next"; then
    watch_problem response "invalid pr-watch-poll snapshot for $repo"
    return 0
  fi
  snapshot_changed=1
  had_baseline=''
  if [ -e "$snapshot" ]; then
    had_baseline=1
    if cmp -s "$snapshot" "$next"; then
      snapshot_changed=''
    else
      watch_changes "$snapshot" "$next" >"$changes" || ao_die "$AO_E_FAIL" "cannot compare PR snapshots for $repo"
    fi
  fi
  if [ -n "$previous_error" ] || [ -s "$changes" ]; then
    {
      # shellcheck disable=SC2016 # literal Markdown backticks
      if [ -n "$previous_error" ]; then
        printf '# Pull request watch for `%s` recovered\n\n' "$repo"
        if [ -z "$had_baseline" ]; then
          printf 'First successful poll established a baseline; earlier PR changes are unknown.\n'
        elif [ ! -s "$changes" ]; then
          printf 'Polling resumed; no material PR changes since the last successful poll.\n'
        fi
      else
        printf '# Pull request changes for `%s`\n\n' "$repo"
      fi
      [ ! -s "$changes" ] || cat "$changes"
    } | "$AO_SCRIPTS/inbox-put.sh" "$key" pr-watch 9>&- ||
      ao_die "$AO_E_FAIL" "cannot publish PR changes for $repo"
  fi
  if [ -n "$snapshot_changed" ]; then
    ao_write_atomic "$snapshot" <"$next" || ao_die "$AO_E_FAIL" "cannot save PR snapshot for $repo"
  fi
  if [ -n "$previous_error" ]; then
    rm -f "$error_state" || ao_die "$AO_E_FAIL" "cannot clear PR watch failure for $repo"
  fi
}

main "$@"
