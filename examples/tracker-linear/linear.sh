#!/bin/sh
# linear.sh - tracker adapter sketch for Linear (UNTESTED; see README.md).
#
# Usage: linear.sh poll
#        linear.sh link ISSUE_ID URL
#
# Profile keys (read from AO_PROFILE): x_linear_team (team key) and
# x_linear_secret (secret name for the API key, fetched through the
# profile's secrets slot by the kit's core library).
#
# Exit codes: 0 success; 2 unavailable; 3 misconfigured.
set -u
KIT=${AO_SCRIPTS:?run from a tick hook, or set AO_SCRIPTS to the kit scripts dir}
# shellcheck source=../../scripts/lib/core.sh
. "$KIT/lib/core.sh"
ao_load
for t in curl jq; do command -v "$t" >/dev/null 2>&1 || { echo "linear.sh: needs $t" >&2; exit 3; }; done
team=$(ao_cfg x_linear_team '') secret=$(ao_cfg x_linear_secret '')
[ -n "$team" ] && [ -n "$secret" ] || { echo "linear.sh: set x_linear_team and x_linear_secret" >&2; exit 3; }
key=$(ao_secret "$secret") && [ -n "$key" ] || { echo "linear.sh: secret not readable" >&2; exit 3; }
cursor=$AO_STATE/linear-$team.cursor

# gql QUERY_JSON  POST one GraphQL request. The key reaches curl as a
# header on its stdin: never on the command line, never in a file.
gql() {
  printf 'Authorization: %s\n' "$key" |
    curl -sS --max-time 25 -H @- -H 'Content-Type: application/json' \
      --data "$1" https://api.linear.app/graphql || exit 2
}

case ${1-} in
  poll)
    since=$(cat "$cursor" 2>/dev/null) || since=1970-01-01T00:00:00Z
    rows=$(ao_tmp rows) after=null
    # Every page first; the cursor moves only after all of them arrived.
    while :; do
      q=$(jq -cn --arg team "$team" --arg since "$since" --argjson after "$after" '{query:
        "query($team: String!, $since: DateTimeOrDuration!, $after: String) { issues(first: 50, after: $after, orderBy: updatedAt, filter: { team: { key: { eq: $team } }, updatedAt: { gt: $since } }) { nodes { identifier state { name } updatedAt title } pageInfo { hasNextPage endCursor } } }",
        variables: {team: $team, since: $since, after: $after}}')
      res=$(gql "$q") || exit 2
      printf '%s\n' "$res" | jq -e '.data.issues' >/dev/null 2>&1 || { echo "linear.sh: unexpected response" >&2; exit 2; }
      printf '%s\n' "$res" | jq -r '.data.issues.nodes[] | [.identifier, .state.name, .updatedAt, .title] | @tsv' >>"$rows"
      [ "$(printf '%s\n' "$res" | jq -r '.data.issues.pageInfo.hasNextPage')" = true ] || break
      after=$(printf '%s\n' "$res" | jq -c '.data.issues.pageInfo.endCursor')
    done
    cat "$rows"
    new=$(cut -f 3 "$rows" | sort | tail -n 1)
    [ -z "$new" ] || printf '%s\n' "$new" | ao_write_atomic "$cursor" ;;
  link)
    [ $# -ge 3 ] || { echo "usage: linear.sh link ISSUE_ID URL" >&2; exit 3; }
    q=$(jq -cn --arg id "$2" --arg url "$3" '{query:
      "mutation($id: String!, $url: String!) { attachmentLinkURL(issueId: $id, url: $url) { success } }",
      variables: {id: $id, url: $url}}')
    gql "$q" | jq -e '.data.attachmentLinkURL.success == true' >/dev/null || exit 2 ;;
  *) echo "linear.sh: unknown verb '${1-}'" >&2; exit 3 ;;
esac
