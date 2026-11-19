#!/bin/sh
# mailroom.sh - EXPERIMENTAL: the cross-app mailroom's helpers.
#
# Usage: mailroom.sh status
#        mailroom.sh cycle
#        mailroom.sh supervise [--dry-run]
#        mailroom.sh wait claude
#        mailroom.sh file claude|codex RING... [--tier T] [--mode M]
#                         [--status S] [--step STEP] [--wait]
#        mailroom.sh metrics [HOURS]
#        mailroom.sh arm-codex
#
# One rule: the relay routes, the bridges deliver, and a model-free
# supervisor keeps both bridges armed. Same-app messages go direct with the
# app's own tools; the mailroom carries only cross-app messages and notes
# from scripts. Every delivery walks a degradation ladder (tier 1 model-free,
# tier 2 a bridge model turn, tier 3 headless or CLI queue, tier 4 an alarm
# and then a push to the owner): it gets slower, never stops, and each drop
# is logged and flagged once per cause. Lanes are never pre-woken. See
# docs/mailroom.md.
#
# status     Per side: watcher state, first tier and its health, waiting
#            rings (count, oldest age), the last delivery. Read-only.
# cycle      What the relay unit runs: relay.sh, then supervise, each under
#            its own lock (fallbacks never hold the relay lock).
# supervise  The supervisor (lib/mailroom.sh ao_mr_supervise): the timed
#            tiers, re-arms after app restarts and reboots, the version
#            fingerprint and canaries, once-per-cause degradation alarms and
#            tier 4. No model runs unless something is down or stuck.
#            Paused while <state_dir>/mailroom-pause holds an unexpired hold
#            (owner=, until=; see lane.sh hold).
# wait       For the Claude bridge's background task: a kqueue push watch
#            (macOS), no polling. With bridge_claude_t1=socket it delivers
#            rings to warm sessions itself (tier 1) and only exits for the
#            rest; otherwise it exits as soon as rings wait. Either way it
#            claims each ring it leaves to the bridge into .watcher/handing/
#            and prints it as `=== <name>` and its body. Exit 2 where no push
#            watch is available; 3 when another watcher is armed.
# file       For a bridge after it handed rings off: move each (from the
#            watcher's handing/ folder, or waiting) to delivered/ and log it
#            (default --tier t2-bridge --mode send --status ok; canaries are
#            logged with mode canary). --wait then becomes `wait`, so one
#            background command files, logs and re-arms. Exit 1 if a ring is
#            no longer waiting (the others are filed).
# metrics    One paragraph for the last HOURS (default 24): per side, rings,
#            the share of deliveries per tier with p50/p90 latency, the
#            first tier's health, fallbacks, re-arms, alarms, pushes,
#            canaries and waiting rings. Read-only.
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
    for _r in "$AO_MR_DIR/$_s"/*.md "$AO_MR_DIR/$_s/.watcher/handing"/*.md; do
      [ -f "$_r" ] || continue
      _n=$((_n + 1))
      _a=$(ao_mr_age "$_r")
      [ "$_a" -le "$_old" ] || _old=$_a
    done
    _w='no bridge row'
    if ao_mr_bridge "$_s"; then
      if ao_mr_watcher_up "$_s"; then _w='watcher armed'; else _w='watcher DOWN'; fi
    fi
    _ts=$(ao_mr_tier_status "$_s" | cut -f 1,2 | tr '\t' ' ')
    _last=$(tail -n 1 "$AO_MR_DIR/$_s/delivered/log.tsv" 2>/dev/null | cut -f 1,4,5,7 | tr '\t' ' ')
    printf '%s: %s; first tier %s (%s); waiting %s (oldest %ss); last delivery: %s\n' \
      "$_s" "$_w" "$(ao_mr_first_tier "$_s")" "$_ts" "$_n" "$_old" "${_last:-none}"
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
  if ao_hold_active "$AO_STATE/mailroom-pause"; then
    ao_msg "paused by $AO_STATE/mailroom-pause (until $AO_H_UNTIL, owner $AO_H_OWNER)"
    exit 0
  fi
  ao_lock mailroom || { ao_msg "another supervisor is running; skipping"; exit "$AO_E_BUSY"; }
  ao_mr_supervise "$_dry" || exit "$AO_E_FAIL"
}

# mr_targets FILE  The sessions tier 1 may send to: the registry's
# addressable Claude rows (the bridges excluded).
_mr_target_cb() {
  ! ao_is_bridge_key "$OP_KEY" || return 0
  [ "$OP_CLIENT" = claude ] && ao_mr_addressable "$OP_SID" || return 0
  printf '%s\n' "$OP_SID" >>"$_mr_tf"
}
mr_targets() {
  _mr_tf=$1
  : >"$_mr_tf"
  [ ! -r "$AO_REGISTRY" ] || ao_registry_each _mr_target_cb
}

mr_wait() {
  [ "${1-}" = claude ] || ao_die "$AO_E_USAGE" "usage: mailroom.sh wait claude (the Codex side uses arm-codex)"
  mkdir -p "$AO_MR_DIR/claude/.watcher" || ao_die "$AO_E_FAIL" "cannot create $AO_MR_DIR/claude"
  [ -x /usr/bin/python3 ] || ao_die "$AO_E_USAGE" "/usr/bin/python3 not found: no push watch here"
  if [ "$AO_MR_T1" = socket ] && ao_mr_bridge claude; then
    _tf=$AO_MR_DIR/claude/.watcher/targets
    mr_targets "$_tf.tmp"
    mv -f "$_tf.tmp" "$_tf" || ao_die "$AO_E_FAIL" "cannot write $_tf"
    rm -rf "$AO_TMPDIR"
    exec /usr/bin/python3 -I "$AO_SCRIPTS/mailroom-wait.py" --t1 "$AO_MR_DIR/claude" "$_tf" "$MR_B_SID"
  fi
  rm -rf "$AO_TMPDIR"
  exec /usr/bin/python3 -I "$AO_SCRIPTS/mailroom-wait.py" "$AO_MR_DIR/claude"
}

mr_word() {
  ao_is_name "$2" || ao_die "$AO_E_USAGE" "$1 takes a word, got '$2'"
}

mr_file() {
  mr_side "${1-}"
  _side=$1
  shift
  _tier=t2-bridge _mode=send _status=ok _step='' _wait='' _rings=$(ao_tmp rings)
  while [ $# -gt 0 ]; do
    case $1 in
      --tier | --mode | --status | --step)
        [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "$1 needs a value"
        mr_word "$1" "$2"
        case $1 in --tier) _tier=$2 ;; --mode) _mode=$2 ;; --status) _status=$2 ;; --step) _step=$2 ;; esac
        shift ;;
      --wait) _wait=1 ;;
      -*) ao_die "$AO_E_USAGE" "unknown option '$1'" ;;
      *)
        _r=${1##*/}
        case $_r in *.md) ao_is_name "$_r" ;; *) false ;; esac || ao_die "$AO_E_USAGE" "not a ring name: $_r"
        printf '%s\n' "$_r" >>"$_rings" ;;
    esac
    shift
  done
  case $_tier in t1-socket | t1-native | t2-bridge | t3-headless | t3-cli-queue | none) ;;
    *) ao_die "$AO_E_USAGE" "--tier must be t1-socket, t1-native, t2-bridge, t3-headless, t3-cli-queue or none" ;; esac
  [ -s "$_rings" ] || [ -n "$_wait" ] || ao_die "$AO_E_USAGE" "usage: mailroom.sh file claude|codex RING... [--tier T] [--mode M] [--status S] [--step STEP] [--wait]"
  _bad=0
  while IFS= read -r _r; do
    _m=$_mode
    case $_r in echo--canary-*) _m='canary' ;; echo--*) _m='echo' ;; esac
    if ao_mr_file "$_side" "$_r" "$_tier" "$_m" "$_status" "$AO_MR_DIR/$_side/.watcher/handing" "$_step" ||
      ao_mr_file "$_side" "$_r" "$_tier" "$_m" "$_status" "" "$_step"; then
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

