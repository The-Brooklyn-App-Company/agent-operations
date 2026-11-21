# shellcheck shell=sh disable=SC2034
# (SC2034: AO_MR_* globals set here are read by relay.sh and mailroom.sh.)
# mailroom.sh - the cross-app mailroom: rings, the delivered log, events, the
# degradation ladders' timed tiers and the bridge supervisor. EXPERIMENTAL
# since 0.3.1 (docs/mailroom.md).
#
# Sourced after core.sh, registry.sh and vendor.sh, and after ao_load.
#
# One rule: the relay routes, the bridges deliver, and a model-free
# supervisor keeps both bridges armed. Every delivery walks a ladder and
# never stops at a broken tier; it only gets slower, and the drop is logged
# per delivery and flagged once per cause:
#   tier  Claude target                     Codex target
#   1     t1-socket: the bridge's watcher   t1-native: the bridge-owned
#         writes to a warm session's        watcher sends natively; steer at
#         socket (opt-in,                   once, queue on the target's
#         bridge_claude_t1=socket)          turn-complete event
#   2     t2-bridge: the bridge model       t2-bridge: a re-arm turn of the
#         sends with SendMessage (cold      bridge chat; the watcher's
#         targets, misses)                  catch-up delivers
#   3     t3-headless: one confined         t3-cli-queue: one CLI queue
#         headless run (3 min)              straight to the target (3 min)
#   4     an alarm to the Oracle (10 min); a push to the owner when the
#         Oracle has not received it in 15 min
#
# A ring is one file per hand-off in <bridge_dir>/<client>/, written
# atomically by the relay (or a doorbell): its body is the relay's
# fixed-shape pointer, never note text. Names:
#   claude  <session>--<key>-<stamp>-<rand>.md
#   codex   <thread>--<key>-<stamp>-<rand>--<steer|queue>.md
#   (a doorbell's key is `.doorbell`, never an operator key)
#   canary  echo--canary-<stamp>.md (codex: ...--queue.md): the supervisor's
#           test of a side's first tier after a version change
# Whatever delivers a ring files it in delivered/ and appends one row to
# delivered/log.tsv, one format for both sides:
#   ISO-time epoch ring tier mode status latency-ms step   (TAB-separated)
# tier is one of the names above (none for a reroute or an old probe);
# step names why an earlier tier missed (- when none).
# The bridges are registry rows with the reserved keys mailroom-claude and
# mailroom-codex: the one file every script reads for their ids.

# Timings, in seconds. Fixed on purpose: fewer knobs, one documented design.
AO_MR_CLAUDE_FALLBACK=180 # a Claude ring this old gets one tier-3 delivery
AO_MR_CODEX_FALLBACK=180  # a Codex ring this old is queued straight to the target
AO_MR_ALARM=600           # a ring still waiting this long alarms once
AO_MR_PUSH=900            # an alarm the Oracle has not received this long pushes the owner
AO_MR_RETRY=300           # spacing between fallback attempts for one ring
AO_MR_HEARTBEAT=180       # a Codex watcher heartbeat older than this is stale
AO_MR_HOLD_CAP=660        # a watcher's queue hold older than this is ignored
AO_MR_REARM_GRACE=120     # a dead Claude watcher this long without re-arming is down
AO_MR_REARM_EVERY=3600    # re-arm per clock hour where the app pid is unknown; relaunch spacing
AO_MR_CANARY_WAIT=600     # a canary not filed by its first tier this long fails
AO_MR_T1_STRANDED=120     # a tier-1 claim this old with its watcher gone is settled
AO_MR_WAKE_GAP=2          # seconds between waking a session and returning to the Oracle
AO_MR_ABSENT=300          # an unknown send whose ring is still absent from the target's record this long escalates once
AO_MR_SICK=2              # unknown sends in a row to one Codex thread, while others deliver, mark it unresponsive
AO_MR_SICK_WINDOW=7200    # ...counted over this many seconds of the delivered log
# The desktop apps (public bundle ids), for the re-arm-per-app-process rule.
AO_MR_APP_CLAUDE=com.anthropic.claudefordesktop
AO_MR_APP_CODEX=com.openai.codex
# Steps that are not a failure of a side's first tier: a cold target, a
# switched-off tier, the rate limit, a queue ring whose target stayed busy,
# and rings that waited while a watcher was down (the bridge-down alarm
# reports that once).
AO_MR_NEUTRAL='- cold-target kill-switch rate-limit not-mailroom queue-cap t1-off held watcher-down'

# ao_mr_init  Read the mailroom settings: AO_MR_ON (on|off), AO_MR_DIR,
# AO_MR_LOG and AO_MR_T1 (socket|off, the Claude side's first tier).
ao_mr_init() {
  AO_MR_ON=$(ao_cfg relay_bridge on)
  case $AO_MR_ON in on | off) ;; *) ao_die "$AO_E_USAGE" "relay_bridge must be on or off" ;; esac
  AO_MR_T1=$(ao_cfg bridge_claude_t1 off)
  case $AO_MR_T1 in socket | off) ;; *) ao_die "$AO_E_USAGE" "bridge_claude_t1 must be socket or off" ;; esac
  AO_MR_DIR=$(ao_cfg_path bridge_dir "$AO_INBOX/.mailroom")
  AO_MR_LOG=$AO_STATE/mailroom.tsv
}

# ao_mr_first_tier SIDE  The tier a healthy SIDE delivers by.
ao_mr_first_tier() {
  if [ "$1" = codex ]; then echo t1-native
  elif [ "$AO_MR_T1" = socket ]; then echo t1-socket
  else echo t2-bridge; fi
}

# ao_mr_bridge CLIENT  Set MR_B_NAME, MR_B_HOME and MR_B_SID from the
# registry row mailroom-CLIENT; returns 1 when there is no row or no
# session id yet.
ao_mr_bridge() {
  MR_B_NAME='' MR_B_HOME='' MR_B_SID=''
  [ -r "$AO_REGISTRY" ] || return 1
  _mr_row=$(awk -F'\t' -v k="mailroom-$1" '$1 == k { print; exit }' "$AO_REGISTRY")
  [ -n "$_mr_row" ] || return 1
  MR_B_NAME=$(printf '%s\n' "$_mr_row" | cut -f 2)
  MR_B_HOME=$(ao_expand_path "$(printf '%s\n' "$_mr_row" | cut -f 3)" /)
  MR_B_SID=$(printf '%s\n' "$_mr_row" | cut -f 4)
  case $MR_B_SID in '' | - | pending) MR_B_SID=''; return 1 ;; esac
  [ "$1" != codex ] || ao_codex_thread_addressable "$MR_B_SID" || { MR_B_SID=''; return 1; }
  return 0
}

# ao_mr_addressable SESSION  True when SESSION can lead a ring name: a safe
# name with no `--` (the separator).
ao_mr_addressable() {
  ao_is_name "$1" || return 1
  case $1 in *--* | echo) return 1 ;; esac
  return 0
}

# ao_mr_event EVENT SIDE RING DETAIL  Append one line to the event log:
#   epoch <TAB> ISO-time <TAB> event <TAB> side <TAB> ring <TAB> detail
ao_mr_event() {
  mkdir -p "$AO_STATE" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$AO_T_EPOCH" "$AO_T_ISO" "$1" "$2" "$3" \
    "$(printf '%s' "$4" | tr '\t\n' '  ')" >>"$AO_MR_LOG" 2>/dev/null ||
    ao_warn "cannot write $AO_MR_LOG"
}

# ao_mr_mode FILE KEY  Print steer when the sender's original name of any
# note listed in FILE (archived as <stamp>-KEY-<name>) says urgent or steer
# (any case), else queue. The archive prefix never counts.
ao_mr_mode() {
  while IFS= read -r _mr_l; do
    _mr_l=${_mr_l#*-"$2"-}
    case $_mr_l in *[Uu][Rr][Gg][Ee][Nn][Tt]* | *[Ss][Tt][Ee][Ee][Rr]*) echo steer; return 0 ;; esac
  done <"$1"
  echo queue
}

# ao_mr_ring CLIENT SESSION KEY MODE  Write stdin as a new ring and print its
# path. The name carries the stamp and six random hex digits, so it is never
# reused while an earlier ring of the same name is still being sent or
# filed; a taken name still gets -2, -3... before the suffix. KEY is an
# operator key, or `.doorbell` for a doorbell (never an operator key).
ao_mr_ring() {
  _mr_dir=$AO_MR_DIR/$1
  _mr_ext=.md
  [ "$1" != codex ] || _mr_ext=--$4.md
  mkdir -p "$_mr_dir" || return 1
  _mr_rand=$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')
  _mr_tmp=$(mktemp "$_mr_dir/.tmp.XXXXXX") || return 1
  if ! cat >"$_mr_tmp" || ! ao_place "$_mr_tmp" "$_mr_dir/$2--$3-$AO_T_STAMP-$_mr_rand" "$_mr_ext"; then
    rm -f "$_mr_tmp"
    return 1
  fi
}

