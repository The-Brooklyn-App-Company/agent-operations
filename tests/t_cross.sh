#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_cross.sh - cross-review.sh: weekly cross-family review, switch-in audit.
. "$(dirname -- "$0")/lib.sh"

# A Friday after the default weekly hour (weekly_day 5, weekly_hour 6).
friday() {
  AO_NOW=$(epoch_of "2026-11-20 09:00")
  export AO_NOW
}

both_families() {
  profile_set reviewer_claude_model strong-claude
  profile_set reviewer_codex_model strong-codex
  profile_set cross_review_per_run 10
}

calls() { _c=$(grep -c "^== $1" "$FAKE_LOG" 2>/dev/null); echo "${_c:-0}"; }

test_weekly_review_by_the_other_family() {
  both_families
  friday
  mkdir -p "$T/proj/alpha"
  printf 'Keep the web app shipping.\n' >"$T/proj/alpha/MANDATE.md"
  git -C "$T/proj/alpha" init -q && git -C "$T/proj/alpha" -c user.name=t -c user.email=t@example.com \
    commit -q --allow-empty -m "add the login page"
  FAKE_OUTPUT="P1 - login.js - no test - add one" run cross-review.sh
  assert_rc 0
  assert_eq "$(calls codex)" 3 "codex reviews of claude rows"
  assert_has "$FAKE_LOG" "arg: strong-codex"
  assert_has "$FAKE_LOG" "## Mandate"
  assert_has "$FAKE_LOG" "Keep the web app shipping."
  assert_has "$FAKE_LOG" "add the login page"
  f=$(ls "$T/home/inbox/alpha"/*-cross-weekly.md)
  assert_has "$f" "by reviewer_codex (cross)"
  assert_has "$f" "P1 - login.js"
  d=$(ls "$T/home/inbox/oracle"/*-cross-review-digest.md)
  assert_has "$d" "alpha${TAB}weekly${TAB}reviewer_codex${TAB}cross"
  # Once a week only.
  run cross-review.sh
  assert_eq "$(calls codex)" 3 "no second review this week"
  set -- "$T/home/inbox/oracle"/*-cross-review-digest.md
  assert_eq "$#" 1 "digests"
}

test_codex_rows_are_reviewed_by_claude() {
  both_families
  friday
  printf 'gamma\tGamma\t%s\tsid-g\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  FAKE_MODE=nothing run cross-review.sh --key gamma
  assert_rc 0
  assert_has "$FAKE_LOG" "== claude"
  assert_has "$FAKE_LOG" "arg: strong-claude"
  assert_no_file "$T/home/inbox/gamma"
}

test_clean_reviews_write_only_the_digest() {
  both_families
  friday
  FAKE_MODE=nothing run cross-review.sh
  assert_rc 0
  assert_no_file "$T/home/inbox/alpha"
  assert_has "$(ls "$T/home/inbox/oracle"/*-cross-review-digest.md)" "alpha${TAB}weekly${TAB}reviewer_codex${TAB}cross${TAB}clean"
}

test_not_before_the_weekly_hour() {
  both_families
  AO_NOW=$(epoch_of "2026-11-17 09:00")
  export AO_NOW
  run cross-review.sh
  assert_rc 0
  assert_no_file "$FAKE_LOG"
}

test_cap_per_run_spreads_the_week() {
  profile_set reviewer_codex_model strong-codex
  friday
  for _i in 1 2; do
    FAKE_MODE=nothing run cross-review.sh
    assert_eq "$(calls codex)" "$_i" "reviews after run $_i"
    assert_no_file "$T/home/inbox/oracle"
  done
  FAKE_MODE=nothing run cross-review.sh
  assert_eq "$(calls codex)" 3 "reviews after run 3"
  assert_file "$(ls "$T/home/inbox/oracle"/*-cross-review-digest.md)"
}

test_single_family_falls_back_and_status_warns() {
  profile_set reviewer_claude_model strong-claude
  profile_set cross_review_per_run 10
  friday
  FAKE_OUTPUT="P2 - notes - stale - prune" run cross-review.sh --key alpha
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: strong-claude"
  assert_has "$(ls "$T/home/inbox/alpha"/*-cross-weekly.md)" "(same-family)"
  run status.sh
  assert_has "$T/err" "cross-review is single-family"
}

test_switch_in_audit_by_the_incoming_family() {
  both_families
  friday
  FAKE_MODE=nothing run cross-review.sh
  sed "s/^alpha\(.*\)sid-alpha\$/alpha\1sid-alpha${TAB}codex/" "$T/home/operators/REGISTRY.tsv" >"$T/reg"
  mv "$T/reg" "$T/home/operators/REGISTRY.tsv"
  : >"$FAKE_LOG"
  FAKE_OUTPUT="P1 - branch x - abandoned - finish or drop" run cross-review.sh
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: strong-codex"
  assert_has "$FAKE_LOG" "the last 30 days"
  assert_has "$(ls "$T/home/inbox/alpha"/*-cross-switch.md)" "Cross-model switch of alpha by reviewer_codex (incoming)"
  : >"$FAKE_LOG"
  run cross-review.sh
  assert_eq "$(calls codex)$(calls claude)" 00 "no repeat audit"
}

test_failed_reviews_are_retried_then_reported() {
  both_families
  friday
  for _i in 1 2; do
    FAKE_MODE=fail run cross-review.sh --key alpha
    assert_rc 1
    assert_no_file "$T/state/cross-review/alpha.week"
  done
  FAKE_MODE=fail run cross-review.sh --key alpha
  assert_eq "$(calls codex)" 3 "attempts"
  assert_eq "$(cat "$T/state/cross-review/alpha.week")" 2026-W47 "given up for the week"
  assert_has "$T/state/cross-review/2026-W47/results.tsv" "failed (exit 7) 3 times"
}

test_switch_audit_needs_the_incoming_family() {
  profile_set reviewer_client claude
  profile_set reviewer_model generic-claude
  profile_set cross_review_per_run 10
  friday
  FAKE_MODE=nothing run cross-review.sh --key alpha
  assert_has "$T/state/cross-review/2026-W47/results.tsv" "alpha${TAB}weekly${TAB}reviewer${TAB}same-family"
  sed "s/^alpha\(.*\)sid-alpha\$/alpha\1sid-alpha${TAB}codex/" "$T/home/operators/REGISTRY.tsv" >"$T/reg"
  mv "$T/reg" "$T/home/operators/REGISTRY.tsv"
  : >"$FAKE_LOG"
  run cross-review.sh --key alpha
  assert_has "$T/state/cross-review/2026-W47/results.tsv" "alpha${TAB}switch${TAB}-${TAB}-${TAB}skipped: no reviewer role configured"
  assert_eq "$(calls claude)" 0 "no audit by the outgoing family"
}

test_off_and_dry_run() {
  both_families
  friday
  profile_set cross_review off
  run cross-review.sh
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  profile_set cross_review on
  run cross-review.sh --dry-run
  assert_rc 0
  assert_has "$T/out" "would review alpha (weekly, 7 days) with reviewer_codex (cross)"
  assert_no_file "$FAKE_LOG"
  assert_no_file "$T/state/cross-review/2026-W47"
}

ao_test_main "$0"
