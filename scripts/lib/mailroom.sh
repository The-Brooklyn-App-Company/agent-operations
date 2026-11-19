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
#   claude  <session>--<key>-<stamp>-<rand>.md
#   codex   <thread>--<key>-<stamp>-<rand>--<steer|queue>.md
#   (a doorbell's key is `.doorbell`, never an operator key)
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
AO_MR_REARM_EVERY=3600    # re-arm per clock hour where the app pid is unknown; relaunch spacing
# The desktop apps (public bundle ids), for the re-arm-per-app-process rule.
AO_MR_APP_CLAUDE=com.anthropic.claudefordesktop
AO_MR_APP_CODEX=com.openai.codex
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

# ao_mr_file SIDE RING BY MODE [STATUS [FROM]]  Move a ring (waiting, or in
# folder FROM) to delivered/ and append its line to delivered/log.tsv.
# Fails if the ring is gone.
ao_mr_file() {
  _mr_src=${6:-$AO_MR_DIR/$1}/$2
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
#   2. Bridges (rows mailroom-claude, mailroom-codex): see
#      _ao_mr_bridge_check: one re-arm per app process, then one alarm; an
#      app that is not running is opened in the background.
#   3. Hourly echo probes (free): a probe ring per side, filed by the live
#      watcher without a send or a model turn; checked at the next probe.
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

_ao_mr_rings() {
  _mr_rf=0
  for _mr_side in claude codex; do
    # A claim left by an interrupted run: the send may have happened, so it
    # is filed as unknown and never sent again (K-28).
    for _mr_c in "$AO_MR_DIR/$_mr_side/.claimed"/*.md; do
      [ -f "$_mr_c" ] || continue
      [ -n "$_mr_dry" ] && continue
      ao_mr_file "$_mr_side" "${_mr_c##*/}" supervisor - unknown "${_mr_c%/*}" || continue
      ao_mr_event unknown "$_mr_side" "${_mr_c##*/}" "interrupted fallback; not sent again"
      _ao_mr_alarm "mailroom-unknown-$_mr_side" "Mailroom: a fallback for ${_mr_c##*/} was interrupted; it may or may not have arrived and is not sent again. Check the target (docs/mailroom.md)." ||
        ao_warn "could not raise the unknown-delivery alarm"
    done
    # Unknown outcomes the Codex watcher recorded: one alarm each, then cleared.
    if [ "$_mr_side" = codex ] && [ -z "$_mr_dry" ]; then
      for _mr_u in "$AO_MR_DIR/codex/.watcher/unknown"/*.md; do
        [ -f "$_mr_u" ] || continue
        ao_mr_event unknown codex "${_mr_u##*/}" "watcher send outcome unknown; not sent again"
        _ao_mr_alarm "mailroom-unknown-codex" "Mailroom: the Codex watcher could not confirm ${_mr_u##*/}; it may or may not have arrived and is not sent again. Check the target thread (docs/mailroom.md)." &&
          rm -f "$_mr_u"
      done
    fi
    # A Codex send cut off with the watcher down may have landed: filed as
    # unknown, never sent again, and one alarm.
    if [ "$_mr_side" = codex ] && [ -z "$_mr_dry" ] && ! ao_mr_watcher_up codex; then
      for _mr_c in "$AO_MR_DIR/codex/.watcher/sending"/*.md; do
        [ -f "$_mr_c" ] || continue
        ao_mr_file codex "${_mr_c##*/}" watcher interrupted unknown "${_mr_c%/*}" || continue
        ao_mr_event unknown codex "${_mr_c##*/}" "send interrupted with the watcher down; not sent again"
        _ao_mr_alarm "mailroom-unknown-codex" "Mailroom: the Codex watcher stopped while sending ${_mr_c##*/}; it may or may not have arrived and is not sent again. Check the target thread (docs/mailroom.md)." ||
          ao_warn "could not raise the unknown-delivery alarm"
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
      if [ "$_mr_side" = codex ] && ao_mr_held "$_mr_b"; then continue; fi
      _ao_mr_route
      case $? in 1) ;; 2) continue ;; *)
        if [ "$_mr_side" = claude ]; then
          _ao_mr_ring_claude || _mr_rf=1
        else
          _ao_mr_ring_codex || _mr_rf=1
        fi ;;
      esac
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
  _ao_mr_claim || return 0
  _ao_mr_wake claude "$_mr_sid"
  _mr_id=$(sed -n 's/^relay-id: //p;s/^doorbell-id: //p' "$_mr_c" | head -n 1)
  : >"$_mr_out"
  if ao_bg _ao_mr_deliver claude "$_mr_name" "$_mr_sid" "$_mr_c" "$_mr_out" "${_mr_id:-$_mr_b}"; then
    _mr_w=
    [ "$(head -c 8 "$_mr_out")" != warning: ] || _mr_w=" with a warning: $(head -n 1 "$_mr_out")"
    ao_mr_file claude "$_mr_b" fallback - ok "${_mr_c%/*}" || ao_warn "cannot file $_mr_b"
    ao_mr_event fallback-ok claude "$_mr_b" "bridge stuck or down: delivered directly to $_mr_name$_mr_w"
    return 0
  fi
  _ao_mr_unclaim
  ao_mr_event fallback-failed claude "$_mr_b" "$(grep -v '^{' "$_mr_out" | tail -n 3 | tr '\n' ' ' | cut -c 1-240)"
  return 1
}