# ao_mr_file SIDE RING TIER MODE [STATUS [FROM [STEP]]]  Move a ring
# (waiting, or in folder FROM) to delivered/ and append its row to
# delivered/log.tsv. The latency runs from the ring's publication: the
# watcher's record in .watcher/meta/RING (`publish-ms <TAB> step`) when it
# claimed the ring, else the file's time. STEP (default: the record's, or -)
# says why an earlier tier missed. Fails if the ring is gone.
ao_mr_file() {
  _mr_src=${6:-$AO_MR_DIR/$1}/$2
  [ -f "$_mr_src" ] || return 1
  _mr_meta=$AO_MR_DIR/$1/.watcher/meta/$2
  _mr_pub='' _mr_mstep=''
  [ ! -f "$_mr_meta" ] || IFS="$AO_TAB" read -r _mr_pub _mr_mstep <"$_mr_meta"
  if ao_is_uint "${_mr_pub:-x}"; then
    _mr_lat=$((AO_T_EPOCH * 1000 - _mr_pub))
  else
    _mr_lat=$(($(ao_mr_age "$_mr_src") * 1000))
  fi
  [ "$_mr_lat" -ge 0 ] || _mr_lat=0
  _mr_step=${7:-${_mr_mstep:--}}
  mkdir -p "$AO_MR_DIR/$1/delivered" || return 1
  mv -f "$_mr_src" "$AO_MR_DIR/$1/delivered/$2" || return 1
  rm -f "$_mr_meta"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$AO_T_ISO" "$AO_T_EPOCH" "$2" "$3" "$4" "${5:-ok}" "$_mr_lat" \
    "$(printf '%s' "$_mr_step" | tr -c 'A-Za-z0-9._-' '-' | cut -c 1-40)" >>"$AO_MR_DIR/$1/delivered/log.tsv"
}

# ao_mr_row SIDE RING TIER MODE STATUS LATENCY-MS STEP  Append one row to
# SIDE's delivered log without moving anything (a resolution of a ring
# already filed, mode `resolve`).
ao_mr_row() {
  mkdir -p "$AO_MR_DIR/$1/delivered" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$AO_T_ISO" "$AO_T_EPOCH" "$2" "$3" "$4" "$5" "$6" \
    "$(printf '%s' "$7" | tr -c 'A-Za-z0-9._-' '-' | cut -c 1-40)" >>"$AO_MR_DIR/$1/delivered/log.tsv"
}

# ao_mr_rollout THREAD  The Codex thread's newest rollout file (the app's
# own record of the thread, read-only), or nothing.
ao_mr_rollout() {
  _mr_rr=${CODEX_HOME:-$HOME/.codex}/sessions
  [ -d "$_mr_rr" ] && ao_is_name "$1" || return 0
  find "$_mr_rr" -type f -name "rollout-*-$1.jsonl" 2>/dev/null | sort | tail -n 1
}

# ao_mr_age FILE  Print FILE's age in seconds (0 when in the future).
ao_mr_age() {
  _mr_m=$(ao_mtime "$1" 2>/dev/null) || { echo 0; return; }
  _mr_a=$((AO_T_EPOCH - _mr_m))
  [ "$_mr_a" -ge 0 ] || _mr_a=0
  echo "$_mr_a"
}

# _ao_mr_pid_alive FILE FIELD  True when field FIELD (1-based) of FILE's
# first line is the pid of a live process.
_ao_mr_pid_alive() {
  _mr_p=$(head -n 1 "$1" 2>/dev/null | cut -d ' ' -f "$2")
  ao_is_uint "${_mr_p:-x}" && [ "$_mr_p" -gt 1 ] && kill -0 "$_mr_p" 2>/dev/null
}

# ao_mr_heartbeat_fresh  True when the Codex watcher's heartbeat is fresh.
ao_mr_heartbeat_fresh() {
  _mr_hb=$AO_MR_DIR/codex/.watcher/heartbeat
  [ -f "$_mr_hb" ] && [ "$(ao_mr_age "$_mr_hb")" -lt "$AO_MR_HEARTBEAT" ]
}

# ao_mr_watcher_up SIDE  True when SIDE's watcher is armed: Codex, a fresh
# heartbeat whose pid lives; Claude, a live pid in .watcher/pid, or one that
# ended less than AO_MR_REARM_GRACE ago (the bridge re-arms after each ring).
ao_mr_watcher_up() {
  if [ "$1" = codex ]; then
    ao_mr_heartbeat_fresh && _ao_mr_pid_alive "$AO_MR_DIR/codex/.watcher/heartbeat" 2
    return
  fi
  _mr_pf=$AO_MR_DIR/claude/.watcher/pid
  [ -f "$_mr_pf" ] || return 1
  _ao_mr_pid_alive "$_mr_pf" 1 || [ "$(ao_mr_age "$_mr_pf")" -lt "$AO_MR_REARM_GRACE" ]
}

# ao_mr_held RING  True when a live Codex watcher is holding this queue ring
# until its target's turn completes (the hold file holds the epoch it
# started).
ao_mr_held() {
  _mr_h=$AO_MR_DIR/codex/.watcher/holding/$1
  [ -f "$_mr_h" ] && ao_mr_heartbeat_fresh || return 1
  read -r _mr_since <"$_mr_h" 2>/dev/null || return 1
  ao_is_uint "${_mr_since:-x}" || return 1
  [ $((AO_T_EPOCH - _mr_since)) -lt "$AO_MR_HOLD_CAP" ]
}

# _ao_mr_marker KIND NAME  Path of a supervisor marker in state.
_ao_mr_marker() { printf '%s/mailroom/%s/%s\n' "$AO_STATE" "$1" "$2"; }

# _ao_mr_touch FILE [TEXT]  Create a marker (with one line of TEXT).
_ao_mr_touch() {
  { mkdir -p "${1%/*}" && printf '%s\n' "${2-}" >"$1"; } || { ao_warn "cannot record $1"; return 1; }
}

# _ao_mr_attempt_due KIND RING  True when another fallback attempt is allowed:
# fewer than relay_max_attempts so far, the last at least AO_MR_RETRY ago.
_ao_mr_attempt_due() {
  _mr_mk=$(_ao_mr_marker "$1" "$2")
  [ -f "$_mr_mk" ] || return 0
  read -r _mr_n _mr_at <"$_mr_mk" 2>/dev/null || return 0
  ao_is_uint "${_mr_n:-x}" && ao_is_uint "${_mr_at:-x}" || return 0
  [ "$_mr_n" -lt "$AO_MR_MAX" ] && [ $((AO_T_EPOCH - _mr_at)) -ge "$AO_MR_RETRY" ]
}

_ao_mr_attempt_count() {
  _mr_mk=$(_ao_mr_marker "$1" "$2")
  _mr_n=0
  [ ! -f "$_mr_mk" ] || read -r _mr_n _mr_at <"$_mr_mk" 2>/dev/null
  ao_is_uint "${_mr_n:-x}" || _mr_n=0
  if ! { mkdir -p "${_mr_mk%/*}" && printf '%s %s\n' "$((_mr_n + 1))" "$AO_T_EPOCH" | ao_write_atomic "$_mr_mk"; }; then
    ao_warn "cannot record $_mr_mk"
  fi
}

# _ao_mr_name_of SESSION  Set _mr_name to the registry name of the row
# whose session is SESSION (empty when none).
_ao_mr_name_cb() { [ -n "$_mr_name" ] || [ "$OP_SID" != "$_mr_want" ] || _mr_name=$OP_NAME; }
_ao_mr_name_of() {
  _mr_name='' _mr_want=$1
  ao_registry_each _ao_mr_name_cb
}

# _ao_mr_oracle_sid  Print the Oracle's session id when its row runs on
# Claude with a session, else nothing.
_ao_mr_oracle_sid() {
  [ -r "$AO_REGISTRY" ] || return 0
  awk -F'\t' -v k="$AO_ORACLE_KEY" -v d="$(ao_cfg relay_default claude)" '
    $1 == k { c = ($5 == "" ? d : $5); if (c == "claude" && $4 != "" && $4 != "-" && $4 != "pending") print $4; exit }' "$AO_REGISTRY"
}

# _ao_mr_open_link SESSION  Open the profile's wake_link for SESSION in the
# background (`open -g`). The link format is the desktop app's own and
# undocumented, so the kit ships none: wake_link names it, with {session}
# where the id goes.
_ao_mr_open_link() {
  _mr_wl=$(ao_cfg wake_link '')
  [ -n "$_mr_wl" ] && ao_is_name "$1" && command -v open >/dev/null 2>&1 || return 1
  _mr_url=$(printf '%s\n' "$_mr_wl" | sed "s|{session}|$1|g")
  open -g "$_mr_url" </dev/null >/dev/null 2>&1
}

