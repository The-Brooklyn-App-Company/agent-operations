#!/bin/sh
# mailroom.sh - EXPERIMENTAL: the cross-app mailroom's helpers.
#
# Usage: mailroom.sh status
#        mailroom.sh cycle
#        mailroom.sh supervise [--dry-run]
#        mailroom.sh wait claude|codex
#        mailroom.sh file claude|codex RING... [--by BY] [--mode MODE] [--wait]
#        mailroom.sh metrics [HOURS]
#        mailroom.sh arm-codex
#
# One rule: the relay routes, the bridges deliver, and a model-free
# supervisor keeps both bridges armed. Same-app messages go direct with the
# app's own tools; the mailroom carries only cross-app messages and notes
# from scripts. Lanes are never pre-woken: a message is their first wake.
# See docs/mailroom.md.
#
# status     Waiting rings per side (count, oldest age), each watcher's state
#            and the last delivery. Read-only.
# cycle      What the relay unit runs: relay.sh, then supervise, each under
#            its own lock (fallbacks never hold the relay lock).
# supervise  The supervisor (lib/mailroom.sh ao_mr_supervise): fallbacks
#            for rings that wait, re-arming a bridge whose watcher is down
#            (app restart, reboot, crash), one alarm per episode, and free
#            hourly echo probes (<state_dir>/mailroom-probe.tsv). No model
#            runs unless something is down or stuck.
# wait       For the Claude bridge's background task: block with no polling
#            (a kqueue push watch, macOS) until a ring is waiting, print each
#            as `=== <name>` followed by its body, and exit 0. Exit 2 where
#            no push watch is available.
# file       For a bridge after it handed rings off: move each to
#            delivered/ and log it (default --by bridge, --mode -; probe
#            rings are filed as echo). --wait then becomes `wait` for the
#            same side, so one background command files, logs and re-arms.
#            Exit 1 if a ring is no longer waiting (the others are filed).
# metrics    One paragraph for the last HOURS (default 24): rings, who
#            delivered them, median ring-to-delivery time, safety-net use,
#            alarms, waiting rings and probe results. Read-only.
# arm-codex  For the Codex bridge chat, from its own command session:
#            becomes the Codex watcher (bridge_codex_node running
#            mailroom-codex-watcher.cjs against bridge_codex_server), unless
#            a live watcher's heartbeat is fresh (prints "armed", exit 0).
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 done; 1 a failure; 2 usage or configuration error, or
# unavailable; 3 busy.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"
. "$AO_SCRIPTS/lib/mailroom.sh"

mr_side() {
  case ${1-} in claude | codex) ;; *) ao_die "$AO_E_USAGE" "expected claude or codex, got '${1-}'" ;; esac
}

