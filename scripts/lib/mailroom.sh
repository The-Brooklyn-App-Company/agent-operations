# shellcheck shell=sh disable=SC2034
# (SC2034: AO_MR_* globals set here are read by relay.sh and mailroom.sh.)
# mailroom.sh - the cross-app mailroom: rings, the delivered log, events, the
# timed safety nets and the bridge supervisor. EXPERIMENTAL since 0.3.1
# (docs/mailroom.md).
#
# Sourced after core.sh, registry.sh and vendor.sh, and after ao_load.
#
# One rule: the relay routes, the bridges deliver, and a model-free
# supervisor keeps both bridges armed.
#
# A ring is one file per hand-off in <bridge_dir>/<client>/, written
# atomically by the relay (or a doorbell): its body is the relay's
# fixed-shape pointer, never note text. Names:
#   claude  <session>--<key>-<stamp>.md
#   codex   <thread>--<key>-<stamp>--<steer|queue>.md
#   probes  echo--probe-<stamp>.md (codex: ...--queue.md): filed, never sent
# The receiving app's in-app bridge (a cheap session in its own home, with a
# push watcher) hands each ring to its target with the app's own messaging
# tool and files it in delivered/, appending one line to delivered/log.tsv:
#   ISO-time <TAB> epoch <TAB> ring <TAB> by <TAB> mode <TAB> status
# The bridges are registry rows with the reserved keys mailroom-claude and
# mailroom-codex: the one file every script reads for their ids.

# Timings, in seconds. Fixed on purpose: fewer knobs, one documented design.
AO_MR_CLAUDE_FALLBACK=180 # a Claude ring this old gets one direct delivery
AO_MR_CODEX_FALLBACK=180  # a Codex ring this old is queued straight to the target
AO_MR_ALARM=600           # a ring still waiting this long alarms once
AO_MR_RETRY=300           # spacing between fallback attempts for one ring
AO_MR_HEARTBEAT=180       # a Codex watcher heartbeat older than this is stale
AO_MR_HOLD_CAP=660        # a watcher's queue hold older than this is ignored
AO_MR_REARM_GRACE=120     # a dead Claude watcher this long without re-arming is down
AO_MR_REARM_EVERY=3600    # at most one re-arm per side per hour
AO_MR_PROBE_EVERY=3600    # free echo probes, hourly

# ao_mr_init  Read the mailroom settings: AO_MR_ON (on|off), AO_MR_DIR and
# AO_MR_LOG.
ao_mr_init() {
  AO_MR_ON=$(ao_cfg relay_bridge on)
  case $AO_MR_ON in on | off) ;; *) ao_die "$AO_E_USAGE" "relay_bridge must be on or off" ;; esac
  AO_MR_DIR=$(ao_cfg_path bridge_dir "$AO_INBOX/.mailroom")
  AO_MR_LOG=$AO_STATE/mailroom.tsv
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

# ao_mr_mode FILE  Print steer when any name listed in FILE says urgent or
# steer (any case), else queue. Only the sender's file name decides.
ao_mr_mode() {
  if grep -qiE 'urgent|steer' "$1" 2>/dev/null; then echo steer; else echo queue; fi
}

# ao_mr_ring CLIENT SESSION KEY MODE  Write stdin as a new ring and print its
# path. Never replaces a ring: a taken name gets -2, -3... before the suffix.
ao_mr_ring() {
  _mr_dir=$AO_MR_DIR/$1
  _mr_ext=.md
  [ "$1" != codex ] || _mr_ext=--$4.md
  mkdir -p "$_mr_dir" || return 1
  _mr_tmp=$(mktemp "$_mr_dir/.tmp.XXXXXX") || return 1
  if ! cat >"$_mr_tmp" || ! ao_place "$_mr_tmp" "$_mr_dir/$2--$3-$AO_T_STAMP" "$_mr_ext"; then
    rm -f "$_mr_tmp"
    return 1
  fi
}

