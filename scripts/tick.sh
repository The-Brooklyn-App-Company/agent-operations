#!/bin/sh
# tick.sh - the scheduled heartbeat: free deterministic checks, then relay.
#
# Usage: tick.sh [--dry-run] [--no-relay]
#
# Run by launchd or systemd every few minutes (see units/). Each run, in
# order, under a lock so runs never overlap:
#   1. Stall watchdog. Inside the work window (watchdog_days, watchdog_hours)
#      every registry row except the Oracle's, not on the quiet list, with a
#      session id, whose transcript has been idle longer than
#      watchdog_idle_min, or that has no transcript, gets one note in the
#      Oracle's inbox; at most one per operator per watchdog_realert_min.
#   2. Hooks. Executables in <hooks_dir>/every run on every tick; those in
#      hourly/, daily/ (from daily_hour) and weekly/ (from weekly_day at
#      weekly_hour, catching up later that ISO week) run once per period,
#      in name order, each under hook_timeout. A failing hook leaves one
#      note in the Oracle's inbox. Hooks get AO_PROFILE, AO_HOME, AO_INBOX,
#      AO_STATE, AO_SCRIPTS, AO_ORACLE_KEY and AO_PERIOD, stdin closed,
#      cwd = oracle_home; their output goes to <state_dir>/hooks.log.
#   3. Relay (relay.sh), which costs nothing when every inbox is empty.
#
# Options:
#   --dry-run   report what would happen; write, run and deliver nothing
#   --no-relay  skip step 3
#   -h, --help  this text
#
# Environment: AO_PROFILE; AO_NOW (epoch seconds) pins the clock for tests.
# Logs: <state_dir>/watchdog-alerts.log, <state_dir>/hooks.log.
#
# Exit codes: 0 all steps fine; 1 a hook or delivery failed; 2 usage or
# configuration error; 3 a previous tick is still running.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"

dry_run=
relay=1
failures=0

# tick_num STRING  Print a decimal string without leading zeros.
tick_num() {
  printf '%s\n' "$1" | sed 's/^0*\([0-9]\)/\1/'
}

# tick_in_days DOW SPEC  SPEC: `all`, or comma list of N or N-M (1=Mon).
tick_in_days() {
  [ "$2" = all ] && return 0
  _rest=$2,
  while [ -n "$_rest" ]; do
    _r=${_rest%%,*}
    _rest=${_rest#*,}
    _lo=${_r%-*} _hi=${_r#*-}
    if ! ao_is_uint "$_lo" || ! ao_is_uint "$_hi"; then
      ao_die "$AO_E_USAGE" "watchdog_days: bad range '$_r'"
    fi
    [ "$1" -ge "$_lo" ] && [ "$1" -le "$_hi" ] && return 0
  done
  return 1
}

# tick_in_hours HOUR SPEC  SPEC: `all`, or HH-HH (start inclusive, end
# exclusive: 09-19 is 09:00 to 18:59).
tick_in_hours() {
  [ "$2" = all ] && return 0
  _lo=$(tick_num "${2%-*}") _hi=$(tick_num "${2#*-}")
  if ! ao_is_uint "$_lo" || ! ao_is_uint "$_hi"; then
    ao_die "$AO_E_USAGE" "watchdog_hours: expected HH-HH or all, got '$2'"
  fi
  [ "$1" -ge "$_lo" ] && [ "$1" -lt "$_hi" ]
}

# watchdog_row  Registry callback: alert on one stalled operator.
watchdog_row() {
  [ "$OP_KEY" != "$AO_ORACLE_KEY" ] || return 0
  [ -n "$OP_SID" ] || return 0
  [ -z "$(ao_quiet_until "$OP_KEY" "$OP_NAME")" ] || return 0
  ao_gate watchdog || return 0
  _state=$(ao_idle_state)
  case $_state in
    no-transcript) ;;
    idle_min=*) [ "${_state#idle_min=}" -gt "$idle_min" ] || return 0 ;;
    *) return 0 ;;
  esac
  _stamp=$AO_STATE/watchdog/$OP_KEY.last
  _last=$(cat "$_stamp" 2>/dev/null) || _last=0
  ao_is_uint "$_last" || _last=0
  [ $((AO_T_EPOCH - _last)) -ge $((realert_min * 60)) ] || return 0
  if [ -n "$dry_run" ]; then
    printf 'would alert: %s %s\n' "$OP_NAME" "$_state"
    return 0
  fi
  mkdir -p "$AO_STATE/watchdog"
  printf '%s\n' "$AO_T_EPOCH" >"$_stamp"
  ao_log "$AO_STATE/watchdog-alerts.log" "$OP_KEY $OP_NAME $_state"
  ao_note_oracle "watchdog-$OP_KEY" "Watchdog: $OP_NAME $_state (work hours). Check whether it stalled with work outstanding."
}