# _ao_mr_wake CLIENT SESSION  Give a cold Claude session a process to
# receive: the optional hooks/wake executable (`wake <client> <session>`,
# 30 s, output to the log), else the profile's wake_link, then, after
# AO_MR_WAKE_GAP seconds, the Oracle's own link, so the app's window lands
# back on the Oracle session instead of staying on the woken one.
_ao_mr_wake() {
  if [ -x "$AO_HOOKS/wake" ]; then
    ao_timeout 30 "$AO_HOOKS/wake" "$1" "$2" </dev/null >>"$AO_STATE/hooks.log" 2>&1 ||
      ao_mr_event wake-failed "$1" - "hooks/wake exit $?"
    return 0
  fi
  [ "$1" = claude ] || return 0
  _ao_mr_open_link "$2" || return 0
  ao_mr_event wake "$1" - "opened the session link for $2"
  _mr_osid=$(_ao_mr_oracle_sid)
  [ -n "$_mr_osid" ] && [ "$_mr_osid" != "$2" ] || return 0
  sleep "$AO_MR_WAKE_GAP"
  _ao_mr_open_link "$_mr_osid" || ao_mr_event wake-failed claude - "could not return to the Oracle session"
}

# _ao_mr_deliver CLIENT NAME SESSION MESSAGE OUT ID  One direct delivery
# through the relay transport, in a subshell so a broken configuration
# cannot stop the supervisor.
_ao_mr_deliver() {
  (ao_role_load "relay_$1" "$1" >"$5" 2>&1 && ao_role_deliver "$2" "$3" "$4" "$5" "$6")
}

# _ao_mr_push TEXT  Tier 4's last step: reach the owner directly, through
# the optional hooks/push executable (`push <text>`), else the chat
# adapter's `notify high`. Returns 1 when neither is configured or both
# fail.
_ao_mr_push() {
  if [ -x "$AO_HOOKS/push" ]; then
    ao_timeout 30 "$AO_HOOKS/push" "$1" </dev/null >>"$AO_STATE/hooks.log" 2>&1 && return 0
  fi
  _mr_chat=$(ao_cfg chat none)
  case $_mr_chat in none | '') return 1 ;; esac
  _mr_cp=$(ao_expand_path "$_mr_chat")
  [ -x "$_mr_cp" ] || return 1
  ao_timeout 30 "$_mr_cp" notify high "$1" </dev/null >/dev/null 2>&1
}

# _ao_mr_alarm SLUG TEXT  One note to the Oracle, tracked until a ring to
# the Oracle is delivered (_ao_mr_tier4). When the note cannot even be
# written, the owner is pushed at once.
_ao_mr_alarm() {
  if _mr_np=$(printf '%s\n' "$2" | (ao_inbox_put "$AO_ORACLE_KEY" "$1") 2>/dev/null) && [ -n "$_mr_np" ]; then
    _mr_ap=$(_ao_mr_marker alarm-pending "$1")
    [ -f "$_mr_ap" ] || _ao_mr_touch "$_mr_ap" "$AO_T_EPOCH ${_mr_np##*/}"
    return 0
  fi
  _ao_mr_push "$2" || { ao_mr_event push-failed - - "alarm note and push both failed: $1"; return 1; }
  ao_mr_event push - - "alarm note failed; pushed the owner: $1"
}

# ao_mr_supervise [--dry-run]  The model-free supervisor: run by
# `mailroom.sh supervise` (from the relay unit every minute, at login, and
# from the tick), outside the relay lock. It uses a model only when
# something is down, and then once. In order:
#   1. Rings that wait: tier 3 at 3 minutes, one alarm at 10 (rings to the
#      Oracle itself are tier 4's job, so an alarm never breeds an alarm).
#   2. Tier 4: an alarm whose ring the Oracle has not received in 15 min
#      pushes the owner, once per outage.
#   3. Bridges: one re-arm per app process (Claude: wake, return to the
#      Oracle, a headless re-arm), an app that is not running is opened,
#      then one alarm.
#   4. Codex threads: an unconfirmed send is reconciled against the
#      target's rollout (late receipt, or one CLI queue once its absence is
#      confirmed); a thread that keeps timing out while others deliver is
#      marked unresponsive and its recovery routine opens and advances.
#   5. Degradation: a version fingerprint per side; on a change, one canary
#      through the side's first tier; one alarm per cause when the canary
#      fails or two warm deliveries in a row miss the first tier.
# A failed fallback is retried at most relay_max_attempts times, spaced
# AO_MR_RETRY apart. Returns 1 if anything failed.
ao_mr_supervise() {
  _mr_dry=${1-}
  _mr_fail=0
  AO_MR_MAX=$(ao_cfg_uint relay_max_attempts 3) || return "$AO_E_USAGE"
  _mr_out=$(ao_tmp mr-out) _mr_msg=$(ao_tmp mr-msg)
  _ao_mr_rings || _mr_fail=1
  [ -z "$_mr_dry" ] || return 0
  _ao_mr_tier4
  for _mr_side in claude codex; do
    _ao_mr_bridge_check "$_mr_side" || _mr_fail=1
  done
  _ao_mr_threads
  for _mr_side in claude codex; do
    _ao_mr_fingerprint "$_mr_side"
    _ao_mr_canary_check "$_mr_side"
    _ao_mr_degraded "$_mr_side"
  done
  # The hourly probes are retired (the fingerprint and canaries replace
  # them); their state is replaceable.
  rm -rf "$AO_STATE/mailroom-probe"
  _ao_mr_prune
  return "$_mr_fail"
}

# _ao_mr_claim  Take the current ring from where it waits (an atomic rename
# into .claimed/), so no watcher or bridge can send it meanwhile. Sets _mr_c
# to its claimed path; fails if someone else took it.
_ao_mr_claim() {
  _mr_cd=$AO_MR_DIR/$_mr_side/.claimed
  mkdir -p "$_mr_cd" || return 1
  _mr_c=$_mr_cd/$_mr_b
  mv "$_mr_r" "$_mr_c" 2>/dev/null
}

# _ao_mr_unclaim  Put a claimed ring back, for the next attempt.
_ao_mr_unclaim() {
  # link(2) refuses an existing name: a return never overwrites a ring.
  if ln "$_mr_c" "$_mr_r" 2>/dev/null; then rm -f "$_mr_c"; else ao_warn "cannot return $_mr_c"; fi
}

# _ao_mr_t1_stranded  Tier-1 claims a dead Claude watcher left: if the
# target's transcript already holds the session's receipt, the send went
# through and the ring is filed; otherwise it goes back to wait (never
# resent after a receipt).
_ao_mr_t1_stranded() {
  for _mr_c in "$AO_MR_DIR/claude/.watcher/t1"/*.md; do
    [ -f "$_mr_c" ] || continue
    ! ao_mr_watcher_up claude || [ "$(ao_mr_age "$_mr_c")" -ge "$AO_MR_T1_STRANDED" ] || continue
    _mr_b=${_mr_c##*/}
    _mr_tx=$(head -n 1 "$_mr_c.tx" 2>/dev/null)
    _mr_rc=3
    if [ -z "$_mr_tx" ]; then _mr_rc=1
    elif [ -x /usr/bin/python3 ]; then
      /usr/bin/python3 -I "$AO_SCRIPTS/mailroom-wait.py" --receipt "$_mr_tx" "$_mr_b" </dev/null >/dev/null 2>&1
      _mr_rc=$?
    fi
    if [ "$_mr_rc" -eq 0 ]; then
      ao_mr_file claude "$_mr_b" t1-socket send ok "${_mr_c%/*}" && ao_mr_event t1-settled claude "$_mr_b" "receipt found in the target's transcript"
    elif [ "$_mr_rc" -eq 1 ]; then
      # A claim with no transcript to check never had a send recorded (the
      # sidecar is written before the send); a readable transcript without
      # the receipt confirms absence. Either way the next tier may send it.
      if ln "$_mr_c" "$AO_MR_DIR/claude/$_mr_b" 2>/dev/null; then
        rm -f "$_mr_c"
        ao_mr_event t1-returned claude "$_mr_b" "no receipt in the target's transcript; back in the queue for the next tier"
      fi
    else
      # The transcript cannot be read: no evidence either way. Kept, never
      # resent; one alarm (K-28).
      _mr_am=$(_ao_mr_marker alarmed "t1-unknown-$_mr_b")
      if [ ! -f "$_mr_am" ] && _ao_mr_alarm "mailroom-unknown-claude" "Mailroom: $_mr_b was sent to a Claude session at tier 1 but the session's transcript cannot be read to confirm it; it is kept and not resent. Check the target session (docs/mailroom.md)."; then
        _ao_mr_touch "$_mr_am"
        ao_mr_event unknown claude "$_mr_b" "transcript unreadable; kept, not resent"
      fi
    fi
    [ -f "$_mr_c" ] || rm -f "$_mr_c.tx"
  done
}