# ao_mr_file SIDE RING BY MODE [STATUS]  Move a waiting ring to delivered/
# and append its line to delivered/log.tsv. Fails if the ring is gone.
ao_mr_file() {
  _mr_src=$AO_MR_DIR/$1/$2
  [ -f "$_mr_src" ] || return 1
  mkdir -p "$AO_MR_DIR/$1/delivered" || return 1
  mv -f "$_mr_src" "$AO_MR_DIR/$1/delivered/$2" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$AO_T_ISO" "$AO_T_EPOCH" "$2" "$3" "$4" "${5:-ok}" \
    >>"$AO_MR_DIR/$1/delivered/log.tsv"
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
# until its target is idle (the hold file holds the epoch it started).
ao_mr_held() {
  _mr_h=$AO_MR_DIR/codex/.watcher/holding/$1
  [ -f "$_mr_h" ] && ao_mr_heartbeat_fresh || return 1
  read -r _mr_since <"$_mr_h" 2>/dev/null || return 1
  ao_is_uint "${_mr_since:-x}" || return 1
  [ $((AO_T_EPOCH - _mr_since)) -lt "$AO_MR_HOLD_CAP" ]
}

# _ao_mr_marker KIND NAME  Path of a safety-net marker in state.
_ao_mr_marker() { printf '%s/mailroom/%s/%s\n' "$AO_STATE" "$1" "$2"; }

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

# _ao_mr_wake CLIENT SESSION  Run the optional hooks/wake executable (for
# example one that opens a desktop session link so a cold session has a
# process to receive): `wake <client> <session>`, 30 s, output to the log.
_ao_mr_wake() {
  [ -x "$AO_HOOKS/wake" ] || return 0
  ao_timeout 30 "$AO_HOOKS/wake" "$1" "$2" </dev/null >>"$AO_STATE/hooks.log" 2>&1 ||
    ao_mr_event wake-failed "$1" - "hooks/wake exit $?"
}

# _ao_mr_deliver CLIENT NAME SESSION MESSAGE OUT ID  One direct delivery
# through the relay transport, in a subshell so a broken configuration
# cannot stop the supervisor.
_ao_mr_deliver() {
  (ao_role_load "relay_$1" "$1" >"$5" 2>&1 && ao_role_deliver "$2" "$3" "$4" "$5" "$6")
}

# _ao_mr_alarm SLUG TEXT  One note to the Oracle, and, because the Oracle's
# inbox itself may need the broken bridge, the chat adapter if configured.
_ao_mr_alarm() {
  _mr_ok=0
  ao_note_oracle "$1" "$2" || _mr_ok=1
  _mr_chat=$(ao_cfg chat none)
  case $_mr_chat in none | '') return "$_mr_ok" ;; esac
  _mr_cp=$(ao_expand_path "$_mr_chat")
  [ -x "$_mr_cp" ] || return "$_mr_ok"
  ao_timeout 30 "$_mr_cp" notify high "$2" </dev/null >/dev/null 2>&1 || ao_mr_event chat-failed - - "chat notify failed"
  return 0
}

