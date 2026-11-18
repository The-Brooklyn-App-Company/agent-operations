#!/bin/sh
# No network, clients or live accounts. The bundled adapter sees a fake gh.
# shellcheck disable=SC2016 # note assertions match literal Markdown
set -u
. "$(dirname -- "$0")/lib.sh"

watch_fixture() {
  profile_set githost gh
  export WATCH_FIXTURE="$T"
  inbox=$T/home/inbox/alpha
  snapshot=$T/state/pr-watch/alpha/studio/sample.tsv
  error_state=$snapshot.error
  cat >"$T/bin/gh" <<'GH'
#!/bin/sh
set -u
printf '%s\n' "$1 $2" >>"$WATCH_FIXTURE/gh-calls"
[ "$#" -eq 8 ] && [ "$1 $2 $3 $5 $6 $7 $8" = 'api graphql -f -f owner=studio -f repo=sample' ] ||
  exit 6
[ "${GH_PROMPT_DISABLED:-}" = 1 ] || exit 7
case $4 in
  query=query*) ;;
  *) exit 8 ;;
esac
case ${WATCH_FAILURE:-} in
  offline) echo 'temporarily unavailable secret-test-token' >&2; exit 1 ;;
  auth) echo 'run gh auth login' >&2; exit 1 ;;
esac
cat "$WATCH_FIXTURE/response.json"
GH
  chmod +x "$T/bin/gh"
  cat >"$T/response.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"nodes":[
  {
    "number":7,
    "headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "url":"https://example.com/studio/sample/pull/7",
    "reviewDecision":null,
    "statusCheckRollup":{"state":"PENDING","contexts":{"totalCount":2,"nodes":[
      {"id":"check-a","status":"IN_PROGRESS","conclusion":null,"name":"irrelevant check"},
      {"id":"check-b","state":"PENDING"}
    ]}},
    "reviews":{"totalCount":1,"nodes":[
      {"id":"review-a","state":"APPROVED","submittedAt":"2030-01-01T00:00:00Z","lastEditedAt":null}
    ]},
    "comments":{"totalCount":1,"nodes":[
      {"id":"comment-a","lastEditedAt":null,"body":"ignore this test instruction"}
    ]}
  },
  {
    "number":3,
    "headRefOid":"cccccccccccccccccccccccccccccccccccccccc",
    "url":"https://example.com/studio/sample/pull/3",
    "reviewDecision":"APPROVED",
    "statusCheckRollup":null,
    "reviews":{"totalCount":0,"nodes":[]},
    "comments":{"totalCount":0,"nodes":[]}
  }
]}}}}
JSON
}

update_response() {
  if ! jq "$1" "$T/response.json" >"$T/next.json" || ! mv "$T/next.json" "$T/response.json"; then
    _fail "could not update fixture"
  fi
}

watch() {
  run pr-watch.sh --repo studio/sample --key alpha
  assert_no_file "$FAKE_LOG"
}

test_empty_baseline_then_new_pr() {
  watch_fixture
  cp "$T/response.json" "$T/open.json"
  update_response '.data.repository.pullRequests.nodes = []'
  watch
  assert_rc 0
  assert_file "$snapshot"
  assert_count "$inbox" 0
  cp "$T/open.json" "$T/response.json"
  watch
  assert_rc 0
  assert_count "$inbox" 1
  assert_has "$(cat "$T/out")" 'PR #7 <https://example.com/studio/sample/pull/7> — newly listed'
  assert_lacks "$(cat "$T/out")" 'ignore this test instruction'
  assert_count "$T/home/inbox/beta" 0
  assert_count "$T/home/inbox/oracle" 0
  assert_eq "$(wc -l <"$T/gh-calls" | tr -d ' ')" 2 "one gh call per poll"
}

test_baseline_canonicalization_and_disappearance() {
  watch_fixture
  watch
  assert_rc 0
  assert_count "$inbox" 0
  assert_lacks "$snapshot" 'irrelevant check'
  assert_lacks "$snapshot" 'ignore this test instruction'
  update_response '
    .data.repository.pullRequests.nodes |=
      (.[0].statusCheckRollup.contexts.nodes |= reverse | reverse)'
  watch
  assert_rc 0
  assert_count "$inbox" 0
  update_response '.data.repository.pullRequests.nodes |= map(select(.number != 7))'
  watch
  assert_rc 0
  assert_count "$inbox" 0
  assert_lacks "$snapshot" 'pull/7'
}