_ao_mr_rings() {
  _mr_rf=0
  [ -n "$_mr_dry" ] || _ao_mr_t1_stranded
  for _mr_side in claude codex; do
    # A claim left by an interrupted run: the send may have happened, so it
    # is filed as unknown and never sent again (K-28).
    for _mr_c in "$AO_MR_DIR/$_mr_side/.claimed"/*.md; do
      [ -f "$_mr_c" ] || continue
      [ -n "$_mr_dry" ] && continue
      if [ "$_mr_side" = claude ]; then _mr_t=t3-headless; else _mr_t=t3-cli-queue; fi
      ao_mr_file "$_mr_side" "${_mr_c##*/}" "$_mr_t" - unknown "${_mr_c%/*}" interrupted || continue
      ao_mr_event unknown "$_mr_side" "${_mr_c##*/}" "interrupted fallback; not sent again"
      _ao_mr_alarm "mailroom-unknown-$_mr_side" "Mailroom: a fallback for ${_mr_c##*/} was interrupted; it may or may not have arrived and is not sent again. Check the target (docs/mailroom.md)." ||
        ao_warn "could not raise the unknown-delivery alarm"
    done
    # Unknown outcomes the Codex watcher recorded: reconciled against the
    # target's own record before anything is repeated (K-28).
    [ "$_mr_side" != codex ] || [ -n "$_mr_dry" ] || _ao_mr_unknowns || _mr_rf=1
    # A Codex send cut off with the watcher down may have landed: filed as
    # unknown and marked for the same reconciliation against the target's
    # rollout (_ao_mr_unknowns); never resent blindly.
    if [ "$_mr_side" = codex ] && [ -z "$_mr_dry" ] && ! ao_mr_watcher_up codex; then
      for _mr_c in "$AO_MR_DIR/codex/.watcher/sending"/*.md; do
        [ -f "$_mr_c" ] || continue
        ao_mr_file codex "${_mr_c##*/}" t1-native - unknown "${_mr_c%/*}" interrupted || continue
        _ao_mr_touch "$AO_MR_DIR/codex/.watcher/unknown/${_mr_c##*/}" ||
          ao_warn "could not mark ${_mr_c##*/} for reconciliation"
        ao_mr_event unknown codex "${_mr_c##*/}" "send interrupted with the watcher down; reconciled against the target's rollout"
      done
    fi
    # Claude rings the bridge's watcher claimed (handing/) count from the
    # claim: a bridge that does not file one is stuck, or its send failed.
    for _mr_r in "$AO_MR_DIR/$_mr_side"/*.md "$AO_MR_DIR/$_mr_side/.watcher/handing"/*.md; do
      [ -f "$_mr_r" ] || continue
      _mr_b=${_mr_r##*/}
      _mr_sid=${_mr_b%%--*}
      [ "$_mr_sid" != echo ] || continue
      _mr_age=$(ao_mr_age "$_mr_r")
      if [ -n "$_mr_dry" ]; then
        printf 'ring waiting %ss: %s/%s\n' "$_mr_age" "$_mr_side" "$_mr_b"
        continue
      fi
      if [ "$_mr_side" = codex ] && ao_mr_held "$_mr_b"; then
        # Held by the watcher for its target's turn to end: if the operator
        # has moved since (a switch, a replaced thread), take the ring from
        # the hold and re-ring the current owner (the watcher then finds it
        # gone and sends nothing).
        _ao_mr_route
        continue
      fi
      _ao_mr_route
      case $? in 1) ;; 2) continue ;; *)
        if [ "$_mr_side" = claude ]; then
          _ao_mr_ring_claude || _mr_rf=1
        else
          _ao_mr_ring_codex || _mr_rf=1
        fi ;;
      esac
      [ -f "$_mr_r" ] || continue
      # A ring to the Oracle that waits is tier 4's to report (a push), so
      # an undeliverable alarm never breeds another alarm.
      [ "$_mr_key" != "$AO_ORACLE_KEY" ] || continue
      _mr_am=$(_ao_mr_marker alarmed "$_mr_b")
      if [ "$_mr_age" -ge "$AO_MR_ALARM" ] && [ ! -e "$_mr_am" ]; then
        if _ao_mr_alarm "mailroom-ring-waiting-$_mr_side" "Mailroom: $_mr_side ring $_mr_b has waited ${_mr_age}s and is not delivered. Check that the $_mr_side desktop app is running and its mailroom bridge is armed (docs/mailroom.md). Events: $AO_MR_LOG"; then
          _ao_mr_touch "$_mr_am"
          ao_mr_event alarm "$_mr_side" "$_mr_b" "waited ${_mr_age}s"
        fi
      fi
    done
  done
  return "$_mr_rf"
}

# _ao_mr_unknowns  Each Codex send the watcher filed `unknown` (a timeout,
# a closed pipe, a crash mid-send) is reconciled once it is AO_MR_ABSENT
# old, against the target thread's rollout, the app's own record:
#   the ring's `Doorbell [<ring>]` text is there  it arrived: a resolve row
#                                                  (t1-native, ok, late-receipt)
#   the record is readable and the text absent     absence is confirmed: one
#                                                  CLI queue (tier 3), a
#                                                  resolve row with step
#                                                  unknown-absent; never more
#   no readable record                             one alarm; never resent
# A queue refused before the CLI ran is retried (relay_max_attempts).
_ao_mr_unknowns() {
  _mr_uf=0
  # An escalation in flight is claimed into escalating/ before the CLI
  # runs; one still there was cut off (the supervisor runs under its lock):
  # its outcome is unknown, so it is settled as unknown, never sent again.
  _mr_ed=$AO_MR_DIR/codex/.watcher/escalating
  for _mr_e in "$_mr_ed"/*.md; do
    [ -f "$_mr_e" ] || continue
    _mr_b=${_mr_e##*/}
    ao_mr_row codex "$_mr_b" t3-cli-queue resolve unknown - escalation-interrupted
    ao_mr_event unknown codex "$_mr_b" "escalation interrupted; not sent again"
    _ao_mr_alarm "mailroom-unknown-codex" "Mailroom: the one escalation of $_mr_b was interrupted; it may or may not have arrived and is not sent again (docs/mailroom.md)." ||
      ao_warn "could not raise the unknown-delivery alarm"
    rm -f "$_mr_e"
  done
  for _mr_u in "$AO_MR_DIR/codex/.watcher/unknown"/*.md; do
    [ -f "$_mr_u" ] || continue
    _mr_b=${_mr_u##*/}
    [ "$(ao_mr_age "$_mr_u")" -ge "$AO_MR_ABSENT" ] || continue
    _mr_sid=${_mr_b%%--*}
    _mr_roll=$(ao_mr_rollout "$_mr_sid")
    _mr_g=2
    if [ -n "$_mr_roll" ] && [ -r "$_mr_roll" ]; then
      grep -qF "Doorbell [$_mr_b]" "$_mr_roll" 2>/dev/null
      _mr_g=$?
    fi
    # Only grep's 0 (found) and 1 (read to the end, absent) are evidence.
    [ "$_mr_g" -le 1 ] || _mr_roll=''
    if [ "$_mr_g" -eq 0 ]; then
      ao_mr_row codex "$_mr_b" t1-native resolve ok - late-receipt
      ao_mr_event unknown-resolved codex "$_mr_b" "found in the target's rollout: it arrived"
      rm -f "$_mr_u"
      continue
    fi
    _mr_d=$AO_MR_DIR/codex/delivered/$_mr_b
    if [ -z "$_mr_roll" ] || [ ! -f "$_mr_d" ]; then
      ao_mr_event unknown codex "$_mr_b" "outcome unknown and the target's record is unreadable; not sent again"
      _ao_mr_alarm "mailroom-unknown-codex" "Mailroom: the Codex watcher could not confirm $_mr_b and the target thread's record cannot be read, so it is not sent again. Check the target thread (docs/mailroom.md)." &&
        rm -f "$_mr_u"
      continue
    fi
    # Absence is confirmed on the thread it went to. Re-check who owns the
    # operator now: a hold waits; a moved owner (a switch, a replaced
    # thread) gets a new ring instead of the old thread.
    if ! _ao_mr_owner "$_mr_b"; then
      ao_mr_event unknown codex "$_mr_b" "absent from the target, and its operator is no longer in the registry; not sent again"
      _ao_mr_alarm "mailroom-unknown-codex" "Mailroom: $_mr_b never reached its thread and its operator is no longer in the registry, so it is not sent again (docs/mailroom.md)." &&
        rm -f "$_mr_u"
      continue
    fi
    if [ -n "$_mr_found" ]; then
      [ "$_mr_ogate" -eq 0 ] || continue
      if [ "$_mr_ocl" != codex ] || [ "$_mr_osid" != "$_mr_sid" ]; then
        case $_mr_ocl in claude | codex) ;; *) continue ;; esac
        ao_mr_addressable "$_mr_osid" || continue
        _mr_nm=queue
        case $_mr_b in *--steer.md) _mr_nm=steer ;; esac
        if _mr_new=$(ao_mr_ring "$_mr_ocl" "$_mr_osid" "$_mr_key" "$_mr_nm" <"$_mr_d"); then
          ao_mr_row codex "$_mr_b" none resolve ok - rerouted-absent
          ao_mr_event rerouted codex "$_mr_b" "absent from the old thread; owner of $_mr_key is now $_mr_ocl: new ring ${_mr_new##*/}"
          rm -f "$_mr_u"
        fi
        continue
      fi
    fi
    _ao_mr_attempt_due absent "$_mr_b" || continue
    _ao_mr_attempt_count absent "$_mr_b"
    {
      printf 'Doorbell [%s] (mailroom fallback after an unconfirmed send, queued): ' "$_mr_b"
      cat "$_mr_d"
    } >"$_mr_msg"
    : >"$_mr_out"
    if ! mkdir -p "$_mr_ed" || ! mv "$_mr_u" "$_mr_ed/$_mr_b"; then continue; fi
    if ao_bg _ao_mr_deliver codex "$_mr_sid" "$_mr_sid" "$_mr_msg" "$_mr_out" "$_mr_b"; then
      ao_mr_row codex "$_mr_b" t3-cli-queue resolve accepted - unknown-absent
      ao_mr_event escalated codex "$_mr_b" "absent from the target's rollout after ${AO_MR_ABSENT}s: queued once by the CLI"
      rm -f "$_mr_ed/$_mr_b"
    elif grep -q 'queue acceptance unconfirmed' "$_mr_out" 2>/dev/null; then
      ao_mr_row codex "$_mr_b" t3-cli-queue resolve unknown - unknown-absent
      ao_mr_event unknown codex "$_mr_b" "escalation unconfirmed; not sent again"
      _ao_mr_alarm "mailroom-unknown-codex" "Mailroom: $_mr_b was absent from its target thread after an unconfirmed send, and the one CLI queue that followed was not confirmed either. It is not sent again; the thread may be unresponsive (docs/mailroom.md, thread recovery)." ||
        ao_warn "could not raise the unknown-delivery alarm"
      rm -f "$_mr_ed/$_mr_b"
      _mr_uf=1
    else
      # Refused before the CLI ran: back for another attempt.
      mv "$_mr_ed/$_mr_b" "$_mr_u" 2>/dev/null || ao_warn "cannot return $_mr_b for another escalation"
      ao_mr_event queue-direct-failed codex "$_mr_b" "escalation refused: $(tr '\n' ' ' <"$_mr_out" | cut -c 1-200)"
      _mr_uf=1
    fi
  done
  return "$_mr_uf"
}