_ao_mr_ring_codex() {
  [ "$_mr_age" -ge "$AO_MR_CODEX_FALLBACK" ] || return 0
  _ao_mr_attempt_due direct "$_mr_b" || return 0
  _mr_mode=queue
  case $_mr_b in *--steer.md) _mr_mode=steer ;; esac
  _ao_mr_claim || return 0
  {
    printf 'Doorbell [%s] (mailroom fallback, queued): ' "$_mr_b"
    cat "$_mr_c"
  } >"$_mr_msg"
  : >"$_mr_out"
  _ao_mr_attempt_count direct "$_mr_b"
  if ao_bg _ao_mr_deliver codex "$_mr_sid" "$_mr_sid" "$_mr_msg" "$_mr_out" "$_mr_b"; then
    ao_mr_file codex "$_mr_b" queue-direct queue accepted "${_mr_c%/*}" || ao_warn "cannot file $_mr_b"
    ao_mr_event queue-direct codex "$_mr_b" "queued to the target (no steering; was $_mr_mode)"
    return 0
  fi
  # The CLI ran and did not confirm: it may have queued (K-28). Only a
  # failure before the CLI ran puts the ring back for another attempt.
  if grep -q 'queue acceptance unconfirmed' "$_mr_out" 2>/dev/null; then
    ao_mr_file codex "$_mr_b" queue-direct queue unknown "${_mr_c%/*}" || ao_warn "cannot file $_mr_b"
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
# only doorbells (key .doorbell) are delivered as named.
_ao_mr_route_cb() {
  [ "$OP_KEY" = "$_mr_key" ] || return 0
  _mr_found=1 _mr_osid=$OP_SID _mr_ocl=$OP_CLIENT _mr_ogate=0
  ao_gate relay || _mr_ogate=1
}
_ao_mr_route() {
  _mr_key=${_mr_b#*--}
  _mr_key=${_mr_key%--steer.md}
  _mr_key=${_mr_key%--queue.md}
  _mr_key=$(printf '%s\n' "${_mr_key%.md}" | sed 's/-[0-9]\{8\}T[0-9]\{6\}\(-[0-9a-f]\{6\}\)\{0,1\}\(-[0-9]\{1,3\}\)\{0,1\}$//')
  _mr_found='' _mr_osid='' _mr_ocl='' _mr_ogate=0
  [ "$_mr_key" != .doorbell ] || return 0
  ao_is_name "$_mr_key" && ao_registry_has "$_mr_key" || return 1
  ao_registry_each _ao_mr_route_cb
  [ -n "$_mr_found" ] || return 1
  [ "$_mr_ogate" -eq 0 ] || return 1
  [ "$_mr_ocl" != "$_mr_side" ] || [ "$_mr_osid" != "$_mr_sid" ] || return 0
  case $_mr_ocl in claude | codex) ;; *) return 1 ;; esac
  ao_mr_addressable "$_mr_osid" || return 1
  _mr_nm=queue
  case $_mr_b in *--steer.md) _mr_nm=steer ;; esac
  _ao_mr_claim || return 2
  if _mr_new=$(ao_mr_ring "$_mr_ocl" "$_mr_osid" "$_mr_key" "$_mr_nm" <"$_mr_c"); then
    ao_mr_file "$_mr_side" "$_mr_b" supervisor rerouted ok "${_mr_c%/*}"
    ao_mr_event rerouted "$_mr_side" "$_mr_b" "owner of $_mr_key moved to $_mr_ocl; new ring ${_mr_new##*/}"
    return 2
  fi
  _ao_mr_unclaim
  return 1
}