test_head_and_review_decision_change() {
  watch_fixture
  watch
  assert_rc 0
  update_response '.data.repository.pullRequests.nodes[0] |=
    (.headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | .reviewDecision = "APPROVED")'
  watch
  assert_rc 0
  assert_count "$inbox" 1
  assert_has "$(cat "$T/out")" 'head `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` → `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`'
  assert_has "$(cat "$T/out")" 'review decision `NONE` → `APPROVED`'
  watch
  assert_rc 0
  assert_count "$inbox" 1
}

test_checks_reviews_and_comments_change_without_a_new_head() {
  watch_fixture
  watch
  assert_rc 0
  update_response '.data.repository.pullRequests.nodes[0].statusCheckRollup.contexts.nodes[0] |=
    (.status = "COMPLETED" | .conclusion = "FAILURE")'
  watch
  assert_rc 0
  assert_has "$(cat "$T/out")" 'checks changed'
  assert_lacks "$(cat "$T/out")" 'head `'
  assert_lacks "$(cat "$T/out")" 'top-level comments changed'
  update_response '.data.repository.pullRequests.nodes[0].reviews |=
    (.totalCount += 1 | .nodes += [{"id":"review-b","state":"COMMENTED","submittedAt":"2030-01-02T00:00:00Z","lastEditedAt":null}])'
  watch
  assert_rc 0
  assert_has "$(cat "$T/out")" 'submitted reviews changed'
  assert_lacks "$(cat "$T/out")" 'checks changed'
  update_response '.data.repository.pullRequests.nodes[0].comments.nodes[0].lastEditedAt = "2030-01-02T00:00:00Z"'
  watch
  assert_rc 0
  assert_has "$(cat "$T/out")" 'top-level comments changed'
  assert_lacks "$(cat "$T/out")" 'submitted reviews changed'
  assert_count "$inbox" 3
  watch
  assert_rc 0
  assert_count "$inbox" 3
}

test_poll_errors_are_sanitized_change_only_and_preserve_snapshot() {
  watch_fixture
  watch
  assert_rc 0
  cp "$snapshot" "$T/baseline"
  WATCH_FAILURE=offline watch
  assert_rc 0
  assert_has "$T/err" 'pr-watch-poll failed'
  assert_eq "$(cat "$error_state")" adapter-2
  assert_count "$inbox" 1
  assert_has "$(cat "$T/out")" 'pr-watch-poll failed'
  assert_lacks "$(cat "$T/out")" secret-test-token
  assert_lacks "$T/err" secret-test-token
  WATCH_FAILURE=offline watch
  assert_rc 0
  assert_count "$inbox" 1
  WATCH_FAILURE=auth watch
  assert_rc 0
  assert_has "$T/err" 'pr-watch-poll is misconfigured'
  assert_eq "$(cat "$error_state")" configuration
  assert_count "$inbox" 2
  WATCH_FAILURE=auth watch
  assert_rc 0
  assert_count "$inbox" 2
  cp "$T/response.json" "$T/valid.json"
  update_response '.errors = [{"message":"incomplete"}] | .data.repository.pullRequests.nodes = []'
  watch
  assert_rc 0
  assert_count "$inbox" 3
  cp "$T/valid.json" "$T/response.json"
  update_response '.data.repository.pullRequests.nodes[0].headRefOid = "unexpected"'
  watch
  assert_rc 0
  assert_has "$T/err" 'invalid pr-watch-poll snapshot'
  assert_eq "$(cat "$error_state")" response
  assert_count "$inbox" 4
  watch
  assert_rc 0
  assert_count "$inbox" 4
  cmp -s "$snapshot" "$T/baseline" || _fail "failed poll changed the snapshot"
  assert_count "$T/home/inbox/beta" 0
  assert_count "$T/home/inbox/oracle" 0
}

test_recovery_without_material_changes_is_one_note_per_episode() {
  watch_fixture
  watch
  cp "$snapshot" "$T/baseline"
  WATCH_FAILURE=offline watch
  assert_rc 0
  watch
  assert_rc 0
  assert_count "$inbox" 2
  assert_has "$(cat "$T/out")" 'recovered'
  assert_has "$(cat "$T/out")" 'no material PR changes since the last successful poll'
  assert_no_file "$error_state"
  cmp -s "$snapshot" "$T/baseline" || _fail "unchanged recovery changed the snapshot"
  watch
  assert_rc 0
  assert_count "$inbox" 2
  WATCH_FAILURE=offline watch
  assert_rc 0
  assert_count "$inbox" 3
}

