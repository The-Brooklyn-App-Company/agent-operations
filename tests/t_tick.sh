#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_tick.sh - watchdog, quiet list, period hooks, relay step, locking.
. "$(dirname -- "$0")/lib.sh"

# at "YYYY-MM-DD HH:MM"  Pin the clock. 2026-11-17 is a Tuesday.
at() {
  AO_NOW=$(epoch_of "$1")
  export AO_NOW
}

hook() { # PERIOD NAME [BODY]
  mkdir -p "$T/home/hooks/$1"
  printf '#!/bin/sh\n%s\n' "${3:-echo \"\$AO_PERIOD\" >>\"\$AO_STATE/ran-$2\"}" >"$T/home/hooks/$1/$2"
  chmod +x "$T/home/hooks/$1/$2"
}

ran() { cat "$T/state/ran-$1" 2>/dev/null | wc -l | tr -d ' '; }

test_watchdog_alerts_idle_operator_once() {
  transcript "$T/proj/alpha" 202611170700
  transcript "$T/proj/beta" 202611171500
  at "2026-11-17 12:00"
  run tick.sh --no-relay
  assert_rc 0
  assert_count "$T/home/inbox/oracle" 1
  assert_has "$(ls "$T/home/inbox/oracle"/*-watchdog-alpha.md)" "Watchdog: Alpha Op idle_min=300"
  assert_has "$T/state/watchdog-alerts.log" "alpha Alpha Op idle_min=300"
  at "2026-11-17 13:00"
  run tick.sh --no-relay
  assert_count "$T/home/inbox/oracle" 1
  at "2026-11-17 15:10"
  run tick.sh --no-relay
  assert_count "$T/home/inbox/oracle" 2
}

test_watchdog_no_transcript_alerts() {
  transcript "$T/proj/beta" 202611171130
  at "2026-11-17 12:00"
  run tick.sh --no-relay
  assert_has "$(ls "$T/home/inbox/oracle"/*-watchdog-alpha.md)" "no-transcript"
}

test_watchdog_respects_window() {
  at "2026-11-17 20:00"
  run tick.sh --no-relay
  assert_no_file "$T/home/inbox/oracle"
  at "2026-11-21 12:00"
  run tick.sh --no-relay
  assert_no_file "$T/home/inbox/oracle"
  profile_set watchdog_days all
  profile_set watchdog_hours all
  run tick.sh --no-relay
  assert_count "$T/home/inbox/oracle" 2
}

test_watchdog_skips_quiet_pending_and_oracle() {
  printf '# who\tuntil\twhy\nAlpha Op\t2026-11-17\tparked\nbeta\t2026-11-01\texpired\n' >"$T/home/operators/WATCHDOG-QUIET.tsv"
  printf 'gamma\tGamma\t%s\tpending\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  at "2026-11-17 12:00"
  run tick.sh --no-relay
  assert_count "$T/home/inbox/oracle" 1
  assert_file "$(ls "$T/home/inbox/oracle"/*-watchdog-beta.md)"
}

test_watchdog_disabled_with_zero() {
  profile_set watchdog_idle_min 0
  at "2026-11-17 12:00"
  run tick.sh --no-relay
  assert_no_file "$T/home/inbox/oracle"
}

test_watchdog_dry_run_writes_nothing() {
  at "2026-11-17 12:00"
  run tick.sh --dry-run
  assert_rc 0
  assert_has "$T/out" "would alert: Alpha Op no-transcript"
  assert_no_file "$T/home/inbox/oracle"
  assert_no_file "$T/state/watchdog"
}

