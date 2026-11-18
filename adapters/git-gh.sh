#!/bin/sh
# git-gh.sh - git host and CI adapter for GitHub through the `gh` CLI
# (see CONTRACT.md). Uses gh's own sign-in; never handles a token.
#
# Usage: git-gh.sh pr-poll [REPO]
#        git-gh.sh pr-watch-poll REPO
#        git-gh.sh review-request NUMBER REVIEWER [REPO]
#        git-gh.sh status SHA [REPO]
#
# REPO is OWNER/NAME; default: the repository of the current directory.
#
# pr-poll         open pull requests: number, head sha, state, review
#                 decision, url (TSV)
# pr-watch-poll   up to 100 recently updated open PRs: number, head sha,
#                 review decision, check/review/comment fingerprints, url
#                 (TSV; see pr-watch.sh for snapshot coverage)
# review-request  ask REVIEWER to review pull request NUMBER
# status          combined state of SHA over commit statuses and check runs
#                 (GitHub Actions): sha, state, url (TSV); state is failure
#                 if any failed, pending if any is unfinished, success if
#                 all passed, pending if there are none
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

# Request metadata in one read-only query. The generic gh pr list fields
# also fetch review and comment bodies and omit comment edit timestamps.
pr_watch_poll() {
  # shellcheck disable=SC2016 # GraphQL variables are part of the query
  query='query($owner: String!, $repo: String!) {
    repository(owner: $owner, name: $repo) {
      pullRequests(states: [OPEN], first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes {
          number headRefOid reviewDecision url
          comments(last: 20) { totalCount nodes { id lastEditedAt } }
          reviews(last: 20, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
            totalCount nodes { id state submittedAt lastEditedAt }
          }
          statusCheckRollup {
            state
            contexts(first: 100) {
              totalCount
              nodes {
                ... on CheckRun { id status conclusion startedAt completedAt }
                ... on StatusContext { id state }
              }
            }
          }
        }
      }
    }
  }'
  json=$(gh_run api graphql -f "query=$query" -f "owner=${1%/*}" -f "repo=${1#*/}") || return
  printf '%s\n' "$json" | jq -r '
    def collection(f):
      if (.nodes | type) == "array" and (.totalCount | type) == "number"
      then [.totalCount, (.nodes | map(f) | sort)]
      else error("incomplete PR metadata connection") end;
    if ((.errors // []) | length) != 0 then error("partial PR response") else
      .data.repository.pullRequests.nodes
    end
    | if type != "array" then error("missing PR list") else .[] end
    | if has("statusCheckRollup") and has("reviewDecision") then . else
        error("incomplete PR metadata")
      end
    | [
        .number, .headRefOid, (.reviewDecision // "NONE"),
        (.statusCheckRollup | if . == null then [] else
          [.state, (.contexts | collection([.id, .state, .status, .conclusion, .startedAt, .completedAt]))]
        end | tojson),
        (.reviews | collection([.id, .state, .submittedAt, .lastEditedAt]) | tojson),
        (.comments | collection([.id, .lastEditedAt]) | tojson),
        .url
      ] | @tsv'
}

case ${1-} in
  pr-poll)
    # shellcheck disable=SC2046 # repo_args prints at most two safe words
    json=$(gh_run pr list --state open $(repo_args "${2-}") \
      --json number,headRefOid,state,reviewDecision,url) || exit
    printf '%s\n' "$json" |
      jq -r '.[] | [.number, .headRefOid, .state, (.reviewDecision // "NONE"), .url] | @tsv' ;;
  pr-watch-poll)
    [ $# -eq 2 ] || { echo "usage: git-gh.sh pr-watch-poll OWNER/REPO" >&2; exit 3; }
    case $2 in
      -* | */-* | .* | */.* | */*/* | */ | /* | *[!A-Za-z0-9_./-]*)
        echo "git-gh.sh: expected repository in OWNER/REPO form" >&2; exit 3 ;;
      */*) pr_watch_poll "$2" ;;
      *) echo "git-gh.sh: expected repository in OWNER/REPO form" >&2; exit 3 ;;
    esac ;;
  review-request)
    [ $# -ge 3 ] || { echo "usage: git-gh.sh review-request NUMBER REVIEWER [REPO]" >&2; exit 3; }
    # shellcheck disable=SC2046
    gh_run pr edit "$2" --add-reviewer "$3" $(repo_args "${4-}") >/dev/null ;;
  status)
    [ $# -ge 2 ] || { echo "usage: git-gh.sh status SHA [REPO]" >&2; exit 3; }
    case $2 in *[!0-9a-f]*) echo "git-gh.sh: not a commit sha: $2" >&2; exit 3 ;; esac
    repo=${3-}
    [ -n "$repo" ] || repo=$(gh_run repo view --json nameWithOwner -q .nameWithOwner) || exit
    # The combined status already folds every commit status into .state;
    # check runs come in pages, all of them read.
    st=$(gh_run api "repos/$repo/commits/$2/status") || exit
    cr=$(gh_run api --paginate "repos/$repo/commits/$2/check-runs?per_page=100") || exit
    printf '%s\n%s\n' "$st" "$cr" | jq -rs --arg sha "$2" '
      .[0] as $st | (.[0].statuses // []) as $s | [.[1:][] | .check_runs[]?] as $c
      | ((if ($st.total_count // ($s | length)) > 0 then
            [$st.state | if . == "success" then "success" elif . == "pending" then "pending" else "failure" end]
          else [] end)
         + [$c[] | if .status != "completed" then "pending"
                   elif (.conclusion | IN("success", "neutral", "skipped")) then "success"
                   else "failure" end]) as $all
      | (if ($all | index("failure")) then "failure"
         elif ($all | length) == 0 or ($all | index("pending")) then "pending"
         else "success" end) as $state
      | ([$s[].target_url, $c[].html_url] | map(select(. != null and . != "")) | first) as $url
      | [$sha, $state, ($url // "")] | @tsv' ;;
  -h | --help) sed -n '2,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "$0" ;;
  *) echo "git-gh.sh: unknown verb '${1-}'" >&2; exit 3 ;;
esac