# ao_mr_supervise [--dry-run]  The model-free supervisor: run by
# `mailroom.sh supervise` (from the relay unit every minute, at login, and
# from the tick), outside the relay lock. It uses a model only when
# something is down, and then once.
#   1. Rings that wait (not probes):
#      claude  older than AO_MR_CLAUDE_FALLBACK: hooks/wake, then one direct
#              delivery through relay_claude, confirmed from its event stream
#      codex   held by a live watcher (queue ring, target busy): left alone;
#              older than AO_MR_CODEX_FALLBACK: queued straight to the target
#              thread (no steering), then filed as queue-direct
#      both    still waiting after AO_MR_ALARM: one alarm
#   2. Bridges (rows mailroom-claude, mailroom-codex): a watcher that is
#      not armed (app restart, reboot, watcher crash) gets one re-arm per
#      hour: hooks/wake, then a fixed "Re-arm" message to the bridge through
#      the relay transport (it carries no mail). Still down at the next
#      re-arm: one alarm per episode.
#   3. Hourly echo probes (free): a probe ring per side, filed by a live
#      bridge without a send; checked at the next probe.
# A failed fallback is retried at most relay_max_attempts times, spaced
# AO_MR_RETRY apart. Returns 1 if anything failed.
ao_mr_supervise() {
  _mr_dry=${1-}
  _mr_fail=0
  AO_MR_MAX=$(ao_cfg_uint relay_max_attempts 3) || return "$AO_E_USAGE"
  _mr_out=$(ao_tmp mr-out) _mr_msg=$(ao_tmp mr-msg)
  _ao_mr_rings || _mr_fail=1
  [ -z "$_mr_dry" ] || return 0
  for _mr_side in claude codex; do
    _ao_mr_bridge_check "$_mr_side" || _mr_fail=1
  done
  _ao_mr_probe
  _ao_mr_prune
  return "$_mr_fail"
}

_ao_mr_rings() {
  _mr_rf=0
  for _mr_side in claude codex; do
    for _mr_r in "$AO_MR_DIR/$_mr_side"/*.md; do
      [ -f "$_mr_r" ] || continue
      _mr_b=${_mr_r##*/}
      _mr_sid=${_mr_b%%--*}
      [ "$_mr_sid" != echo ] || continue
      _mr_age=$(ao_mr_age "$_mr_r")
      if [ -n "$_mr_dry" ]; then
        printf 'ring waiting %ss: %s/%s\n' "$_mr_age" "$_mr_side" "$_mr_b"
        continue
      fi
      if [ "$_mr_side" = claude ]; then
        _ao_mr_ring_claude || _mr_rf=1
      else
        ao_mr_held "$_mr_b" && continue
        _ao_mr_ring_codex || _mr_rf=1
      fi
      [ -f "$_mr_r" ] || continue
      _mr_am=$(_ao_mr_marker alarmed "$_mr_b")
      if [ "$_mr_age" -ge "$AO_MR_ALARM" ] && [ ! -e "$_mr_am" ]; then
        if _ao_mr_alarm "mailroom-ring-waiting-$_mr_side" "Mailroom: $_mr_side ring $_mr_b has waited ${_mr_age}s and is not delivered. Check that the $_mr_side desktop app is running and its mailroom bridge is armed (docs/mailroom.md). Events: $AO_MR_LOG"; then
          mkdir -p "${_mr_am%/*}" && : >"$_mr_am"
          ao_mr_event alarm "$_mr_side" "$_mr_b" "waited ${_mr_age}s"
        fi
      fi
    done
  done
  return "$_mr_rf"
}

_ao_mr_ring_claude() {
  [ "$_mr_age" -ge "$AO_MR_CLAUDE_FALLBACK" ] || return 0
  _ao_mr_attempt_due fallback "$_mr_b" || return 0
  _ao_mr_attempt_count fallback "$_mr_b"
  _ao_mr_name_of "$_mr_sid"
  if [ -z "$_mr_name" ]; then
    ao_mr_event fallback-failed claude "$_mr_b" "no registry row for session $_mr_sid"
    return 1
  fi
  _ao_mr_wake claude "$_mr_sid"
  _mr_id=$(sed -n 's/^relay-id: //p;s/^doorbell-id: //p' "$_mr_r" | head -n 1)
  : >"$_mr_out"
  if ao_bg _ao_mr_deliver claude "$_mr_name" "$_mr_sid" "$_mr_r" "$_mr_out" "${_mr_id:-$_mr_b}"; then
    _mr_w=
    [ "$(head -c 8 "$_mr_out")" != warning: ] || _mr_w=" with a warning: $(head -n 1 "$_mr_out")"
    ao_mr_file claude "$_mr_b" fallback - || ao_warn "cannot file $_mr_b"
    ao_mr_event fallback-ok claude "$_mr_b" "bridge stuck or down: delivered directly to $_mr_name$_mr_w"
    return 0
  fi
  ao_mr_event fallback-failed claude "$_mr_b" "$(grep -v '^{' "$_mr_out" | tail -n 3 | tr '\n' ' ' | cut -c 1-240)"
  return 1
}