test_hooks_run_once_per_period() {
  hook every e
  hook hourly h
  hook daily d
  hook weekly w
  at "2026-11-17 05:10"
  run tick.sh --no-relay
  assert_eq "$(ran e) $(ran h) $(ran d) $(ran w)" "1 1 0 0" "before daily_hour"
  at "2026-11-17 06:20"
  run tick.sh --no-relay
  at "2026-11-17 06:30"
  run tick.sh --no-relay
  assert_eq "$(ran e) $(ran h) $(ran d) $(ran w)" "3 2 1 0" "same hour"
  at "2026-11-20 06:00"
  run tick.sh --no-relay
  at "2026-11-20 09:00"
  run tick.sh --no-relay
  assert_eq "$(ran d) $(ran w)" "2 1" "friday"
  assert_eq "$(sed -n 1p "$T/state/ran-w")" weekly
}

test_weekly_hook_catches_up() {
  hook weekly w
  at "2026-11-21 10:00"
  run tick.sh --no-relay
  assert_eq "$(ran w)" 1 "saturday catch-up"
  at "2026-11-22 10:00"
  run tick.sh --no-relay
  assert_eq "$(ran w)" 1 "already ran this ISO week"
  at "2026-11-24 10:00"
  run tick.sh --no-relay
  assert_eq "$(ran w)" 1 "not yet due next week"
}

test_interrupted_period_runs_unstarted_hooks() {
  hook daily a
  hook daily b
  AO_NOW=$(epoch_of "2026-11-17 07:00")
  export AO_NOW
  mkdir -p "$T/state/stamps"
  # As if a previous tick died while running hook a.
  echo 2026-11-17 >"$T/state/stamps/daily-a"
  run tick.sh --no-relay
  assert_eq "$(ran a) $(ran b)" "0 1"
}

test_unrecordable_stamp_blocks_the_hook() {
  hook daily d
  : >"$T/state/stamps"
  at "2026-11-17 07:00"
  run tick.sh --no-relay
  assert_rc 1
  assert_eq "$(ran d)" 0
  assert_has "$T/err" "not running daily/d"
}

test_failed_alert_is_retried() {
  at "2026-11-17 12:00"
  mkdir -p "$T/home/inbox"
  : >"$T/home/inbox/oracle"
  run tick.sh --no-relay
  assert_rc 1
  assert_no_file "$T/state/watchdog/alpha.last"
  mv "$T/home/inbox/oracle" "$T/blocker"
  run tick.sh --no-relay
  assert_rc 0
  assert_file "$(ls "$T/home/inbox/oracle"/*-watchdog-alpha.md)"
}

test_failing_hook_is_reported() {
  hook every bad 'echo "hook says no"; exit 5'
  hook every good
  at "2026-11-17 20:00"
  run tick.sh --no-relay
  assert_rc 1
  assert_eq "$(ran good)" 1
  assert_has "$(ls "$T/home/inbox/oracle"/*-hook-fail-every-bad.md)" "Hook every/bad failed (exit 5)"
  assert_has "$T/state/hooks.log" "hook says no"
}

test_hook_gets_environment_and_closed_stdin() {
  hook every env 'printf "%s|%s|%s|%s|%s\n" "$AO_INBOX" "$AO_ORACLE_KEY" "$PWD" "$AO_SCRIPTS" "$(cat)" >"$AO_STATE/env"'
  at "2026-11-17 20:00"
  run tick.sh --no-relay
  assert_eq "$(cat "$T/state/env")" "$T/home/inbox|oracle|$T/home|$SCRIPTS|"
}

test_hook_timeout() {
  profile_set hook_timeout 1
  hook every slow 'sleep 20'
  at "2026-11-17 20:00"
  AO_TIMEOUT_BIN=none run tick.sh --no-relay
  assert_rc 1
  assert_has "$(ls "$T/home/inbox/oracle"/*-hook-fail-every-slow.md)" "exit 124"
}

test_skipped_hook_files() {
  hook every a.example
  hook every b.disabled
  hook every .hidden
  mkdir -p "$T/home/hooks/every"
  printf '#!/bin/sh\necho x >>"$AO_STATE/ran-plain"\n' >"$T/home/hooks/every/plain"
  at "2026-11-17 20:00"
  run tick.sh --no-relay
  assert_rc 0
  assert_eq "$(ran a.example)$(ran b.disabled)$(ran .hidden)$(ran plain)" "0000"
}

