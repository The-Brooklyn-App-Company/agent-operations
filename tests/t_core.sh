#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_core.sh - profile parsing, paths, clock, locking, timeouts, usage text.
. "$(dirname -- "$0")/lib.sh"

# lib CODE  Run CODE with core.sh (and registry.sh) sourced and the profile loaded.
lib() {
  "$AO_TEST_SHELL" -c '
    AO_SCRIPTS=$1; shift
    . "$AO_SCRIPTS/lib/core.sh"; . "$AO_SCRIPTS/lib/registry.sh"
    ao_load
    eval "$1"' sh "$SCRIPTS" "$1" >"$T/out" 2>"$T/err"
  rc=$?
}

test_profile_values_are_literal() {
  cat >>"$T/profile" <<'EOF'
# a comment
   x_spaced   =   padded value
x_quoted="quoted # not a comment"
x_dollar=$(touch SHOULD_NOT_EXIST) `id` $HOME
EOF
  lib 'ao_cfg x_spaced; ao_cfg x_quoted; ao_cfg x_dollar; ao_cfg x_missing fallback'
  assert_rc 0
  assert_eq "$(sed -n 1p "$T/out")" "padded value"
  assert_eq "$(sed -n 2p "$T/out")" "quoted # not a comment"
  assert_eq "$(sed -n 3p "$T/out")" '$(touch SHOULD_NOT_EXIST) `id` $HOME'
  assert_eq "$(sed -n 4p "$T/out")" fallback
  assert_no_file "$T/home/SHOULD_NOT_EXIST"
  assert_no_file "$PWD/SHOULD_NOT_EXIST"
}

test_profile_later_lines_win() {
  profile_set worker_model second
  lib 'ao_cfg worker_model'
  assert_eq "$(cat "$T/out")" second
}

test_profile_unknown_key_warns() {
  profile_set wroker_model typo
  lib ':'
  assert_rc 0
  assert_has "$T/err" "unknown key 'wroker_model'"
}

test_profile_bad_line_is_an_error() {
  printf 'no equals sign here\n' >>"$T/profile"
  lib ':'
  assert_rc 2
  assert_has "$T/err" "expected key=value"
}

test_profile_bad_key_is_an_error() {
  printf 'Bad-Key=1\n' >>"$T/profile"
  lib ':'
  assert_rc 2
  assert_has "$T/err" "invalid key"
}

test_profile_missing_is_an_error() {
  AO_PROFILE=$T/nope
  export AO_PROFILE
  lib ':'
  assert_rc 2
  assert_has "$T/err" "profile not readable"
}

test_oracle_home_required() {
  grep -v '^oracle_home=' "$T/profile" >"$T/p2" && mv "$T/p2" "$T/profile"
  lib ':'
  assert_rc 2
  assert_has "$T/err" "oracle_home is required"
}

test_uint_keys_are_validated() {
  profile_set watchdog_idle_min soon
  lib 'v=$(ao_cfg_uint watchdog_idle_min 5) || exit; echo "$v"'
  assert_rc 2
  assert_has "$T/err" "must be a non-negative integer"
}

test_paths_expand_tilde_and_relative() {
  lib 'ao_expand_path "~/x"; ao_expand_path rel; ao_expand_path /abs; printf "%s\n" "$AO_REGISTRY"'
  assert_eq "$(sed -n 1p "$T/out")" "$T/user/x"
  assert_eq "$(sed -n 2p "$T/out")" "$T/home/rel"
  assert_eq "$(sed -n 3p "$T/out")" /abs
  assert_eq "$(sed -n 4p "$T/out")" "$T/home/operators/REGISTRY.tsv"
}

test_clock_can_be_pinned() {
  AO_NOW=$(epoch_of "2026-11-20 07:05")
  export AO_NOW
  lib 'echo "$AO_T_DATE $AO_T_HOUR $AO_T_DOW $AO_T_WEEK $AO_T_STAMP"'
  assert_eq "$(cat "$T/out")" "2026-11-20 7 5 2026-W47 20261120T070500"
}