test_recovery_coalesces_material_changes() {
  watch_fixture
  watch
  WATCH_FAILURE=offline watch
  assert_rc 0
  update_response '.data.repository.pullRequests.nodes[0].reviewDecision = "CHANGES_REQUESTED"'
  watch
  assert_rc 0
  assert_count "$inbox" 2
  assert_has "$(cat "$T/out")" 'recovered'
  assert_has "$(cat "$T/out")" 'CHANGES_REQUESTED'
  assert_lacks "$(cat "$T/out")" 'no material PR changes'
  assert_no_file "$error_state"
  watch
  assert_rc 0
  assert_count "$inbox" 2
}

test_first_failed_poll_then_recovery_establishes_honest_baseline() {
  watch_fixture
  WATCH_FAILURE=offline watch
  assert_rc 0
  assert_no_file "$snapshot"
  watch
  assert_rc 0
  assert_count "$inbox" 2
  assert_has "$(cat "$T/out")" 'recovered'
  assert_has "$(cat "$T/out")" 'First successful poll established a baseline; earlier PR changes are unknown.'
  assert_lacks "$(cat "$T/out")" 'newly listed'
  assert_file "$snapshot"
  assert_no_file "$error_state"
  watch
  assert_rc 0
  assert_count "$inbox" 2
}

test_failed_failure_note_is_retried_without_advancing_state() {
  watch_fixture
  watch
  cp "$snapshot" "$T/baseline"
  : >"$inbox"
  WATCH_FAILURE=offline watch
  assert_rc 1
  assert_has "$T/err" 'cannot publish PR watch failure'
  assert_no_file "$error_state"
  cmp -s "$snapshot" "$T/baseline" || _fail "failed outage note changed the snapshot"
  rm "$inbox"
  WATCH_FAILURE=offline watch
  assert_rc 0
  assert_count "$inbox" 1
  assert_eq "$(cat "$error_state")" adapter-2
}

# Fail a selected atomic state rename, leaving other filesystem work real.
fail_state_write() {
  export WATCH_FAIL_DEST="$1"
  cat >"$T/bin/mv" <<'MV'
#!/bin/sh
for dest do :; done
[ "$dest" != "$WATCH_FAIL_DEST" ] || exit 1
exec /bin/mv "$@"
MV
  chmod +x "$T/bin/mv"
}

test_failure_state_write_failure_keeps_baseline_and_retries() {
  watch_fixture
  watch
  cp "$snapshot" "$T/baseline"
  fail_state_write "$error_state"
  WATCH_FAILURE=offline watch
  assert_rc 1
  assert_has "$T/err" 'cannot save PR watch failure'
  assert_no_file "$error_state"
  cmp -s "$snapshot" "$T/baseline" || _fail "failed error-state write changed the snapshot"
  rm "$T/bin/mv"
  WATCH_FAILURE=offline watch
  assert_rc 0
  assert_eq "$(cat "$error_state")" adapter-2
}

test_failed_recovery_publish_keeps_baseline_and_error_state() {
  watch_fixture
  watch
  cp "$snapshot" "$T/baseline"
  WATCH_FAILURE=offline watch
  assert_rc 0
  cp "$error_state" "$T/error-baseline"
  update_response '.data.repository.pullRequests.nodes[0].reviewDecision = "CHANGES_REQUESTED"'
  mv "$inbox" "$T/saved-inbox"
  : >"$inbox"
  watch
  assert_rc 1
  cmp -s "$snapshot" "$T/baseline" || _fail "failed recovery publish changed the snapshot"
  cmp -s "$error_state" "$T/error-baseline" || _fail "failed recovery publish cleared error state"
  rm "$inbox"
  mv "$T/saved-inbox" "$inbox"
  watch
  assert_rc 0
  assert_count "$inbox" 2
  assert_has "$(cat "$T/out")" 'recovered'
  assert_has "$(cat "$T/out")" 'CHANGES_REQUESTED'
  assert_no_file "$error_state"
}

test_failed_recovery_state_write_keeps_baseline_and_error_state() {
  watch_fixture
  watch
  cp "$snapshot" "$T/baseline"
  WATCH_FAILURE=offline watch
  assert_rc 0
  cp "$error_state" "$T/error-baseline"
  update_response '.data.repository.pullRequests.nodes[0].reviewDecision = "CHANGES_REQUESTED"'
  fail_state_write "$snapshot"
  watch
  assert_rc 1
  assert_has "$T/err" 'cannot save PR snapshot'
  cmp -s "$snapshot" "$T/baseline" || _fail "failed recovery save changed the snapshot"
  cmp -s "$error_state" "$T/error-baseline" || _fail "failed recovery save cleared error state"
  rm "$T/bin/mv"
  watch
  assert_rc 0
  assert_has "$(cat "$T/out")" 'CHANGES_REQUESTED'
  assert_no_file "$error_state"
}