# _ao_mr_threads  Codex thread health. A thread with AO_MR_SICK unknown
# outcomes in a row (in the last AO_MR_SICK_WINDOW seconds of the delivered
# log, resolutions included) while another thread delivered after the
# first of them is unresponsive, not the app: it is marked in
# <state_dir>/mailroom/unhealthy/THREAD, the Oracle gets one note, and the
# operator's recovery routine opens (operator.sh recover: revive with a
# queued, then a native no-op; else replace). Each pass advances open
# recovery routines; a later ok delivery to the thread clears the mark.
_ao_mr_threads() {
  _mr_lg=$AO_MR_DIR/codex/delivered/log.tsv
  [ -f "$_mr_lg" ] || return 0
  _mr_sick=$(tail -n 400 "$_mr_lg" | awk -F'\t' -v cut="$((AO_T_EPOCH - AO_MR_SICK_WINDOW))" -v k="$AO_MR_SICK" '
    $2 < cut || $5 == "canary" || $5 == "echo" { next }
    { split($3, p, "--"); t = p[1] }
    t == "echo" || t == "" { next }
    $6 == "ok" || $6 == "accepted" { run[t] = 0; first[t] = 0; lastok_by[t] = $2; next }
    $6 == "unknown" { if (!run[t]) first[t] = $2; run[t]++ }
    END { for (t in run) if (run[t] >= k) { other = 0; for (u in lastok_by) if (u != t && lastok_by[u] >= first[t]) other = 1; if (other) print t } }')
  for _mr_t in $_mr_sick; do
    ao_is_name "$_mr_t" || continue
    _mr_mk=$AO_STATE/mailroom/unhealthy/$_mr_t
    [ ! -f "$_mr_mk" ] || continue
    _ao_mr_touch "$_mr_mk" "$AO_T_EPOCH" || continue
    _mr_key=$(awk -F'\t' -v s="$_mr_t" '$1 !~ /^#/ && $4 == s && ($5 == "codex") { print $1; exit }' "$AO_REGISTRY" 2>/dev/null)
    ao_mr_event thread-unhealthy codex - "$_mr_t (${_mr_key:-no operator}): $AO_MR_SICK unknown sends in a row while other threads deliver"
    if [ -n "$_mr_key" ] && ! ao_is_bridge_key "$_mr_key"; then
      _ao_mr_alarm "mailroom-thread-$_mr_key" "Mailroom: the Codex thread of $_mr_key ($_mr_t) looks unresponsive ($AO_MR_SICK sends in a row with no answer while other threads deliver). Recovery started: operator.sh verify $_mr_key (revive with a queued, then a native no-op; else replace the thread)." ||
        ao_warn "could not raise the thread alarm"
      ao_timeout 120 sh "$AO_SCRIPTS/operator.sh" recover "$_mr_key" --auto </dev/null >>"$AO_STATE/routine.log" 2>&1 || true
    else
      _ao_mr_alarm "mailroom-thread-$_mr_t" "Mailroom: the Codex thread $_mr_t looks unresponsive and is not an operator's; check it in the app (docs/mailroom.md, thread recovery)." ||
        ao_warn "could not raise the thread alarm"
    fi
  done
  # A thread that delivered since it was marked is healthy again.
  for _mr_mk in "$AO_STATE/mailroom/unhealthy"/*; do
    [ -f "$_mr_mk" ] || continue
    read -r _mr_at <"$_mr_mk" 2>/dev/null
    ao_is_uint "${_mr_at:-x}" || continue
    awk -F'\t' -v t="${_mr_mk##*/}--" -v at="$_mr_at" 'index($3, t) == 1 && $2 > at && $5 != "resolve" && $6 == "ok" { f = 1 } END { exit !f }' "$_mr_lg" &&
      rm -f "$_mr_mk" && ao_mr_event thread-healthy codex - "${_mr_mk##*/} delivered again"
  done
  # Advance open recovery routines (model-free checks; a revive sends one
  # no-op turn to the target).
  for _mr_rt in "$AO_STATE/routine"/*; do
    [ -f "$_mr_rt" ] || continue
    grep -qx 'kind=recover' "$_mr_rt" || continue
    ao_timeout 120 sh "$AO_SCRIPTS/operator.sh" verify "${_mr_rt##*/}" </dev/null >>"$AO_STATE/routine.log" 2>&1 || true
  done
  return 0
}