tick_watchdog() {
  days=$(ao_cfg watchdog_days 1-5)
  hours=$(ao_cfg watchdog_hours 09-19)
  idle_min=$(ao_cfg_uint watchdog_idle_min 180) || exit
  realert_min=$(ao_cfg_uint watchdog_realert_min 180) || exit
  [ "$idle_min" -gt 0 ] || return 0
  tick_in_days "$AO_T_DOW" "$days" && tick_in_hours "$AO_T_HOUR" "$hours" || return 0
  ao_registry_each watchdog_row
}

# tick_period_key PERIOD  Print the stamp value for PERIOD if it is due
# (hourly, daily, weekly); print nothing if not due yet.
tick_period_key() {
  case $1 in
    hourly) printf '%s-%s\n' "$AO_T_DATE" "$AO_T_HOUR" ;;
    daily)
      [ "$AO_T_HOUR" -lt "$daily_hour" ] || printf '%s\n' "$AO_T_DATE" ;;
    weekly)
      if [ "$AO_T_DOW" -gt "$weekly_day" ] ||
        { [ "$AO_T_DOW" -eq "$weekly_day" ] && [ "$AO_T_HOUR" -ge "$weekly_hour" ]; }; then
        printf '%s\n' "$AO_T_WEEK"
      fi ;;
  esac
}

# tick_hooks PERIOD  Run PERIOD's hooks if the period is due.
tick_hooks() {
  _dir=$AO_HOOKS/$1
  [ -d "$_dir" ] || return 0
  if [ "$1" != every ]; then
    _want=$(tick_period_key "$1")
    _sfile=$AO_STATE/stamps/$1
    [ -n "$_want" ] && [ "$(cat "$_sfile" 2>/dev/null)" != "$_want" ] || return 0
    if [ -z "$dry_run" ]; then
      mkdir -p "$AO_STATE/stamps"
      printf '%s\n' "$_want" >"$_sfile"
    fi
  fi
  for _hook in "$_dir"/*; do
    _name=${_hook##*/}
    case $_name in .* | *~ | *.disabled | *.example) continue ;; esac
    [ -f "$_hook" ] && [ -x "$_hook" ] || continue
    if [ -n "$dry_run" ]; then
      printf 'would run hook: %s/%s\n' "$1" "$_name"
      continue
    fi
    ao_log "$AO_STATE/hooks.log" "run $1/$_name"
    (cd "$AO_HOME" && AO_PERIOD=$1 && export AO_PERIOD &&
      ao_timeout "$hook_timeout" "$_hook" </dev/null >>"$AO_STATE/hooks.log" 2>&1)
    _rc=$?
    [ "$_rc" -eq 0 ] && continue
    failures=$((failures + 1))
    ao_log "$AO_STATE/hooks.log" "FAILED $1/$_name rc=$_rc"
    ao_note_oracle "hook-fail-$1-$_name" "Hook $1/$_name failed (exit $_rc) at $AO_T_STAMP. Output: $AO_STATE/hooks.log"
  done
}

tick_relay() {
  if [ -n "$dry_run" ]; then
    "$AO_SCRIPTS/relay.sh" --dry-run
  else
    "$AO_SCRIPTS/relay.sh"
  fi
  case $? in 0 | "$AO_E_BUSY") ;; *) failures=$((failures + 1)) ;; esac
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry_run=1 ;;
      --no-relay) relay= ;;
      -h | --help) ao_usage; exit 0 ;;
      *) ao_die "$AO_E_USAGE" "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  ao_load
  ao_lock tick || { ao_msg "previous tick still running; skipping"; exit "$AO_E_BUSY"; }
  hook_timeout=$(ao_cfg_uint hook_timeout 900) || exit
  daily_hour=$(ao_cfg_uint daily_hour 6) || exit
  weekly_day=$(ao_cfg_uint weekly_day 5) || exit
  weekly_hour=$(ao_cfg_uint weekly_hour 6) || exit
  tick_watchdog
  for period in every hourly daily weekly; do tick_hooks "$period"; done
  [ -z "$relay" ] || tick_relay
  [ "$failures" -eq 0 ] || exit "$AO_E_FAIL"
}

main "$@"