mr_metrics() {
  _h=${1:-24}
  ao_is_uint "$_h" && [ "$_h" -gt 0 ] || ao_die "$AO_E_USAGE" "HOURS must be a positive integer"
  _cut=$((AO_T_EPOCH - _h * 3600))
  _wc=0 _wx=0
  for _r in "$AO_MR_DIR/claude"/*.md "$AO_MR_DIR/claude/.watcher/handing"/*.md; do [ -f "$_r" ] && _wc=$((_wc + 1)); done
  for _r in "$AO_MR_DIR/codex"/*.md; do [ -f "$_r" ] && _wx=$((_wx + 1)); done
  _sc=$(ao_mr_tier_status claude | cut -f 1,2 | tr '\t' ' ')
  _sx=$(ao_mr_tier_status codex | cut -f 1,2 | tr '\t' ' ')
  # Each input is tagged by position (empty files count too), so the three
  # parts never mix.
  _pt=$(ao_tmp parts)
  for _f in "$AO_MR_LOG" "$AO_MR_DIR/claude/delivered/log.tsv" "$AO_MR_DIR/codex/delivered/log.tsv"; do
    printf 'PART\n' >>"$_pt"
    [ ! -f "$_f" ] || cat "$_f" >>"$_pt"
  done
  awk -F '\t' -v cut="$_cut" -v h="$_h" -v wc="$_wc" -v wx="$_wx" \
    -v fc="$(ao_mr_first_tier claude)" -v sc="$_sc" -v sx="$_sx" '
    function pct(key, p,   n, i, j, t, a, k) {
      n = lat_n[key]
      if (n == 0) return "n/a"
      for (i = 1; i <= n; i++) a[i] = lat[key, i]
      for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
      k = int((n - 1) * p + 0.5) + 1
      return sprintf("%.1fs", a[k] / 1000)
    }
    function tiers(side, list,   n, i, t, s, out, sep) {
      n = split(list, t, " ")
      out = ""; sep = ""
      for (i = 1; i <= n; i++) {
        s = by[side, t[i]] + 0
        if (s == 0) { out = out sep t[i] " 0"; sep = ", "; continue }
        out = out sep sprintf("%s %d%% (%d; p50 %s, p90 %s)", t[i], int(100 * s / tot[side] + 0.5), s, pct(side SUBSEP t[i], 0.5), pct(side SUBSEP t[i], 0.9))
        sep = ", "
      }
      return out
    }
    $0 == "PART" { part++; next }
    part == 1 { if ($1 >= cut) cnt[$4, $3]++; next }
    part == 2 || part == 3 {
      side = (part == 2) ? "claude" : "codex"
      if ($2 < cut || $5 == "canary" || $5 == "echo" || $5 == "rerouted" || $4 == "none") next
      if ($5 == "resolve") { if ($4 == "t1-native" && $6 == "ok") late[side]++; else esc[side]++; next }
      tot[side]++; by[side, $4]++
      if ($6 == "unknown") unk[side]++
      if ($7 ~ /^[0-9]+$/) lat[side SUBSEP $4, ++lat_n[side SUBSEP $4]] = $7 + 0
      next
    }
    END {
      printf "Mailroom, last %s h. ", h
      printf "Claude: rings %d; delivered %d: %s; first tier %s: %s; tier-3 failures %d. ", \
        cnt["claude", "ring"], tot["claude"], tiers("claude", (fc == "t1-socket" ? "t1-socket " : "") "t2-bridge t3-headless"), fc, sc, cnt["claude", "fallback-failed"]
      printf "Codex: rings %d; delivered %d: %s; outcome unknown %d (arrived late %d, escalated once absent %d); first tier t1-native: %s; tier-3 failures %d; threads marked unresponsive %d. ", \
        cnt["codex", "ring"], tot["codex"], tiers("codex", "t1-native t2-bridge t3-cli-queue"), unk["codex"], late["codex"], esc["codex"], sx, cnt["codex", "queue-direct-failed"], cnt["codex", "thread-unhealthy"]
      printf "Bridges down: Claude %d, Codex %d; re-arms: Claude %d, Codex %d (failed %d). ", \
        cnt["claude", "bridge-down"], cnt["codex", "bridge-down"], cnt["claude", "rearm"], cnt["codex", "rearm"], \
        cnt["claude", "rearm-failed"] + cnt["codex", "rearm-failed"]
      printf "Canaries ok/failed: Claude %d/%d, Codex %d/%d. ", cnt["claude", "canary-ok"], cnt["claude", "canary-failed"], cnt["codex", "canary-ok"], cnt["codex", "canary-failed"]
      printf "Alarms: Claude %d, Codex %d; degraded flags: Claude %d, Codex %d; pushes to the owner %d (failed %d). ", \
        cnt["claude", "alarm"], cnt["codex", "alarm"], cnt["claude", "degraded"], cnt["codex", "degraded"], cnt["-", "push"], cnt["-", "push-failed"]
      printf "Waiting now: Claude %d, Codex %d.\n", wc, wx
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
  # One watcher: a kernel lock the watcher keeps through exec, released
  # when it dies however it dies.
  ao_lock codex-watcher || { echo "armed: another watcher holds the lock"; exit 0; }
  rm -rf "$AO_TMPDIR"
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