_ao_mr_ring_codex() {
  [ "$_mr_age" -ge "$AO_MR_CODEX_FALLBACK" ] || return 0
  _ao_mr_attempt_due direct "$_mr_b" || return 0
  _mr_mode=queue
  case $_mr_b in *--steer.md) _mr_mode=steer ;; esac
  {
    printf 'Doorbell [%s] (mailroom fallback, queued): ' "$_mr_b"
    cat "$_mr_r"
  } >"$_mr_msg"
  : >"$_mr_out"
  _ao_mr_attempt_count direct "$_mr_b"
  if ao_bg _ao_mr_deliver codex "$_mr_sid" "$_mr_sid" "$_mr_msg" "$_mr_out" "$_mr_b"; then
    ao_mr_file codex "$_mr_b" queue-direct queue accepted || ao_warn "cannot file $_mr_b"
    ao_mr_event queue-direct codex "$_mr_b" "queued to the target (no steering; was $_mr_mode)"
    return 0
  fi
  ao_mr_event queue-direct-failed codex "$_mr_b" "$(tr '\n' ' ' <"$_mr_out" | cut -c 1-240)"
  return 1
}

# _ao_mr_bridge_check SIDE  Re-arm a bridge whose watcher is not armed.
_ao_mr_bridge_check() {
  ao_mr_bridge "$1" || return 0
  _mr_down=$(_ao_mr_marker down "$1")
  _mr_ra=$(_ao_mr_marker rearm "$1")
  if ao_mr_watcher_up "$1"; then
    if [ -f "$_mr_down" ]; then
      rm -f "$_mr_down" "$_mr_ra" "$(_ao_mr_marker alarmed "bridge-$1")"
      ao_mr_event recovered "$1" - "watcher armed again"
    fi
    return 0
  fi
  if [ ! -f "$_mr_down" ]; then
    mkdir -p "${_mr_down%/*}" && printf '%s\n' "$AO_T_EPOCH" >"$_mr_down"
    ao_mr_event bridge-down "$1" - "watcher not armed"
  fi
  _mr_last=0
  [ ! -f "$_mr_ra" ] || read -r _mr_last <"$_mr_ra"
  ao_is_uint "${_mr_last:-x}" || _mr_last=0
  [ $((AO_T_EPOCH - _mr_last)) -ge "$AO_MR_REARM_EVERY" ] || return 0
  if [ "$_mr_last" -gt 0 ] && [ ! -e "$(_ao_mr_marker alarmed "bridge-$1")" ]; then
    _ao_mr_alarm "mailroom-bridge-down-$1" "Mailroom: the $1 bridge ($MR_B_NAME) is still not armed after a re-arm an hour ago. Open the $1 desktop app and send its bridge 'Re-arm' (docs/mailroom.md, restart recovery)." &&
      { : >"$(_ao_mr_marker alarmed "bridge-$1")"; ao_mr_event alarm "$1" - "bridge still down after re-arm"; }
  fi
  { mkdir -p "${_mr_ra%/*}" && printf '%s\n' "$AO_T_EPOCH" >"$_mr_ra"; } || ao_warn "cannot record $_mr_ra"
  _ao_mr_wake "$1" "$MR_B_SID"
  if [ "$1" = codex ]; then
    printf 'Mailroom (automated, not from the human): Re-arm doorbell watcher. Run your one arm command, then end the turn with no text.\nmailroom-id: rearm-%s\n' "$AO_T_STAMP" >"$_mr_msg"
  else
    printf 'Mailroom (automated, not from the human): Re-arm. Start your watcher again as your AGENTS.md says, hand off any waiting rings, then end the turn.\nmailroom-id: rearm-%s\n' "$AO_T_STAMP" >"$_mr_msg"
  fi
  : >"$_mr_out"
  if ao_bg _ao_mr_deliver "$1" "$MR_B_NAME" "$MR_B_SID" "$_mr_msg" "$_mr_out" "rearm-$AO_T_STAMP"; then
    ao_mr_event rearm "$1" - "re-arm sent to $MR_B_NAME"
    return 0
  fi
  ao_mr_event rearm-failed "$1" - "$(grep -v '^{' "$_mr_out" | tail -n 3 | tr '\n' ' ' | cut -c 1-240)"
  return 1
}

