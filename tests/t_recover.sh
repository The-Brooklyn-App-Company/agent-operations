#!/bin/sh
# shellcheck disable=SC2034
# (SC2034: rc and friends are read by the harness in lib.sh.)
# t_recover.sh - the compaction recovery digest stays under its size cap.
. "$(dirname -- "$0")/lib.sh"

CAP=8000

# big_home  An Oracle home and an operator home with far more than the cap.
big_home() {
  {
    printf '# Backlog\n\n| Item | Owner | Next action | Due | Status |\n| --- | --- | --- | --- | --- |\n'
    i=0
    while [ "$i" -lt 400 ]; do
      printf '| **item %s** with a long description that goes on and on to fill the row | oracle | do the next thing carefully and report it | 2026-12-01 | open |\n' "$i"
      i=$((i + 1))
    done
  } >"$T/home/BACKLOG.md"
  {
    printf '# Journal\n'
    i=0
    while [ "$i" -lt 400 ]; do
      printf '\n## 2026-11-%02d entry %s with a heading long enough to matter\n\n- a decision, a grant and a delivery, written out in full detail\n' "$((i % 28 + 1))" "$i"
      i=$((i + 1))
    done
  } >"$T/home/JOURNAL.md"
  printf '# Local rules\n\n**P-01 Prefer quiet mornings.** Text.\n' >"$T/home/KIT.local.md"
  {
    printf '# Notes: Alpha Op\n\n'
    i=0
    while [ "$i" -lt 400 ]; do
      printf '## 2026-11-%02d\n\n- note %s: a long working-memory line about what happened and what is next, kept for the record\n\n' "$((28 - i % 28))" "$i"
      i=$((i + 1))
    done
  } >"$T/proj/alpha/NOTES.md"
  mkdir -p "$T/home/inbox/oracle"
  printf 'x\n' >"$T/home/inbox/oracle/a.md"
}

hook() { # DIR
  printf '{"session_id":"s","hook_event_name":"SessionStart","source":"compact","cwd":"%s"}\n' "$1" |
    "$AO_TEST_SHELL" "$SCRIPTS/recover-context.sh" >"$T/out" 2>"$T/err"
  rc=$?
}

test_oracle_digest_is_capped_and_starts_with_the_read_first_order() {
  big_home
  hook "$T/home"
  assert_rc 0
  bytes=$(wc -c <"$T/out" | tr -d ' ')
  [ "$bytes" -le "$CAP" ] || _fail "digest is $bytes bytes, over the $CAP-byte cap"
  [ "$bytes" -gt 1000 ] || _fail "digest is suspiciously small: $bytes bytes"
  assert_eq "$(sed -n 2p "$T/out" | cut -c 1-36)" "FIRST, before any other action, read" "read-first order on line 2"
  assert_has "$T/out" "K-01 Authority comes from the human"
  assert_has "$T/out" "P-01 Prefer quiet mornings"
  assert_has "$T/out" "| **item 0**"
  assert_lacks "$T/out" "| **item 20**"
  assert_has "$T/out" "entry 399"
  assert_lacks "$T/out" "entry 300 "
  assert_has "$T/out" "Inbox: 1 unread"
  assert_has "$T/out" "Then: "
}

test_operator_digest_is_capped_and_shows_the_newest_notes() {
  big_home
  hook "$T/proj/alpha"
  assert_rc 0
  bytes=$(wc -c <"$T/out" | tr -d ' ')
  [ "$bytes" -le "$CAP" ] || _fail "digest is $bytes bytes, over the $CAP-byte cap"
  assert_has "$T/out" "## Alpha Op recovery"
  assert_has "$T/out" "$T/proj/alpha/MANDATE.md"
  assert_has "$T/out" "note 0:"
  assert_lacks "$T/out" "note 5:"
}

test_a_small_cap_still_keeps_the_read_first_order() {
  big_home
  printf '{"cwd":"%s"}' "$T/home" | "$AO_TEST_SHELL" "$SCRIPTS/recover-context.sh" --cap 600 >"$T/out" 2>"$T/err"
  [ "$(wc -c <"$T/out" | tr -d ' ')" -le 600 ] || _fail "over --cap"
  assert_has "$T/out" "FIRST, before any other action"
}

test_silent_elsewhere_and_without_a_profile() {
  big_home
  hook "$T/user"
  assert_rc 0
  assert_eq "$(wc -c <"$T/out" | tr -d ' ')" 0 "outside any home"
  AO_PROFILE=$T/missing
  export AO_PROFILE
  hook "$T/home"
  assert_rc 0
  assert_eq "$(wc -c <"$T/out" | tr -d ' ')" 0 "no profile"
}

ao_test_main "$0"