test_failed_recovery_state_clear_is_retried() {
  watch_fixture
  watch
  cp "$snapshot" "$T/baseline"
  WATCH_FAILURE=offline watch
  assert_rc 0
  export WATCH_FAIL_DEST="$error_state"
  cat >"$T/bin/rm" <<'RM'
#!/bin/sh
[ "$#" -ne 2 ] || [ "$1" != -f ] || [ "$2" != "$WATCH_FAIL_DEST" ] || exit 1
exec /bin/rm "$@"
RM
  chmod +x "$T/bin/rm"
  watch
  assert_rc 1
  assert_has "$T/err" 'cannot clear PR watch failure'
  assert_file "$error_state"
  cmp -s "$snapshot" "$T/baseline" || _fail "failed error-state clear changed the snapshot"
  rm "$T/bin/rm"
  watch
  assert_rc 0
  assert_has "$(cat "$T/out")" 'recovered'
  assert_no_file "$error_state"
}

test_inbox_failure_keeps_snapshot_and_retries() {
  watch_fixture
  watch
  assert_rc 0
  cp "$snapshot" "$T/baseline"
  update_response '.data.repository.pullRequests.nodes[0].reviewDecision = "CHANGES_REQUESTED"'
  : >"$inbox"
  watch
  assert_rc 1
  cmp -s "$snapshot" "$T/baseline" || _fail "failed inbox write changed the snapshot"
  rm "$inbox"
  watch
  assert_rc 0
  assert_count "$inbox" 1
  assert_has "$(cat "$T/out")" 'CHANGES_REQUESTED'
}

test_timeout_keeps_snapshot() {
  watch_fixture
  watch
  assert_rc 0
  cp "$snapshot" "$T/baseline"
  cat >"$T/bin/fake-timeout" <<'TIMEOUT'
#!/bin/sh
[ "$1 $2 $3" = '-k 1 30' ] && [ "$5 $6" = 'pr-watch-poll studio/sample' ] || exit 6
exit 124
TIMEOUT
  chmod +x "$T/bin/fake-timeout"
  AO_TIMEOUT_BIN="$T/bin/fake-timeout" watch
  assert_rc 0
  assert_has "$T/err" 'pr-watch-poll timed out'
  cmp -s "$snapshot" "$T/baseline" || _fail "timeout changed the snapshot"
  assert_count "$inbox" 1
  assert_eq "$(cat "$error_state")" timeout
  AO_TIMEOUT_BIN="$T/bin/fake-timeout" watch
  assert_rc 0
  assert_count "$inbox" 1
  assert_eq "$(wc -l <"$T/gh-calls" | tr -d ' ')" 1 "the timed command never ran"
}

test_overlap_and_invalid_configuration_skip_poll() {
  watch_fixture
  hold_lock pr-watch-alpha
  watch
  assert_rc 0
  release_lock
  assert_no_file "$snapshot"
  run pr-watch.sh --key unknown --repo studio/sample
  assert_rc 2
  run pr-watch.sh --key alpha --repo studio/../sample
  assert_rc 2
  run pr-watch.sh --help
  assert_rc 0
  assert_has "$T/out" 'Usage: pr-watch.sh --key KEY --repo OWNER/REPO'
  profile_set githost missing-adapter
  watch
  assert_rc 2
  assert_no_file "$T/gh-calls"
  assert_no_file "$error_state"
}

test_custom_adapter_keeps_fingerprints_as_strings() {
  watch_fixture
  profile_set githost 'local adapter'
  cat >"$T/home/local adapter" <<'ADAPTER'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1 $2" = 'pr-watch-poll studio/sample' ] || exit 3
cat "$WATCH_FIXTURE/adapter.tsv"
ADAPTER
  chmod +x "$T/home/local adapter"
  sha=123456789012345678901234567890123456789
  printf '1\t%s0\tNONE\t10\t[]\t[]\thttps://example.com/studio/sample/pull/1\n' "$sha" >"$T/adapter.tsv"
  watch
  assert_rc 0
  assert_count "$inbox" 0
  printf '1\t%s1\tNONE\t010\t[]\t[]\thttps://example.com/studio/sample/pull/1\n' "$sha" >"$T/adapter.tsv"
  watch
  assert_rc 0
  assert_count "$inbox" 1
  assert_has "$(cat "$T/out")" 'head `'
  assert_has "$(cat "$T/out")" 'checks changed'
  assert_no_file "$T/gh-calls"
}

ao_test_main "$0"