# _ao_mr_probe  Hourly free echo probes: check last hour's, send new ones.
_ao_mr_probe() {
  _mr_pd=$AO_STATE/mailroom-probe
  _mr_pt=$_mr_pd/sent
  if [ -f "$_mr_pt" ] && [ "$(ao_mr_age "$_mr_pt")" -lt "$AO_MR_PROBE_EVERY" ]; then return 0; fi
  mkdir -p "$_mr_pd" || return 0
  for _mr_side in claude codex; do
    _mr_st=$_mr_pd/last-$_mr_side
    if [ -f "$_mr_st" ] && read -r _mr_p <"$_mr_st" && ao_is_name "$_mr_p"; then
      if [ -e "$AO_MR_DIR/$_mr_side/delivered/$_mr_p" ]; then
        _ao_mr_probe_result "$_mr_side" ok "$_mr_p filed by the bridge"
      elif [ -e "$AO_MR_DIR/$_mr_side/$_mr_p" ]; then
        rm -f "$AO_MR_DIR/$_mr_side/$_mr_p"
        _ao_mr_probe_result "$_mr_side" FAIL "probe ring $_mr_p was still waiting an hour later"
      else
        _ao_mr_probe_result "$_mr_side" ok "$_mr_p gone"
      fi
    fi
    rm -f "$_mr_st"
    # Probe only a side whose bridge is registered and armed.
    if ! ao_mr_bridge "$_mr_side" || ! ao_mr_watcher_up "$_mr_side"; then continue; fi
    _mr_ext=.md
    [ "$_mr_side" != codex ] || _mr_ext=--queue.md
    _mr_t=$(mktemp "$AO_MR_DIR/$_mr_side/.tmp.XXXXXX") || continue
    printf 'Probe: no delivery needed. File it without a send.\n' >"$_mr_t"
    if _mr_p=$(ao_place "$_mr_t" "$AO_MR_DIR/$_mr_side/echo--probe-$AO_T_STAMP" "$_mr_ext"); then
      printf '%s\n' "${_mr_p##*/}" >"$_mr_st"
    else
      rm -f "$_mr_t"
    fi
  done
  : >"$_mr_pt"
}

_ao_mr_probe_result() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$AO_T_ISO" "$AO_T_EPOCH" "$1" "$2" "$3" >>"$AO_STATE/mailroom-probe.tsv"
  ao_mr_event "probe-$2" "$1" - "$3"
  [ "$2" = ok ] || _ao_mr_alarm "mailroom-probe-fail-$1" "Mailroom probe FAILED ($1): $3. The $1 bridge looks armed but is not filing rings; check it (docs/mailroom.md)." ||
    ao_warn "could not raise the $1 probe alarm"
}

# _ao_mr_prune  Drop per-ring markers whose ring is no longer waiting.
_ao_mr_prune() {
  for _mr_k in fallback direct alarmed; do
    for _mr_m in "$AO_STATE/mailroom/$_mr_k"/*; do
      [ -f "$_mr_m" ] || continue
      _mr_n=${_mr_m##*/}
      case $_mr_n in bridge-*) continue ;; esac
      [ -f "$AO_MR_DIR/claude/$_mr_n" ] || [ -f "$AO_MR_DIR/codex/$_mr_n" ] || rm -f "$_mr_m"
    done
  done
}