mr_status() {
  for _s in claude codex; do
    _n=0 _old=0
    for _r in "$AO_MR_DIR/$_s"/*.md; do
      [ -f "$_r" ] || continue
      _n=$((_n + 1))
      _a=$(ao_mr_age "$_r")
      [ "$_a" -le "$_old" ] || _old=$_a
    done
    _w='no bridge row'
    if ao_mr_bridge "$_s"; then
      if ao_mr_watcher_up "$_s"; then _w='watcher armed'; else _w='watcher DOWN'; fi
    fi
    _last=$(tail -n 1 "$AO_MR_DIR/$_s/delivered/log.tsv" 2>/dev/null | cut -f 1,4,5 | tr '\t' ' ')
    printf '%s: %s; waiting %s (oldest %ss); last delivery: %s\n' "$_s" "$_w" "$_n" "$_old" "${_last:-none}"
  done
}

mr_cycle() {
  "$AO_SCRIPTS/relay.sh" </dev/null
  _rc=$?
  case $_rc in 0 | "$AO_E_BUSY") _rc=0 ;; esac
  "$AO_SCRIPTS/mailroom.sh" supervise </dev/null
  case $? in 0 | "$AO_E_BUSY") ;; *) _rc=$AO_E_FAIL ;; esac
  exit "$_rc"
}

mr_supervise() {
  _dry=
  case ${1-} in --dry-run) _dry=1 ;; '') ;; *) ao_die "$AO_E_USAGE" "usage: mailroom.sh supervise [--dry-run]" ;; esac
  [ "$AO_MR_ON" = on ] || exit 0
  ao_lock mailroom || { ao_msg "another supervisor is running; skipping"; exit "$AO_E_BUSY"; }
  ao_mr_supervise "$_dry" || exit "$AO_E_FAIL"
}

mr_wait() {
  mr_side "${1-}"
  mkdir -p "$AO_MR_DIR/$1/.watcher" || ao_die "$AO_E_FAIL" "cannot create $AO_MR_DIR/$1"
  [ -x /usr/bin/python3 ] || ao_die "$AO_E_USAGE" "/usr/bin/python3 not found: no push watch here"
  exec /usr/bin/python3 -I "$AO_SCRIPTS/mailroom-wait.py" "$AO_MR_DIR/$1"
}

mr_file() {
  mr_side "${1-}"
  _side=$1
  shift
  _by=bridge _mode=- _wait='' _rings=$(ao_tmp rings)
  while [ $# -gt 0 ]; do
    case $1 in
      --by) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--by needs a value"; _by=$2; shift ;;
      --mode) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--mode needs a value"; _mode=$2; shift ;;
      --wait) _wait=1 ;;
      -*) ao_die "$AO_E_USAGE" "unknown option '$1'" ;;
      *)
        _r=${1##*/}
        case $_r in *.md) ao_is_name "$_r" ;; *) false ;; esac || ao_die "$AO_E_USAGE" "not a ring name: $_r"
        printf '%s\n' "$_r" >>"$_rings" ;;
    esac
    shift
  done
  ao_is_name "$_by" || ao_die "$AO_E_USAGE" "--by takes a word"
  [ "$_mode" = - ] || ao_is_name "$_mode" || ao_die "$AO_E_USAGE" "--mode takes a word"
  [ -s "$_rings" ] || [ -n "$_wait" ] || ao_die "$AO_E_USAGE" "usage: mailroom.sh file claude|codex RING... [--by BY] [--mode MODE] [--wait]"
  _bad=0
  while IFS= read -r _r; do
    _m=$_mode
    case $_r in echo--*) _m='echo' ;; esac
    if ao_mr_file "$_side" "$_r" "$_by" "$_m"; then
      echo "filed: $_side/$_r"
    else
      ao_msg "$_r is not waiting in $AO_MR_DIR/$_side"
      _bad=1
    fi
  done <"$_rings"
  [ -z "$_wait" ] || mr_wait "$_side"
  exit "$_bad"
}

# ---------------------------------------------------------------- metrics

# mr_or_empty FILE  FILE if it exists, else /dev/null (read as empty).
mr_or_empty() {
  if [ -f "$1" ]; then printf '%s\n' "$1"; else printf '/dev/null\n'; fi
}

