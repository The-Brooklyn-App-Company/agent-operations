#!/bin/sh
# git-gh.sh - git host and CI adapter for GitHub through the `gh` CLI
# (see CONTRACT.md). Uses gh's own sign-in; never handles a token.
#
# Usage: git-gh.sh pr-poll [REPO]
#        git-gh.sh review-request NUMBER REVIEWER [REPO]
#        git-gh.sh status SHA [REPO]
#
# REPO is OWNER/NAME; default: the repository of the current directory.
#
# pr-poll         open pull requests: number, head sha, state, review
#                 decision, url (TSV)
# review-request  ask REVIEWER to review pull request NUMBER
# status          combined check state of SHA: sha, state, url (TSV)
#
# Exit codes: 0 success; 2 unavailable (network, rate limit); 3
# misconfigured (no gh or jq, not signed in, unknown verb).
set -u
command -v gh >/dev/null 2>&1 || { echo "git-gh.sh: gh not found" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "git-gh.sh: jq not found" >&2; exit 3; }

# gh_run ARG...  Run gh with stdin closed; map its failures to 2 or 3.
gh_run() {
  errf=$(mktemp "${TMPDIR:-/tmp}/git-gh.XXXXXX") || exit 3
  if ! out=$(gh "$@" </dev/null 2>"$errf"); then
    err=$(head -n 1 "$errf")
    rm -f "$errf"
    case $err in
      *"auth login"* | *"not logged"* | *"Could not resolve to a Repository"*) echo "git-gh.sh: $err" >&2; exit 3 ;;
      *) echo "git-gh.sh: $err" >&2; exit 2 ;;
    esac
  fi
  rm -f "$errf"
  printf '%s\n' "$out"
}

repo_args() { [ -z "${1-}" ] || printf -- '--repo\n%s\n' "$1"; }

case ${1-} in
  pr-poll)
    # shellcheck disable=SC2046 # repo_args prints at most two safe words
    json=$(gh_run pr list --state open $(repo_args "${2-}") \
      --json number,headRefOid,state,reviewDecision,url) || exit
    printf '%s\n' "$json" |
      jq -r '.[] | [.number, .headRefOid, .state, (.reviewDecision // "NONE"), .url] | @tsv' ;;
  review-request)
    [ $# -ge 3 ] || { echo "usage: git-gh.sh review-request NUMBER REVIEWER [REPO]" >&2; exit 3; }
    # shellcheck disable=SC2046
    gh_run pr edit "$2" --add-reviewer "$3" $(repo_args "${4-}") >/dev/null ;;
  status)
    [ $# -ge 2 ] || { echo "usage: git-gh.sh status SHA [REPO]" >&2; exit 3; }
    case $2 in *[!0-9a-f]*) echo "git-gh.sh: not a commit sha: $2" >&2; exit 3 ;; esac
    repo=${3-}
    [ -n "$repo" ] || repo=$(gh_run repo view --json nameWithOwner -q .nameWithOwner) || exit
    json=$(gh_run api "repos/$repo/commits/$2/status") || exit
    printf '%s\n' "$json" |
      jq -r --arg sha "$2" '[$sha, .state, (.statuses[0].target_url // "")] | @tsv' ;;
  -h | --help) sed -n '2,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "$0" ;;
  *) echo "git-gh.sh: unknown verb '${1-}'" >&2; exit 3 ;;
esac
