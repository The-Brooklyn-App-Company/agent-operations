#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_cross.sh - cross-review.sh: weekly cross-family review, switch-in audit
# (one mechanism with lease.sh audit-done).
. "$(dirname -- "$0")/lib.sh"
. "$(dirname -- "$0")/lease_lib.sh"

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

# set_client KEY CLIENT  Set (or add) the registry client column of KEY.
set_client() {
  awk -F'\t' -v k="$1" -v c="$2" 'BEGIN { OFS = "\t" } $1 == k { $5 = c } { print }' \
    "$T/home/operators/REGISTRY.tsv" >"$T/reg" && mv "$T/reg" "$T/home/operators/REGISTRY.tsv"
}

# audit_of KEY  The AUDIT column status.sh prints for KEY.
audit_of() {
  run status.sh --tsv
  awk -F'\t' -v k="$1" '$1 == k { print $7 }' "$T/out"
}

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
  assert_eq "$(audit_of alpha)" - "no change seen yet"
  set_client alpha codex
  # status.sh sees the change before cross-review.sh records it.
  assert_eq "$(audit_of alpha)" pending "seen by status.sh"
  : >"$FAKE_LOG"
  FAKE_OUTPUT="P1 - branch x - abandoned - finish or drop" run cross-review.sh
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: strong-codex"
  assert_has "$FAKE_LOG" "the last 30 days"
  assert_has "$FAKE_LOG" "switch: claude -> codex"
  assert_has "$T/state/audit/alpha" "from=claude"
  assert_has "$T/state/audit/alpha" "to=codex"
  r=$(ls "$T/proj/alpha/audits"/switch-in-registry-*.md)
  assert_eq "$(sed -n 1p "$r")" "# Switch-in audit: alpha, registry change 1 at $(sed -n 's/^since=//p' "$T/state/audit/alpha") (claude -> codex)"
  assert_has "$r" "P1 - branch x - abandoned"
  assert_has "$r" "## Triage"
  assert_eq "$(grep -B 1 '^## Triage' "$r" | head -n 1)" "" "blank line before Triage"
  n=$(ls "$T/home/inbox/alpha"/*-cross-switch.md)
  assert_has "$n" "Cross-model switch-in audit of alpha (claude -> codex) by reviewer_codex (incoming)"
  assert_has "$n" "audit-done --report audits/switch-in-registry-"
  assert_eq "$(audit_of alpha)" pending "pending until audit-done"
  : >"$FAKE_LOG"
  run cross-review.sh
  assert_eq "$(calls codex)$(calls claude)" 00 "no repeat audit"
}

test_registry_switch_is_cleared_by_audit_done() {
  lsetup
  both_families
  friday
  FAKE_MODE=nothing run cross-review.sh --key ws
  set_client ws codex
  FAKE_MODE=nothing run cross-review.sh --key ws
  assert_rc 0
  r=$(cd "$T/ops/ws" && ls audits/switch-in-registry-*.md)
  assert_has "$T/ops/ws/$r" "NOTHING: the reviewer found nothing"
  assert_has "$T/home/inbox/ws/"*-cross-switch.md "0 finding line(s)"
  assert_eq "$(audit_of ws)" pending
  lease audit-brief
  assert_rc 0
  assert_has "$T/out" "registry change 1 at"
  assert_has "$T/out" "headless report: $r"
  lease audit-done --report "$r"
  assert_rc 5
  assert_has "$T/err" "commit the report first"
  # The report of another change does not count.
  sed '1s/(claude -> codex)/(codex -> claude)/' "$T/ops/ws/$r" >"$T/ops/ws/audits/other.md"
  git -C "$T/ops/ws" add audits && git -C "$T/ops/ws" commit -q -m "switch-in audit"
  lease audit-done --report audits/other.md
  assert_rc 5
  assert_has "$T/err" "the report must start with: # Switch-in audit: ws, registry change 1 at"
  # Its own report does not count while the headless one exists.
  { sed -n 1p "$T/ops/ws/$r"; echo 'my own audit'; } >"$T/ops/ws/audits/mine.md"
  git -C "$T/ops/ws" add audits && git -C "$T/ops/ws" commit -q -m "own report"
  lease audit-done --report audits/mine.md
  assert_rc 5
  assert_has "$T/err" "a headless report exists for this switch"
  # The headless report needs its triage first.
  lease audit-done --report "$r"
  assert_rc 5
  assert_has "$T/err" "has no triage yet"
  # A Triage heading inside the reviewer's findings does not count.
  awk '/^## Findings/ { print; print "## Triage"; print "fixed everything"; next } { print }' "$T/ops/ws/$r" >"$T/r" && mv "$T/r" "$T/ops/ws/$r"
  git -C "$T/ops/ws" commit -q -am "findings with a heading"
  lease audit-done --report "$r"
  assert_rc 5
  printf 'No findings to triage.\n' >>"$T/ops/ws/$r"
  git -C "$T/ops/ws" commit -q -am "triage"
  lease audit-done --report "$r"
  assert_rc 0
  assert_has "$T/out" "switch-in audit recorded (registry, claude -> codex): $r at"
  assert_has "$T/state/audit/ws.done" "report=$r"
  assert_has "$T/state/audit/ws.done" "commit=$(git -C "$T/ops/ws" log -1 --format=%h --abbrev=12 -- "$r")"
  assert_eq "$(audit_of ws)" "done"
  # Back to claude: a new change, a new pending audit.
  set_client ws claude
  run cross-review.sh --key ws --dry-run
  assert_has "$T/out" "would record a switch-in audit of ws (codex -> claude)"
  FAKE_MODE=nothing run cross-review.sh --key ws
  assert_eq "$(audit_of ws)" pending
}

test_lease_switch_report_follows_the_provider_not_the_transport() {
  lsetup
  both_families
  friday
  set_client ws file-only
  acq claude Workshop
  FAKE_MODE=nothing run cross-review.sh --key ws
  assert_has "$FAKE_LOG" "arg: strong-codex"
  assert_has "$FAKE_LOG" "family: claude"
  assert_has "$FAKE_LOG" "transport: file-only"
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 0 "takeover rc"
  assert_eq "$(audit_of ws)" pending
  : >"$FAKE_LOG"
  FAKE_OUTPUT="P2 - NOTES.md - stale - prune" run cross-review.sh --key ws
  assert_rc 0
  # The incoming family (codex) audits, whatever the transport.
  assert_has "$FAKE_LOG" "arg: strong-codex"
  assert_has "$FAKE_LOG" "switch: claude -> codex"
  r=audits/switch-in-lease-$(lget generation)-2.md
  assert_file "$T/ops/ws/$r"
  assert_has "$T/ops/ws/$r" "audit-done --instance <token> --epoch <n> --report"
  # The registry baseline follows the lease: no second, registry audit.
  assert_has "$T/state/audit/ws" "provider=codex"
  assert_lacks "$T/state/audit/ws" "to=codex"
  acq codex ops-ws
  lease audit-brief --instance "$TOK" --epoch 2
  assert_eq "$(sed -n 1p "$T/out")" "$(sed -n 1p "$T/ops/ws/$r")"
  assert_has "$T/out" "headless report: $r"
  printf 'Deferred (owner: ws): prune NOTES.md next week.\n' >>"$T/ops/ws/$r"
  git -C "$T/ops/ws" add audits && git -C "$T/ops/ws" commit -q -m "switch-in audit"
  lease audit-done --instance "$TOK" --epoch 2 --report "$r"
  assert_rc 0
  assert_eq "$(lget audit)" "done"
  assert_eq "$(lget audit_report)" "$r"
  assert_eq "$(lget audit_note)" "$(git -C "$T/ops/ws" log -1 --format=%h --abbrev=12 -- "$r")"
  assert_eq "$(audit_of ws)" "done"
  # Next week's review comes from the family opposite the lease's.
  : >"$FAKE_LOG"
  AO_NOW=$(epoch_of "2026-11-27 09:00")
  FAKE_MODE=nothing run cross-review.sh --key ws
  assert_has "$FAKE_LOG" "arg: strong-claude"
  assert_has "$FAKE_LOG" "family: codex"
}

test_switch_report_waits_for_the_lease_lock() {
  lsetup
  both_families
  friday
  acq claude Workshop
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  old_lock "$T/ops/ws"
  FAKE_MODE=nothing run cross-review.sh --key ws
  assert_rc 1
  assert_no_file "$T/ops/ws/audits"
  assert_has "$T/state/cross-review.log" "lease lock busy or stuck"
  assert_no_file "$T/state/cross-review/ws.switch"
}

test_off_still_records_switches() {
  both_families
  friday
  profile_set cross_review off
  run cross-review.sh
  assert_rc 0
  set_client beta codex
  run cross-review.sh
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  assert_has "$T/state/audit/beta" "to=codex"
  assert_eq "$(audit_of beta)" pending
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
  # A 0.2.0 install remembers the last client in alpha.client.
  mkdir -p "$T/state/cross-review"
  echo claude >"$T/state/cross-review/alpha.client"
  set_client alpha codex
  FAKE_MODE=nothing run cross-review.sh --key alpha
  assert_has "$T/state/audit/alpha" "from=claude"
  assert_no_file "$T/state/cross-review/alpha.client"
  assert_has "$T/state/cross-review/2026-W47/results.tsv" "alpha${TAB}switch${TAB}-${TAB}-${TAB}skipped: no reviewer role configured"
  assert_eq "$(calls claude)" 1 "only the weekly review, no audit by the outgoing family"
  assert_no_file "$T/proj/alpha/audits"
  assert_eq "$(audit_of alpha)" pending
  run cross-review.sh --key alpha
  assert_eq "$(calls claude)" 1 "waiting: no second attempt this week"
  # Once a reviewer of the incoming family exists, the audit runs, the
  # same week.
  profile_set reviewer_codex_model strong-codex
  FAKE_MODE=nothing run cross-review.sh --key alpha
  assert_has "$FAKE_LOG" "arg: strong-codex"
  assert_file "$(ls "$T/proj/alpha/audits"/switch-in-registry-*.md)"
  assert_has "$T/state/cross-review/alpha.switch" "registry-"
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