mr_metrics() {
  _h=${1:-24}
  ao_is_uint "$_h" && [ "$_h" -gt 0 ] || ao_die "$AO_E_USAGE" "HOURS must be a positive integer"
  _cut=$((AO_T_EPOCH - _h * 3600))
  _wc=0 _wx=0
  for _r in "$AO_MR_DIR/claude"/*.md; do [ -f "$_r" ] && _wc=$((_wc + 1)); done
  for _r in "$AO_MR_DIR/codex"/*.md; do [ -f "$_r" ] && _wx=$((_wx + 1)); done
  # Each input is tagged by position (empty files and /dev/null stand-ins
  # count too), so the four parts never mix.
  _pt=$(ao_tmp parts)
  for _f in "$AO_MR_LOG" "$AO_MR_DIR/claude/delivered/log.tsv" "$AO_MR_DIR/codex/delivered/log.tsv" "$AO_STATE/mailroom-probe.tsv"; do
    printf 'PART\n' >>"$_pt"
    [ ! -f "$_f" ] || cat "$_f" >>"$_pt"
  done
  awk -F '\t' -v cut="$_cut" -v h="$_h" -v wc="$_wc" -v wx="$_wx" '
    function med(side,   n, i, j, t, a) {
      n = lat_n[side]
      if (n == 0) return "n/a"
      for (i = 1; i <= n; i++) a[i] = lat[side, i]
      for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
      return a[int((n + 1) / 2)] "s"
    }
    $0 == "PART" { part++; next }
    part == 1 {
      if ($3 == "ring") ring_at[$5] = $1
      if ($1 >= cut) cnt[$4, $3]++
      next
    }
    part == 2 || part == 3 {
      side = (part == 2) ? "claude" : "codex"
      if ($2 < cut || $5 == "echo") next
      by[side, $4]++
      if ($6 == "unknown") unk[side]++
      if (($3 in ring_at) && $2 >= ring_at[$3]) lat[side, ++lat_n[side]] = $2 - ring_at[$3]
      next
    }
    part == 4 {
      if ($2 < cut) next
      if ($4 == "ok") pok[$3]++; else pfail[$3]++
    }
    END {
      printf "Mailroom, last %s h. ", h
      printf "Claude: rings %d; delivered by bridge %d, by fallback %d (failed %d); median ring-to-delivery %s. ", \
        cnt["claude", "ring"], by["claude", "bridge"], by["claude", "fallback"], cnt["claude", "fallback-failed"], med("claude")
      printf "Codex: rings %d; delivered by watcher %d (outcome unknown %d), queued direct %d (failed %d); median ring-to-delivery %s. ", \
        cnt["codex", "ring"], by["codex", "watcher"], unk["codex"], by["codex", "queue-direct"], cnt["codex", "queue-direct-failed"], med("codex")
      printf "Bridges down: Claude %d, Codex %d; re-arms sent: Claude %d, Codex %d (failed %d). ", \
        cnt["claude", "bridge-down"], cnt["codex", "bridge-down"], cnt["claude", "rearm"], cnt["codex", "rearm"], \
        cnt["claude", "rearm-failed"] + cnt["codex", "rearm-failed"]
      printf "Alarms: Claude %d, Codex %d. Waiting now: Claude %d, Codex %d. ", cnt["claude", "alarm"], cnt["codex", "alarm"], wc, wx
      printf "Hourly probes ok/fail: Claude %d/%d, Codex %d/%d.\n", pok["claude"], pfail["claude"], pok["codex"], pfail["codex"]
    }' "$_pt"
}

# ---------------------------------------------------------------- arm

mr_arm_codex() {
  if ao_mr_watcher_up codex; then
    echo "armed: the watcher's heartbeat is fresh and its process is alive"
    exit 0
  fi
  _node=$(ao_cfg_path bridge_codex_node '')
  _server=$(ao_cfg_path bridge_codex_server '')
  [ -n "$_node" ] && [ -x "$_node" ] || ao_die "$AO_E_USAGE" "bridge_codex_node must name the desktop app's bundled node (docs/mailroom.md)"
  [ -n "$_server" ] && [ -r "$_server" ] || ao_die "$AO_E_USAGE" "bridge_codex_server must name the app's codex-app-tools server.mjs (docs/mailroom.md)"
  mkdir -p "$AO_MR_DIR/codex/delivered" || ao_die "$AO_E_FAIL" "cannot create $AO_MR_DIR/codex"
  exec "$_node" "$AO_SCRIPTS/mailroom-codex-watcher.cjs" --dir "$AO_MR_DIR/codex" --server "$_server"
}

main() {
  case ${1-} in
    -h | --help) ao_usage; exit 0 ;;
    '') ao_usage; exit "$AO_E_USAGE" ;;
  esac
  cmd=$1
  shift
  ao_load
  ao_mr_init
  case $cmd in
    status) mr_status ;;
    cycle) mr_cycle ;;
    supervise) mr_supervise "$@" ;;
    wait) mr_wait "$@" ;;
    file) mr_file "$@" ;;
    metrics) mr_metrics "$@" ;;
    arm-codex) mr_arm_codex ;;
    *) ao_die "$AO_E_USAGE" "unknown command '$cmd' (see --help)" ;;
  esac
}

main "$@"