# _ao_mr_app_pid BUNDLE  Print the desktop app's pid, `none` when it is not
# running, or nothing when this host cannot tell (no lsappinfo: not macOS).
_ao_mr_app_pid() {
  command -v lsappinfo >/dev/null 2>&1 || return 0
  _mr_ap=$(lsappinfo info -only pid -app "$1" 2>/dev/null |
    sed -n 's/.*pid"\{0,1\} *= *\([0-9][0-9]*\).*/\1/p' | head -n 1)
  printf '%s\n' "${_mr_ap:-none}"
}

# _ao_mr_bridge_check SIDE  Keep one bridge armed. A watcher that is not
# armed (app restart, watcher crash) gets one re-arm per app process (the
# app's pid; where it cannot be read, per clock hour): hooks/wake, then a
# fixed "Re-arm" message through the relay transport, carrying no mail. Still
# down AO_MR_REARM_GRACE after that re-arm: one alarm per episode. An app
# that is not running at all (a reboot) is opened in the background, at most
# once an hour. The Codex watcher is managed once deployed (its log exists).
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
    mkdir -p "${_mr_down%/*}" && printf '%s\n' "$AO_T_EPOCH" >"$_mr_down"
    ao_mr_event bridge-down "$1" - "watcher not armed"
  fi
  if [ "$1" = claude ]; then _mr_bundle=$AO_MR_APP_CLAUDE; else _mr_bundle=$AO_MR_APP_CODEX; fi
  _mr_app=$(_ao_mr_app_pid "$_mr_bundle")
  if [ "$_mr_app" = none ]; then
    _mr_lm=$(_ao_mr_marker launched "$1")
    if [ ! -f "$_mr_lm" ] || [ "$(ao_mr_age "$_mr_lm")" -ge "$AO_MR_REARM_EVERY" ]; then
      mkdir -p "${_mr_lm%/*}" && : >"$_mr_lm"
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
      if mkdir -p "${_mr_bam%/*}" && : >"$_mr_bam"; then ao_mr_event alarm "$1" - "app not running"; fi
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
      if mkdir -p "${_mr_bam%/*}" && : >"$_mr_bam"; then
        ao_mr_event alarm "$1" - "bridge still down after re-arm"
      else
        ao_warn "cannot record $_mr_bam"
      fi
    fi
    return 0
  fi
  { mkdir -p "${_mr_ra%/*}" && printf '%s %s\n' "$AO_T_EPOCH" "$_mr_key" >"$_mr_ra"; } || ao_warn "cannot record $_mr_ra"
  _ao_mr_wake "$1" "$MR_B_SID"
  if [ "$1" = codex ]; then
    printf 'Mailroom (automated, not from the human): Re-arm doorbell watcher. Run your one arm command, then end the turn with no text.\nmailroom-id: rearm-%s\n' "$AO_T_STAMP" >"$_mr_msg"
  else
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
      [ -f "$AO_MR_DIR/claude/$_mr_n" ] || [ -f "$AO_MR_DIR/codex/$_mr_n" ] ||
        [ -f "$AO_MR_DIR/claude/.watcher/handing/$_mr_n" ] || rm -f "$_mr_m"
    done
  done
}