test_dry_run_runs_no_hooks() {
  hook daily d
  at "2026-11-17 07:00"
  run tick.sh --dry-run
  assert_has "$T/out" "would run hook: daily/d"
  assert_eq "$(ran d)" 0
  assert_no_file "$T/state/stamps/daily-d"
}

test_tick_relays() {
  at "2026-11-17 20:00"
  note beta b.md "deliver me"
  FAKE_MODE=sent run tick.sh
  assert_rc 0
  assert_count "$T/home/inbox/beta" 0
}

test_tick_with_no_changes_starts_neither_client() {
  printf 'gamma\tGamma Op\t%s\tsid-g\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  at "2026-11-17 20:00"
  run tick.sh
  assert_rc 0
  assert_no_file "$FAKE_LOG"
}

test_tick_relay_failure_is_reported() {
  at "2026-11-17 20:00"
  note beta b.md "deliver me"
  FAKE_MODE=failed run tick.sh
  assert_rc 1
}

test_tick_lock() {
  hold_lock tick
  hook every e
  run tick.sh
  release_lock
  assert_rc 3
  assert_eq "$(ran e)" 0
}

test_term_to_the_tick_stops_the_running_hook() {
  # The tick is told to stop mid-hook: the hook (which ignores TERM) is gone
  # before the tick exits, and the lock is free again.
  hook every slow 'trap "" TERM; sleep 8; : >"$AO_STATE/survived"'
  at "2026-11-17 20:00"
  "$AO_TEST_SHELL" "$SCRIPTS/tick.sh" --no-relay </dev/null >"$T/out" 2>"$T/err" &
  tick=$!
  sleep 2
  kill -s TERM "$tick"
  wait "$tick"
  rc=$?
  assert_rc 143
  sleep 7
  assert_no_file "$T/state/survived"
  hook every e
  run tick.sh --no-relay
  assert_eq "$(ran e)" 1
}

test_overnight_watchdog_window() {
  profile_set watchdog_hours 22-06
  profile_set watchdog_days all
  for t in "2026-11-17 23:00" "2026-11-18 03:00"; do
    rm -rf "$T/state/watchdog" "$T/home/inbox/oracle"
    at "$t"
    run tick.sh --no-relay
    assert_count "$T/home/inbox/oracle" 2
  done
  rm -rf "$T/state/watchdog" "$T/home/inbox/oracle"
  at "2026-11-17 12:00"
  run tick.sh --no-relay
  assert_no_file "$T/home/inbox/oracle"
}

test_hook_failure_notes_are_rate_limited() {
  hook every bad 'exit 5'
  at "2026-11-17 20:00"
  run tick.sh --no-relay
  AO_NOW=$((AO_NOW + 600))
  run tick.sh --no-relay
  assert_rc 1
  set -- "$T/home/inbox/oracle"/*-hook-fail-every-bad.md
  assert_eq "$#" 1 "hook-fail notes"
  assert_eq "$(grep -c 'FAILED every/bad' "$T/state/hooks.log")" 2 "logged failures"
}

test_writable_hooks_are_skipped() {
  hook every loose
  chmod 777 "$T/home/hooks/every/loose"
  at "2026-11-17 20:00"
  run tick.sh --no-relay
  assert_rc 1
  assert_eq "$(ran loose)" 0
  assert_has "$T/state/hooks.log" "SKIPPED every/loose"
}

test_bad_window_config() {
  profile_set watchdog_hours "nine-five"
  at "2026-11-17 12:00"
  run tick.sh --no-relay
  assert_rc 2
}

test_bad_hook_config_is_an_error() {
  profile_set daily_hour six
  run tick.sh --no-relay
  assert_rc 2
}

ao_test_main "$0"