test_lock_is_exclusive_and_released() {
  lib 'ao_lock demo && echo first; ( AO_LOCK=; ao_lock demo; echo "inner=$?" )'
  assert_has "$T/out" first
  assert_has "$T/out" "inner=3"
  assert_no_file "$T/state/locks/demo.lock"
}

test_cleanup_only_releases_own_lock() {
  lib 'ao_lock demo; echo 1 >"$AO_STATE/locks/demo.lock/pid"'
  assert_file "$T/state/locks/demo.lock"
}

test_stale_reclaim_marker_is_cleared() {
  mkdir -p "$T/state/locks/demo.lock" "$T/state/locks/demo.lock.reclaim"
  echo 999999999 >"$T/state/locks/demo.lock/pid"
  touch -t 202001010000 "$T/state/locks/demo.lock.reclaim"
  lib 'ao_lock demo; echo "first=$?"; ao_lock demo && echo second'
  assert_has "$T/out" "first=3"
  assert_has "$T/out" "second"
}

test_inbox_put_never_overwrites() {
  AO_NOW=$(epoch_of "2026-11-17 12:00")
  export AO_NOW
  lib 'i=0; while [ $i -lt 5 ]; do echo "n$i" | ao_inbox_put alpha same & i=$((i + 1)); done; wait'
  assert_count "$T/home/inbox/alpha" 5
}

test_stale_lock_is_reclaimed() {
  mkdir -p "$T/state/locks/demo.lock"
  # A pid that cannot be alive: above any default pid_max.
  echo 999999999 >"$T/state/locks/demo.lock/pid"
  lib 'ao_lock demo && echo got'
  assert_has "$T/out" got
  assert_has "$T/err" "reclaiming stale lock"
}

test_subshell_exit_keeps_parent_lock_and_tmp() {
  lib 'ao_lock demo; f=$(ao_tmp keep); ( exit 3 ); [ -d "$AO_STATE/locks/demo.lock" ] && [ -f "$f" ] && echo intact'
  assert_has "$T/out" intact
}

test_timeout_portable_fallback() {
  AO_TIMEOUT_BIN=none
  export AO_TIMEOUT_BIN
  lib 'ao_timeout 1 sleep 20; echo "slow=$?"; ao_timeout 5 sh -c "exit 6"; echo "fast=$?"; ao_timeout 0 true; echo "none=$?"'
  assert_has "$T/out" "slow=124"
  assert_has "$T/out" "fast=6"
  assert_has "$T/out" "none=0"
}

test_timeout_kills_descendants() {
  _bins=$(command -v timeout || command -v gtimeout || true)
  # The portable path can only reach descendants where job control works.
  if "$AO_TEST_SHELL" -c 'set -m 2>/dev/null; case $- in *m*) exit 0 ;; esac; exit 1' </dev/null; then
    _bins="$_bins none"
  fi
  for _bin in $_bins; do
    AO_TIMEOUT_BIN=$_bin
    export AO_TIMEOUT_BIN
    lib 'ao_timeout 1 sh -c "(sleep 3; : >\"$AO_HOME/survivor\") & sleep 20"; echo "rc=$?"'
    assert_has "$T/out" "rc=124"
    assert_eq "$(wc -c <"$T/err" | tr -d ' ')" 0 "stderr bytes ($_bin)"
  done
  sleep 3
  assert_no_file "$T/home/survivor"
}

test_timeout_coreutils() {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || return 0
  lib 'ao_timeout 1 sleep 20; echo "slow=$?"; ao_timeout 5 sh -c "exit 6"; echo "fast=$?"'
  assert_has "$T/out" "slow=124"
  assert_has "$T/out" "fast=6"
}

test_usage_is_the_header() {
  run tick.sh --help
  assert_rc 0
  assert_has "$T/out" "Usage: tick.sh [--dry-run] [--no-relay]"
  assert_has "$T/out" "Exit codes:"
  assert_lacks "$T/out" "set -u"
}

test_registry_survives_stdin_readers() {
  lib 'cb() { cat >/dev/null; echo "row=$OP_KEY"; }; ao_registry_each cb'
  assert_eq "$(grep -c '^row=' "$T/out")" 3
}

ao_test_main "$0"