# _ao_mr_ring_claude  Tier 3 for a Claude ring: wake the target (a cold one
# has no process to receive), then one confined headless delivery through
# relay_claude, confirmed from its event stream.
_ao_mr_ring_claude() {
  [ "$_mr_age" -ge "$AO_MR_CLAUDE_FALLBACK" ] || return 0
  _ao_mr_attempt_due fallback "$_mr_b" || return 0
  _ao_mr_attempt_count fallback "$_mr_b"
  _ao_mr_name_of "$_mr_sid"
  if [ -z "$_mr_name" ]; then
    ao_mr_event fallback-failed claude "$_mr_b" "no registry row for session $_mr_sid"
    return 1
  fi
  _mr_why=bridge-down
  case $_mr_r in */.watcher/handing/*) _mr_why=bridge-stuck ;; esac
  _ao_mr_claim || return 0
  _ao_mr_wake claude "$_mr_sid"
  _mr_id=$(sed -n 's/^relay-id: //p;s/^doorbell-id: //p' "$_mr_c" | head -n 1)
  : >"$_mr_out"
  if ao_bg _ao_mr_deliver claude "$_mr_name" "$_mr_sid" "$_mr_c" "$_mr_out" "${_mr_id:-$_mr_b}"; then
    _mr_w=
    [ "$(head -c 8 "$_mr_out")" != warning: ] || _mr_w=" with a warning: $(head -n 1 "$_mr_out")"
    ao_mr_file claude "$_mr_b" t3-headless send ok "${_mr_c%/*}" "$_mr_why" || ao_warn "cannot file $_mr_b"
    ao_mr_event fallback-ok claude "$_mr_b" "$_mr_why: delivered directly to $_mr_name$_mr_w"
    return 0
  fi
  _ao_mr_unclaim
  ao_mr_event fallback-failed claude "$_mr_b" "$(grep -v '^{' "$_mr_out" | tail -n 3 | tr '\n' ' ' | cut -c 1-240)"
  return 1
}

# _ao_mr_ring_codex  Tier 3 for a Codex ring: one CLI queue straight to the
# target thread (no steering). The step is why the watcher let it go.
_ao_mr_ring_codex() {
  [ "$_mr_age" -ge "$AO_MR_CODEX_FALLBACK" ] || return 0
  _ao_mr_attempt_due direct "$_mr_b" || return 0
  _mr_mode=queue
  case $_mr_b in *--steer.md) _mr_mode=steer ;; esac
  _mr_why=''
  [ ! -f "$AO_MR_DIR/codex/.watcher/released/$_mr_b" ] ||
    read -r _mr_why <"$AO_MR_DIR/codex/.watcher/released/$_mr_b" 2>/dev/null
  if [ -z "$_mr_why" ]; then
    if ao_mr_watcher_up codex; then _mr_why=unconfirmed; else _mr_why=watcher-down; fi
  fi
  _ao_mr_claim || return 0
  {
    printf 'Doorbell [%s] (mailroom fallback, queued): ' "$_mr_b"
    cat "$_mr_c"
  } >"$_mr_msg"
  : >"$_mr_out"
  _ao_mr_attempt_count direct "$_mr_b"
  if ao_bg _ao_mr_deliver codex "$_mr_sid" "$_mr_sid" "$_mr_msg" "$_mr_out" "$_mr_b"; then
    ao_mr_file codex "$_mr_b" t3-cli-queue queue accepted "${_mr_c%/*}" "$_mr_why" || ao_warn "cannot file $_mr_b"
    ao_mr_event queue-direct codex "$_mr_b" "$_mr_why: queued to the target (no steering; was $_mr_mode)"
    return 0
  fi
  # The CLI ran and did not confirm: it may have queued (K-28). Only a
  # failure before the CLI ran puts the ring back for another attempt.
  if grep -q 'queue acceptance unconfirmed' "$_mr_out" 2>/dev/null; then
    ao_mr_file codex "$_mr_b" t3-cli-queue queue unknown "${_mr_c%/*}" "$_mr_why" || ao_warn "cannot file $_mr_b"
    ao_mr_event unknown codex "$_mr_b" "direct queue unconfirmed; not sent again: $(tr '\n' ' ' <"$_mr_out" | cut -c 1-200)"
    _ao_mr_alarm "mailroom-unknown-codex" "Mailroom: the direct queue of $_mr_b was not confirmed; it may or may not have arrived and is not sent again. Check the target thread (docs/mailroom.md)." ||
      ao_warn "could not raise the unknown-delivery alarm"
    return 1
  fi
  _ao_mr_unclaim
  ao_mr_event queue-direct-failed codex "$_mr_b" "$(tr '\n' ' ' <"$_mr_out" | cut -c 1-240)"
  return 1
}

# _ao_mr_route  Before a fallback, re-check who owns the ring's operator now
# (registry, lease, gate): 0 deliver as named; 1 hold (the gate says no, or
# the owner has no addressable session; the alarm still runs); 2 the owner
# moved, so a new ring went to the current owner and this one is filed as
# rerouted. An operator no longer in the registry holds (the alarm runs);
# only doorbells (key .doorbell) are delivered as named. Sets _mr_key.
_ao_mr_route_cb() {
  [ "$OP_KEY" = "$_mr_key" ] || return 0
  _mr_found=1 _mr_osid=$OP_SID _mr_ocl=$OP_CLIENT _mr_ogate=0
  ao_gate relay || _mr_ogate=1
}
# _ao_mr_owner RING  Set _mr_key from the ring's name and _mr_found,
# _mr_osid, _mr_ocl, _mr_ogate from the registry as it is now. Returns 0
# for a doorbell (key .doorbell: delivered as named, _mr_found empty) or an
# operator in the registry, 1 otherwise.
_ao_mr_owner() {
  _mr_key=${1#*--}
  _mr_key=${_mr_key%--steer.md}
  _mr_key=${_mr_key%--queue.md}
  _mr_key=$(printf '%s\n' "${_mr_key%.md}" | sed 's/-[0-9]\{8\}T[0-9]\{6\}\(-[0-9a-f]\{6\}\)\{0,1\}\(-[0-9]\{1,3\}\)\{0,1\}$//')
  _mr_found='' _mr_osid='' _mr_ocl='' _mr_ogate=0
  [ "$_mr_key" != .doorbell ] || return 0
  ao_is_name "$_mr_key" && ao_registry_has "$_mr_key" || return 1
  ao_registry_each _ao_mr_route_cb
  [ -n "$_mr_found" ]
}
_ao_mr_route() {
  _ao_mr_owner "$_mr_b" || return 1
  [ "$_mr_key" != .doorbell ] || return 0
  [ "$_mr_ogate" -eq 0 ] || return 1
  [ "$_mr_ocl" != "$_mr_side" ] || [ "$_mr_osid" != "$_mr_sid" ] || return 0
  case $_mr_ocl in claude | codex) ;; *) return 1 ;; esac
  ao_mr_addressable "$_mr_osid" || return 1
  _mr_nm=queue
  case $_mr_b in *--steer.md) _mr_nm=steer ;; esac
  _ao_mr_claim || return 2
  if _mr_new=$(ao_mr_ring "$_mr_ocl" "$_mr_osid" "$_mr_key" "$_mr_nm" <"$_mr_c"); then
    ao_mr_file "$_mr_side" "$_mr_b" none rerouted ok "${_mr_c%/*}"
    ao_mr_event rerouted "$_mr_side" "$_mr_b" "owner of $_mr_key moved to $_mr_ocl; new ring ${_mr_new##*/}"
    return 2
  fi
  _ao_mr_unclaim
  return 1
}

# ao_mr_note_received NOTE AT  True when a ring to the Oracle that lists
# NOTE (a note's file name in the Oracle's inbox, as the relay archived it)
# was delivered with status ok at or after epoch AT. A CLI `accepted` only
# proves submission, and an unrelated delivery proves nothing about NOTE.
ao_mr_note_received() {
  _mr_nk=-$AO_ORACLE_KEY-$(ao_slug "${1%.md}")
  for _mr_sd in claude codex; do
    _mr_lg=$AO_MR_DIR/$_mr_sd/delivered/log.tsv
    [ -f "$_mr_lg" ] || continue
    # Ring names are single words (ao_mr_ring).
    # shellcheck disable=SC2013
    for _mr_rn in $(awk -F'\t' -v k="--$AO_ORACLE_KEY-" -v at="$2" 'index($3, k) && $2 >= at && $6 == "ok" && $5 != "resolve" { print $3 }' "$_mr_lg"); do
      _mr_rf=$AO_MR_DIR/$_mr_sd/delivered/$_mr_rn
      [ -f "$_mr_rf" ] || continue
      grep -qF -- "$_mr_nk" "$_mr_rf" && return 0
      _mr_mf=$(sed -n 's/^- and [0-9]* more, all listed in //p' "$_mr_rf" | head -n 1)
      [ -n "$_mr_mf" ] && grep -qF -- "$_mr_nk" "$AO_SENT/$_mr_mf" 2>/dev/null && return 0
    done
  done
  return 1
}

# _ao_mr_tier4  An alarm note is pending until a ring that lists it reaches
# the Oracle (ao_mr_note_received). One pending longer than AO_MR_PUSH means the Oracle is
# unreachable: the owner is pushed once per outage. The outage ends when no
# alarm is overdue; pending alarms are dropped after a day.
_ao_mr_tier4() {
  _mr_pd=$AO_STATE/mailroom/alarm-pending
  _mr_over=''
  for _mr_p in "$_mr_pd"/*; do
    [ -f "$_mr_p" ] || continue
    _mr_note=''
    read -r _mr_at _mr_note <"$_mr_p" 2>/dev/null
    ao_is_uint "${_mr_at:-x}" || _mr_at=$AO_T_EPOCH
    if [ -n "$_mr_note" ] && ao_mr_note_received "$_mr_note" "$_mr_at"; then
      rm -f "$_mr_p"
      continue
    fi
    if [ $((AO_T_EPOCH - _mr_at)) -ge 86400 ]; then rm -f "$_mr_p"; continue; fi
    [ $((AO_T_EPOCH - _mr_at)) -lt "$AO_MR_PUSH" ] || _mr_over=${_mr_p##*/}
  done
  _mr_om=$(_ao_mr_marker outage oracle)
  if [ -z "$_mr_over" ]; then
    [ ! -f "$_mr_om" ] || { rm -f "$_mr_om"; ao_mr_event outage-closed - - "no alarm overdue"; }
    return 0
  fi
  [ ! -f "$_mr_om" ] || return 0
  # Marked before the push, so a crash mid-push never repeats it.
  _ao_mr_touch "$_mr_om" "$AO_T_EPOCH $_mr_over" || return 0
  if _ao_mr_push "Mailroom: the Oracle has not received an alarm for 15+ minutes ($_mr_over). Check the always-on host and its desktop apps (docs/mailroom.md)."; then
    ao_mr_event push - - "Oracle unreachable 15+ min ($_mr_over): pushed the owner"
  else
    ao_mr_event push-failed - - "Oracle unreachable 15+ min ($_mr_over); no hooks/push or chat adapter reached the owner"
  fi
}

# _ao_mr_app_pid BUNDLE  Print the desktop app's pid, `none` when it is not
# running, or nothing when this host cannot tell (no lsappinfo: not macOS).
_ao_mr_app_pid() {
  command -v lsappinfo >/dev/null 2>&1 || return 0
  _mr_ap=$(lsappinfo info -only pid -app "$1" 2>/dev/null |
    sed -n 's/.*pid"\{0,1\} *= *\([0-9][0-9]*\).*/\1/p' | head -n 1)
  printf '%s\n' "${_mr_ap:-none}"
}

# _ao_mr_app_version BUNDLE  Print the running app's CFBundleVersion, or
# unknown.
_ao_mr_app_version() {
  _mr_v=''
  if command -v lsappinfo >/dev/null 2>&1 && command -v defaults >/dev/null 2>&1; then
    _mr_bp=$(lsappinfo info -only bundlepath -app "$1" 2>/dev/null | sed -n 's/.*"LSBundlePath" *= *"\([^"]*\)".*/\1/p' | head -n 1)
    [ -z "$_mr_bp" ] || _mr_v=$(defaults read "$_mr_bp/Contents/Info" CFBundleVersion 2>/dev/null)
  fi
  printf '%s\n' "${_mr_v:-unknown}" | tr -c 'A-Za-z0-9._\n-' '-'
}

# _ao_mr_bridge_check SIDE  Keep one bridge armed. A watcher that is not
# armed (app restart, watcher crash) gets one re-arm per app process (the
# app's pid; where it cannot be read, per clock hour). Claude: wake the
# bridge session (hooks/wake or wake_link), return the window to the Oracle,
# then one confined headless run sends the bridge a fixed "Re-arm" message
# (no mail). Codex: one CLI queue "Re-arm doorbell watcher" to the bridge
# chat. Still down AO_MR_REARM_GRACE after that: one alarm per episode. An
# app that is not running at all (a reboot) is opened in the background, at
# most once an hour. The Codex watcher is managed once deployed (its log
# exists).
_ao_mr_bridge_check() {
  ao_mr_bridge "$1" || return 0
  [ "$1" != codex ] || [ -f "$AO_MR_DIR/codex/.watcher/log" ] || return 0
  _mr_down=$(_ao_mr_marker down "$1")
  _mr_ra=$(_ao_mr_marker rearm "$1")
  _mr_bam=$(_ao_mr_marker alarmed "bridge-$1")
  if ao_mr_watcher_up "$1"; then
    if [ -f "$_mr_down" ]; then
      rm -f "$_mr_down" "$_mr_bam"
      ao_mr_event recovered "$1" - "watcher armed again"
    fi
    return 0
  fi
  if [ ! -f "$_mr_down" ]; then
    _ao_mr_touch "$_mr_down" "$AO_T_EPOCH"
    ao_mr_event bridge-down "$1" - "watcher not armed"
  fi
  if [ "$1" = claude ]; then _mr_bundle=$AO_MR_APP_CLAUDE; else _mr_bundle=$AO_MR_APP_CODEX; fi
  _mr_app=$(_ao_mr_app_pid "$_mr_bundle")
  if [ "$_mr_app" = none ]; then
    _mr_lm=$(_ao_mr_marker launched "$1")
    if [ ! -f "$_mr_lm" ] || [ "$(ao_mr_age "$_mr_lm")" -ge "$AO_MR_REARM_EVERY" ]; then
      _ao_mr_touch "$_mr_lm"
      if command -v open >/dev/null 2>&1 && open -g -b "$_mr_bundle" </dev/null >/dev/null 2>&1; then
        ao_mr_event relaunch "$1" - "opened $_mr_bundle in the background"
      else
        ao_mr_event relaunch-failed "$1" - "could not open $_mr_bundle"
      fi
    fi
    # Still not running well after the open: one alarm per episode.
    _mr_since=0
    read -r _mr_since <"$_mr_down" 2>/dev/null
    ao_is_uint "${_mr_since:-x}" || _mr_since=$AO_T_EPOCH
    if [ $((AO_T_EPOCH - _mr_since)) -ge $((AO_MR_REARM_GRACE * 2)) ] && [ ! -e "$_mr_bam" ] &&
      _ao_mr_alarm "mailroom-bridge-down-$1" "Mailroom: the $1 desktop app is not running and opening it did not bring it back. Open it yourself; its bridge then re-arms (docs/mailroom.md, restart recovery)."; then
      _ao_mr_touch "$_mr_bam" && ao_mr_event alarm "$1" - "app not running"
    fi
    return 0
  fi
  _mr_key=${_mr_app:-hour-$((AO_T_EPOCH / 3600))}
  _mr_last=0 _mr_lkey=
  [ ! -f "$_mr_ra" ] || read -r _mr_last _mr_lkey <"$_mr_ra"
  ao_is_uint "${_mr_last:-x}" || _mr_last=0
  if [ "$_mr_lkey" = "$_mr_key" ]; then
    # Re-armed already for this app process: alarm once if still down.
    [ $((AO_T_EPOCH - _mr_last)) -ge "$AO_MR_REARM_GRACE" ] && [ ! -e "$_mr_bam" ] || return 0
    if _ao_mr_alarm "mailroom-bridge-down-$1" "Mailroom: the $1 bridge ($MR_B_NAME) is still not armed after a re-arm. Open the $1 desktop app and send its bridge 'Re-arm' (docs/mailroom.md, restart recovery)."; then
      _ao_mr_touch "$_mr_bam" && ao_mr_event alarm "$1" - "bridge still down after re-arm"
    fi
    return 0
  fi
  # Marked before the call: a failed or timed-out submission is never
  # repeated for this app process (no repeat model turns); the alarm covers it.
  _ao_mr_touch "$_mr_ra" "$AO_T_EPOCH $_mr_key"
  if [ "$1" = codex ]; then
    printf 'Mailroom (automated, not from the human): Re-arm doorbell watcher. Run your one arm command, then end the turn with no text.\nmailroom-id: rearm-%s\n' "$AO_T_STAMP" >"$_mr_msg"
  else
    _ao_mr_wake claude "$MR_B_SID"
    printf 'Mailroom (automated, not from the human): Re-arm. Start your watcher again as your AGENTS.md says, then end the turn.\nmailroom-id: rearm-%s\n' "$AO_T_STAMP" >"$_mr_msg"
  fi
  : >"$_mr_out"
  if ao_bg _ao_mr_deliver "$1" "$MR_B_NAME" "$MR_B_SID" "$_mr_msg" "$_mr_out" "rearm-$AO_T_STAMP"; then
    ao_mr_event rearm "$1" - "re-arm sent to $MR_B_NAME (app $_mr_key)"
    return 0
  fi
  ao_mr_event rearm-failed "$1" - "$(grep -v '^{' "$_mr_out" | tail -n 3 | tr '\n' ' ' | cut -c 1-240)"
  return 1
}

# ao_mr_fingerprint_now SIDE  Print SIDE's version fingerprint, read with no
# model: Claude, the CLI version and peer protocol of the newest live
# session record plus the desktop app's version; Codex, the watcher's
# record of its app tool server (name, version, a hash of the tool list)
# plus the desktop app's version.
ao_mr_fingerprint_now() {
  if [ "$1" = claude ]; then
    _mr_f=''
    [ ! -x /usr/bin/python3 ] || _mr_f=$(/usr/bin/python3 -I "$AO_SCRIPTS/mailroom-wait.py" --fingerprint </dev/null 2>/dev/null)
    printf '%s app=%s\n' "${_mr_f:-cli=unknown}" "$(_ao_mr_app_version "$AO_MR_APP_CLAUDE")"
  else
    _mr_f=$(head -n 1 "$AO_MR_DIR/codex/.watcher/fingerprint" 2>/dev/null)
    printf '%s app=%s\n' "${_mr_f:-tools=unknown}" "$(_ao_mr_app_version "$AO_MR_APP_CODEX")"
  fi
}

# _ao_mr_fingerprint SIDE  Record a changed fingerprint (history in
# <state_dir>/mailroom-versions.tsv) and send one canary through SIDE's
# normal path. The new fingerprint is recorded only once its canary is out,
# so a skipped canary is retried at the next pass. Needs an armed bridge;
# a fingerprint that is wholly unknown is ignored.
_ao_mr_fingerprint() {
  ao_mr_bridge "$1" && ao_mr_watcher_up "$1" || return 0
  _mr_fp=$(ao_mr_fingerprint_now "$1")
  case $_mr_fp in *=unknown*app=unknown) return 0 ;; esac
  _mr_ff=$(_ao_mr_marker fingerprint "$1")
  _mr_old=$(cat "$_mr_ff" 2>/dev/null)
  [ "$_mr_fp" != "$_mr_old" ] || return 0
  [ ! -f "$(_ao_mr_marker canary "$1")" ] || return 0
  _mr_ext=.md
  [ "$1" != codex ] || _mr_ext=--queue.md
  _mr_t=$(mktemp "$AO_MR_DIR/$1/.tmp.XXXXXX") || return 0
  printf 'Canary (mailroom supervisor, automated): no delivery needed.\n' >"$_mr_t"
  # Never reused (a random suffix): a canary is confirmed by its own row.
  _mr_rand=$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')
  if ! _mr_cn=$(ao_place "$_mr_t" "$AO_MR_DIR/$1/echo--canary-$AO_T_STAMP-$_mr_rand" "$_mr_ext"); then
    rm -f "$_mr_t"
    return 0
  fi
  _ao_mr_touch "$(_ao_mr_marker canary "$1")" "$AO_T_EPOCH ${_mr_cn##*/}"
  printf '%s\t%s\t%s\t%s\n' "$AO_T_ISO" "$1" "${_mr_old:-none}" "$_mr_fp" >>"$AO_STATE/mailroom-versions.tsv"
  printf '%s\n' "$_mr_fp" | ao_write_atomic "$_mr_ff" || ao_warn "cannot record $_mr_ff"
  ao_mr_event canary "$1" "${_mr_cn##*/}" "fingerprint ${_mr_old:-none} -> $_mr_fp"
}

# _ao_mr_canary_check SIDE  A canary is confirmed by its delivered row from
# SIDE's first tier with status ok. Any other row, or none after
# AO_MR_CANARY_WAIT, alarms once per side and version: deliveries carry on
# by the slower tiers, with higher latency, until the first tier is fixed.
_ao_mr_canary_check() {
  _mr_cm=$(_ao_mr_marker canary "$1")
  [ -f "$_mr_cm" ] || return 0
  read -r _mr_at _mr_cn <"$_mr_cm" 2>/dev/null
  if ! ao_is_uint "${_mr_at:-x}" || ! ao_is_name "${_mr_cn:-x}"; then rm -f "$_mr_cm"; return 0; fi
  _mr_first=$(ao_mr_first_tier "$1")
  _mr_row=$(awk -F'\t' -v r="$_mr_cn" '$3 == r { l = $4 "\t" $6 "\t" $8 } END { if (l != "") print l }' \
    "$AO_MR_DIR/$1/delivered/log.tsv" 2>/dev/null)
  _mr_ok=''
  if [ -z "$_mr_row" ]; then
    [ $((AO_T_EPOCH - _mr_at)) -ge "$AO_MR_CANARY_WAIT" ] || return 0
    if ao_mr_watcher_up "$1"; then _mr_step=not-filed; else _mr_step=watcher-down; fi
  else
    _mr_tier=$(printf '%s\n' "$_mr_row" | cut -f 1)
    _mr_st=$(printf '%s\n' "$_mr_row" | cut -f 2)
    _mr_step=$(printf '%s\n' "$_mr_row" | cut -f 3)
    [ "$_mr_tier" != "$_mr_first" ] || [ "$_mr_st" != ok ] || _mr_ok=1
    [ "$_mr_step" != - ] || _mr_step="$_mr_tier-$_mr_st"
  fi
  rm -f "$_mr_cm"
  if [ -n "$_mr_ok" ]; then
    ao_mr_event canary-ok "$1" "$_mr_cn" "filed by $_mr_first"
    return 0
  fi
  _mr_ver=$(cat "$(_ao_mr_marker fingerprint "$1")" 2>/dev/null)
  ao_mr_event canary-failed "$1" "$_mr_cn" "step $_mr_step"
  _mr_am=$(_ao_mr_marker alarmed "canary-$1-$(printf '%s' "$_mr_ver" | cksum | cut -d ' ' -f 1)")
  [ ! -e "$_mr_am" ] || return 0
  _ao_mr_alarm "mailroom-degraded-$1" "Mailroom: the $1 canary after a version change failed at step $_mr_step (fingerprint: ${_mr_ver:-unknown}). Deliveries continue by the slower tiers, with higher latency, until the first tier ($_mr_first) works again. History: $AO_STATE/mailroom-versions.tsv (docs/mailroom.md, degradation)." &&
    _ao_mr_touch "$_mr_am" "$AO_T_EPOCH"
}

# ao_mr_tier_status SIDE  Print `ok|degraded <TAB> step <TAB> last first-tier
# success epoch (0 if none)` from SIDE's delivered log: degraded when the
# last two deliveries that were not neutral missed the first tier. A cold
# target, a switched-off tier, the rate limit and a busy queue target are
# neutral; canaries, reroutes and old probes are not deliveries.
ao_mr_tier_status() {
  _mr_first=$(ao_mr_first_tier "$1")
  tail -n 400 "$AO_MR_DIR/$1/delivered/log.tsv" 2>/dev/null | awk -F'\t' -v first="$_mr_first" -v neutral=" $AO_MR_NEUTRAL " '
    $5 == "canary" || $5 == "echo" || $5 == "rerouted" || $4 == "none" || NF < 8 { next }
    $4 == first && ($6 == "ok" || $6 == "accepted") { fails = 0; good = $2; next }
    {
      step = ($4 == first) ? "outcome-" $6 : $8
      if (index(neutral, " " step " ")) next
      fails++; last = step
    }
    END { printf "%s\t%s\t%s\n", (fails >= 2 ? "degraded" : "ok"), (fails >= 2 ? last : "-"), good + 0 }'
}

# _ao_mr_degraded SIDE  One alarm per side, failing step and version while
# SIDE is degraded; a first-tier success after an alarm clears its marker,
# so the same cause can alarm again later.
_ao_mr_degraded() {
  _mr_ts=$(ao_mr_tier_status "$1")
  _mr_state=$(printf '%s\n' "$_mr_ts" | cut -f 1)
  _mr_step=$(printf '%s\n' "$_mr_ts" | cut -f 2)
  _mr_good=$(printf '%s\n' "$_mr_ts" | cut -f 3)
  for _mr_m in "$AO_STATE/mailroom/alarmed/degraded-$1-"* "$AO_STATE/mailroom/alarmed/canary-$1-"*; do
    [ -f "$_mr_m" ] || continue
    read -r _mr_at <"$_mr_m" 2>/dev/null
    ao_is_uint "${_mr_at:-x}" || _mr_at=0
    if [ "$_mr_good" -gt "$_mr_at" ]; then
      rm -f "$_mr_m"
      ao_mr_event first-tier-ok "$1" - "alarm ${_mr_m##*/} cleared by a first-tier delivery"
    fi
  done
  [ "$_mr_state" = degraded ] || return 0
  _mr_ver=$(cat "$(_ao_mr_marker fingerprint "$1")" 2>/dev/null)
  _mr_am=$(_ao_mr_marker alarmed "degraded-$1-$_mr_step-$(printf '%s' "${_mr_ver:-unknown}" | cksum | cut -d ' ' -f 1)")
  [ ! -e "$_mr_am" ] || return 0
  if [ "$_mr_good" -gt 0 ]; then _mr_last=$(ao_utc "$_mr_good"); else _mr_last=never; fi
  _ao_mr_alarm "mailroom-degraded-$1" "Mailroom: two $1 deliveries in a row missed the first tier ($(ao_mr_first_tier "$1")) at step $_mr_step; they were still delivered by a slower tier, with higher latency. Fingerprint: ${_mr_ver:-unknown}. Last first-tier delivery (UTC): $_mr_last. Rows: $AO_MR_DIR/$1/delivered/log.tsv; summary: mailroom.sh metrics (docs/mailroom.md, degradation)." &&
    _ao_mr_touch "$_mr_am" "$AO_T_EPOCH" && ao_mr_event degraded "$1" - "step $_mr_step"
}

# _ao_mr_prune  Drop per-ring markers whose ring is no longer waiting.
_ao_mr_prune() {
  for _mr_k in fallback direct alarmed; do
    for _mr_m in "$AO_STATE/mailroom/$_mr_k"/*; do
      [ -f "$_mr_m" ] || continue
      _mr_n=${_mr_m##*/}
      case $_mr_n in
        bridge-* | degraded-* | canary-*) continue ;;
        t1-unknown-*) [ -f "$AO_MR_DIR/claude/.watcher/t1/${_mr_n#t1-unknown-}" ] || rm -f "$_mr_m"; continue ;;
      esac
      [ -f "$AO_MR_DIR/claude/$_mr_n" ] || [ -f "$AO_MR_DIR/codex/$_mr_n" ] ||
        [ -f "$AO_MR_DIR/claude/.watcher/handing/$_mr_n" ] || rm -f "$_mr_m"
    done
  done
}
