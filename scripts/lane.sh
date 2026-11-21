#!/bin/sh
# lane.sh - switch an operator between clients as a scripted checklist, and
# keep one active side per operator and one active Oracle.
#
# Usage: lane.sh switch KEY --to claude|codex --session ID [--name NAME]
#        lane.sh verify KEY
#        lane.sh mark KEY STEP [--evidence TEXT | --cold REASON]
#        lane.sh ack KEY TOKEN
#        lane.sh side KEY
#        lane.sh check
#        lane.sh hold KEY|mailroom --owner WHO --until DATE --reason TEXT
#        lane.sh unhold KEY|mailroom
#        lane.sh oracle-lock [show | take CLIENT --session ID]
#
# A switch is a fixed list of steps that `verify` checks in order, so none
# can be missed (K-36). Steps the script can do or check itself it does;
# steps only a person or the app's own tools can do (titles, pins, models)
# are marked done with `mark` after they are done. The switch counts as done
# only when every step passes; `verify` then closes it.
#   handoff     the outgoing session wrote and committed a warm HANDOFF.md in
#               the home since the switch began (`switch` asks it to by an
#               inbox note); `mark KEY handoff --cold REASON` when the
#               outgoing session is gone
#   routing     the registry row names the incoming client and session (set
#               by verify once handoff passes); the incoming session gets a
#               switch-in note with a one-time token
#   watchdog    no quiet-list entry silences the operator, and no timed job
#               in JOBS.tsv still names the old session
#   labels      (mark) the incoming session is titled with the operator's
#               name; the outgoing one is retitled or archived
#   pins-claude (mark) Claude sidebar: an active operator is pinned; an
#               inactive one sits in the "Inactive Operators" section
#   pins-codex  (mark) Codex sidebar: the active side's threads are pinned,
#               the parked side's are not
#   models      (mark) the incoming session was created with the model and
#               effort recorded for its client in operator.conf
#               (model.<client>, effort.<client>; operator.sh create)
#   Marks of these four carry --evidence: the app's own readback (a sidebar
#   listing, the session's model as the app shows it), or `gap: ...` when
#   the app gives none (docs/client-capabilities.md). A receipt or an ACK
#   proves receipt, not that the app is set up.
#   switch-in   a move to the other model family has its switch-in audit
#               recorded (lease.sh audit-done, K-22); same family: passes
#   ack         the incoming session proved it received the switch-in note:
#               it ran `lane.sh ack KEY TOKEN` (from Codex the thread id must
#               match), or a note to the Oracle quotes the token
# pins-* pass by themselves when neither side of the switch is that client.
# See docs/conventions.md.
#
# side       Print `<client> <session> <name>` for KEY: the parked-side
#            guard in each home's AGENTS.md runs it first.
# check      Every operator has exactly one active side (client and
#            session); open switches, holds and the Oracle lock. Exit 1 on a
#            finding.
# hold       A hold names its owner, expiry and reason (K-07): <state_dir>/holds/KEY
#            stops the relay, the watchdog and doorbells for KEY until DATE
#            (YYYY-MM-DD inclusive, or YYYY-MM-DDTHH:MM); `mailroom` pauses
#            the mailroom supervisor instead. An expired hold is ignored and
#            reported by hygiene.sh.
# oracle-lock  <oracle_home>/operators/ORACLE-LOCK names the one active
#            Oracle (holder=client, session=, since=). `take` only on the
#            human's word (K-01).
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 done (verify: every step passes); 1 steps remain or a
# finding; 2 usage or configuration error; 3 busy; 5 refused.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"

LANE_MARKS='handoff labels pins-claude pins-codex models'
E_REFUSED=5

refuse() {
  ao_msg "refused: $*"
  exit "$E_REFUSED"
}

# lane_row KEY  Set R_NAME, R_DIR, R_SID, R_CLIENT and R_AUDIT from the
# registry (lease and audit included); fails when KEY has no row.
_lane_row_cb() {
  [ "$OP_KEY" = "$_lane_want" ] || return 0
  R_FOUND=1 R_NAME=$OP_NAME R_DIR=$OP_DIR R_SID=$OP_SID R_CLIENT=$OP_CLIENT R_AUDIT=${OP_AUDIT:--}
}
lane_row() {
  _lane_want=$1 R_FOUND='' R_NAME='' R_DIR='' R_SID='' R_CLIENT='' R_AUDIT=-
  ao_registry_each _lane_row_cb
  [ -n "$R_FOUND" ]
}

lane_key() {
  ao_is_name "${1-}" || ao_die "$AO_E_USAGE" "invalid key '${1-}'"
  ! ao_is_bridge_key "$1" || refuse "$1 is a mailroom bridge, not an operator"
  [ "$1" != "$AO_ORACLE_KEY" ] || refuse "the Oracle moves with lane.sh oracle-lock, not switch"
  lane_row "$1" || ao_die "$AO_E_USAGE" "no registry row for '$1'"
}

lane_state() { printf '%s/switch/%s\n' "$AO_STATE" "$1"; }

# st_get FILE KEY / st_set FILE KEY VALUE  key=value state, last line wins.
st_get() { [ -r "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n 1; }
st_set() {
  { [ ! -r "$1" ] || grep -v "^$2=" "$1"; printf '%s=%s\n' "$2" "$3"; } | ao_write_atomic "$1" ||
    ao_die "$AO_E_FAIL" "cannot write $1"
}

lane_family() { case $1 in claude | codex) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------- switch

lane_switch() {
  _key=${1-}
  shift || true
  _to='' _sid='' _name=''
  while [ $# -gt 0 ]; do
    case $1 in
      --to) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--to needs claude or codex"; _to=$2; shift ;;
      --session) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--session needs an id"; _sid=$2; shift ;;
      --name) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--name needs a value"; _name=$2; shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1'" ;;
    esac
    shift
  done
  lane_key "$_key"
  lane_family "$_to" || ao_die "$AO_E_USAGE" "--to must be claude or codex"
  ao_is_name "$_sid" && [ "$_sid" != pending ] && [ "$_sid" != - ] || ao_die "$AO_E_USAGE" "--session needs the incoming session or thread id"
  case $_name in *"$AO_TAB"* | *"$AO_NL"*) ao_die "$AO_E_USAGE" "--name must be one line without tabs" ;; esac
  [ "$_to" != "$R_CLIENT" ] || [ "$_sid" != "$R_SID" ] || refuse "$_key already runs on $_to in session $_sid"
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  _other=$(awk -F'\t' -v k="$_key" -v s="$_sid" '$1 !~ /^#/ && $1 != k && $4 == s { print $1; exit }' "$AO_REGISTRY")
  [ -z "$_other" ] || refuse "session $_sid already leads '$_other': one session per operator"
  _st=$(lane_state "$_key")
  [ ! -f "$_st" ] || refuse "a switch of $_key is open since $(ao_utc "$(st_get "$_st" started)"); finish it with lane.sh verify $_key, or remove $_st"
  _tok=$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')
  {
    printf 'from_client=%s\nfrom_sid=%s\nto_client=%s\nto_sid=%s\nname=%s\n' "$R_CLIENT" "$R_SID" "$_to" "$_sid" "${_name:-$R_NAME}"
    printf 'started=%s\ntoken=%s\n' "$AO_T_EPOCH" "$_tok"
  } | ao_write_atomic "$_st" || ao_die "$AO_E_FAIL" "cannot write $_st"
  # shellcheck disable=SC2016 # backticks are Markdown in the note
  printf 'Lane switch (the Oracle, by lane.sh; automated, not from the human): %s moves from %s to %s.\nBefore anything else: write a warm HANDOFF.md in your home (in flight, next steps, open asks; `lease.sh note` prints a template), commit it, and take no new work for this operator. The incoming session takes over from your HANDOFF.md.\n' \
    "$R_NAME" "$R_CLIENT" "$_to" | ao_inbox_put "$_key" lane-switch >/dev/null
  echo "switch opened for $_key: $R_CLIENT -> $_to ($_sid); the outgoing session was asked for a warm handoff."
  echo "Next: lane.sh verify $_key (repeat until every step passes)."
}

# ---------------------------------------------------------------- verify

# lane_registry_set KEY CLIENT SESSION NAME  Rewrite one registry row.
lane_registry_set() {
  _tmp=$(ao_tmp registry)
  awk -F'\t' -v OFS='\t' -v k="$1" -v c="$2" -v s="$3" -v n="$4" '
    $1 == k { $4 = s; $5 = c; if (n != "") $2 = n }
    { print }' "$AO_REGISTRY" >"$_tmp" && ao_write_atomic "$AO_REGISTRY" <"$_tmp"
}

# lane_say STATE STEP TEXT
lane_say() { printf '%-5s %-12s %s\n' "$1" "$2" "$3"; [ "$1" = PASS ] || _left=$((_left + 1)); }

lane_marked() { [ -n "$(st_get "$_st" "done_$1")" ]; }

lane_verify() {
  lane_key "${1-}"
  _key=$1
  _st=$(lane_state "$_key")
  [ -f "$_st" ] || ao_die "$AO_E_USAGE" "no open switch for $_key (lane.sh switch first)"
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  _fc=$(st_get "$_st" from_client) _fs=$(st_get "$_st" from_sid)
  _tc=$(st_get "$_st" to_client) _ts=$(st_get "$_st" to_sid)
  _nm=$(st_get "$_st" name) _since=$(st_get "$_st" started) _tok=$(st_get "$_st" token)
  ao_is_uint "${_since:-x}" || ao_die "$AO_E_FAIL" "unreadable switch record $_st"
  _left=0
  printf 'Switch of %s: %s (%s) -> %s (%s), opened %s UTC\n' "$_key" "$_fc" "$_fs" "$_tc" "$_ts" "$(ao_utc "$_since")"
  # handoff
  _hc=$(git -C "$R_DIR" log --since="@$_since" --format=%ct -1 -- HANDOFF.md 2>/dev/null)
  if [ -n "$_hc" ]; then lane_say PASS handoff "HANDOFF.md committed $(ao_utc "$_hc") UTC"
  elif lane_marked handoff; then lane_say PASS handoff "$(st_get "$_st" done_handoff | cut -d ' ' -f 2-)"
  else lane_say WAIT handoff "the outgoing session has not committed HANDOFF.md in $R_DIR yet (gone? lane.sh mark $_key handoff --cold REASON)"; fi
  # routing
  if [ "$R_CLIENT" = "$_tc" ] && [ "$R_SID" = "$_ts" ]; then
    lane_say PASS routing "registry: $_tc $_ts"
  elif [ "$_left" -eq 0 ] && _dup=$(awk -F'\t' -v k="$_key" -v s="$_ts" '$1 !~ /^#/ && $1 != k && $4 == s { print $1; exit }' "$AO_REGISTRY") && [ -n "$_dup" ]; then
    lane_say TODO routing "session $_ts now leads '$_dup': one session per operator; fix the registry or switch to another session"
  elif [ "$_left" -eq 0 ]; then
    # A move to the other family with no audit record yet (cross-review has
    # not seen this operator): record the change itself, so the switch-in
    # audit is pending at once instead of the new client becoming the
    # baseline (K-22).
    ao_audit_read "$_key"
    if [ $? -eq 1 ] && lane_family "$_fc" && lane_family "$_tc" && [ "$_fc" != "$_tc" ]; then
      A_provider=$_tc A_from=$_fc A_to=$_tc A_change=1 A_since=$(ao_utc "$AO_T_EPOCH")
      _ao_audit_put "$(ao_audit_file "$_key")" || ao_die "$AO_E_FAIL" "cannot record the switch-in audit for $_key"
    fi
    lane_registry_set "$_key" "$_tc" "$_ts" "$_nm" || ao_die "$AO_E_FAIL" "cannot update $AO_REGISTRY"
    lane_row "$_key"
    lane_say PASS routing "registry updated: $_tc $_ts"
  else
    lane_say WAIT routing "applied once the handoff passes"
  fi
  if [ "$R_SID" = "$_ts" ] && [ -z "$(st_get "$_st" note_sent)" ]; then
    # shellcheck disable=SC2016 # backticks are Markdown in the note
    printf 'Lane switch (the Oracle, by lane.sh; automated, not from the human): you are now the active side for %s (%s). Read HANDOFF.md first, then MANDATE.md and NOTES.md. Prove you received this: run `sh %s/lane.sh ack %s %s` from your session (or reply to the Oracle quoting %s). Triage the switch-in audit when it arrives (K-22).\n' \
      "$_key" "$_tc" "$AO_SCRIPTS" "$_key" "$_tok" "$_tok" | ao_inbox_put "$_key" lane-switch-in >/dev/null &&
      st_set "$_st" note_sent "$AO_T_EPOCH"
  fi
  # watchdog
  _q=$(ao_quiet_until "$_key" "$R_NAME")
  _j=$AO_HOME/JOBS.tsv
  if [ -n "$_q" ]; then lane_say TODO watchdog "a quiet-list entry silences $_key until $_q: remove it from $AO_QUIET"
  elif [ -n "$_fs" ] && [ "$_fs" != "$_ts" ] && [ -r "$_j" ] && grep -qF -- "$_fs" "$_j"; then lane_say TODO watchdog "$_j still names the old session $_fs"
  else lane_say PASS watchdog "the stall watch follows the registry; no quiet entry, no job on the old session"; fi
  # in-app steps
  for _m in labels pins-claude pins-codex models; do
    if lane_marked "$_m"; then lane_say PASS "$_m" "$(st_get "$_st" "done_$_m" | cut -d ' ' -f 2-)"; continue; fi
    case $_m in
      labels) _do="title the $_tc session \"$_nm\"; retitle or archive the $_fc one" ;;
      pins-claude)
        if [ "$_tc" != claude ] && [ "$_fc" != claude ]; then lane_say PASS "$_m" "no Claude side"; continue; fi
        if [ "$_tc" = claude ]; then _do="pin the Claude session; take it out of \"Inactive Operators\""
        else _do="unpin the Claude session; move it to \"Inactive Operators\""; fi ;;
      pins-codex)
        if [ "$_tc" != codex ] && [ "$_fc" != codex ]; then lane_say PASS "$_m" "no Codex side"; continue; fi
        if [ "$_tc" = codex ]; then _do="pin the Codex thread"; else _do="unpin the Codex thread"; fi ;;
      models)
        _om=$(sed -n "s/^model\.$_tc=//p" "$R_DIR/operator.conf" 2>/dev/null | tail -n 1)
        _oe=$(sed -n "s/^effort\.$_tc=//p" "$R_DIR/operator.conf" 2>/dev/null | tail -n 1)
        if [ -n "$_om" ]; then _do="create the $_tc session with model $_om${_oe:+ and effort $_oe} (operator.conf), set at creation, never by a message"
        else _do="decide the $_tc model with the owner (operator.sh model $_key --client $_tc ...), then create the session with it"; fi ;;
    esac
    lane_say TODO "$_m" "$_do, then: lane.sh mark $_key $_m --evidence '<the app's readback, or gap: ...>'"
  done
  # switch-in
  if [ "$_fc" = "$_tc" ] || ! lane_family "$_fc"; then lane_say PASS switch-in "same model family: no audit"
  elif [ "$R_AUDIT" = "done" ]; then lane_say PASS switch-in "audit recorded"
  else lane_say WAIT switch-in "audit $R_AUDIT: cross-review.sh writes it, the incoming session records it with lease.sh audit-done"; fi
  # ack
  _ack=$(st_get "$_st" ack)
  if [ -n "$_ack" ]; then lane_say PASS ack "$(printf '%s' "$_ack" | cut -d ' ' -f 2-)"
  elif _r=$(lane_reply "$_since" "$_tok"); then lane_say PASS ack "token quoted in ${_r##*/}"
  elif [ -n "$(st_get "$_st" note_sent)" ]; then lane_say WAIT ack "the incoming session has not acknowledged the switch-in note"
  else lane_say WAIT ack "sent once routing passes"; fi
  if [ "$_left" -gt 0 ]; then
    printf '%s step(s) left.\n' "$_left"
    exit "$AO_E_FAIL"
  fi
  mkdir -p "$AO_STATE/switch/done" && mv -f "$_st" "$AO_STATE/switch/done/$_key.$AO_T_STAMP"
  ao_inbox_put "$AO_ORACLE_KEY" lane-switched >/dev/null <<EOF || true
Lane switch done (lane.sh verify, every step passed): $_key now runs on $_tc ($_ts). Record: $AO_STATE/switch/done/$_key.$AO_T_STAMP
EOF
  echo "switch of $_key complete."
}

# lane_reply SINCE TOKEN  Print a note to the Oracle placed since SINCE that
# quotes TOKEN (inbox or the relay's archive).
lane_reply() {
  for _f in "$AO_INBOX/$AO_ORACLE_KEY"/*.md "$AO_SENT"/*-"$AO_ORACLE_KEY"-*.md; do
    [ -f "$_f" ] || continue
    [ "$(ao_mtime "$_f")" -ge "$1" ] || continue
    grep -qF -- "$2" "$_f" && { printf '%s\n' "$_f"; return 0; }
  done
  return 1
}

lane_mark() {
  lane_key "${1-}"
  _key=$1 _step=${2-}
  shift 2 2>/dev/null || ao_die "$AO_E_USAGE" "usage: lane.sh mark KEY STEP [--evidence TEXT | --cold REASON]"
  case " $LANE_MARKS " in *" $_step "*) ;; *) ao_die "$AO_E_USAGE" "STEP must be one of: $LANE_MARKS" ;; esac
  if [ "$_step" = handoff ]; then
    if [ "${1-}" != --cold ] || [ -z "${2-}" ]; then ao_die "$AO_E_USAGE" "handoff is checked from git; mark it only as: lane.sh mark KEY handoff --cold REASON"; fi
    _note="cold: $2"
  else
    if [ "${1-}" != --evidence ] || [ -z "${2-}" ]; then ao_die "$AO_E_USAGE" "$_step needs --evidence: the app's own readback, or 'gap: <why there is none>'"; fi
    _note="evidence: $2"
  fi
  _note=$(printf '%s' "$_note" | tr '\t\n' '  ')
  _st=$(lane_state "$_key")
  [ -f "$_st" ] || ao_die "$AO_E_USAGE" "no open switch for $_key"
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  st_set "$_st" "done_$_step" "$AO_T_EPOCH $_note"
  echo "marked $_step for $_key"
}

lane_ack() {
  lane_key "${1-}"
  _key=$1 _tok=${2-}
  _st=$(lane_state "$_key")
  [ -f "$_st" ] || ao_die "$AO_E_USAGE" "no open switch for $_key"
  [ -n "$_tok" ] && [ "$_tok" = "$(st_get "$_st" token)" ] || refuse "wrong token for $_key"
  _tc=$(st_get "$_st" to_client) _ts=$(st_get "$_st" to_sid)
  # Which client is asking: a Codex command session carries its thread id,
  # a Claude Code shell carries CLAUDECODE.
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    [ "$_tc" = codex ] && [ "$CODEX_THREAD_ID" = "$_ts" ] || refuse "this Codex thread is not the incoming session ($_tc $_ts)"
    _how="acknowledged from Codex thread $_ts"
  elif [ -n "${CLAUDECODE:-}" ]; then
    [ "$_tc" = claude ] || refuse "this is a Claude session; the incoming side is $_tc"
    _how="acknowledged from a Claude session"
  else
    _how="acknowledged (client not detectable)"
  fi
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  st_set "$_st" ack "$AO_T_EPOCH $_how"
  echo "$_how"
}

lane_side() {
  ao_is_name "${1-}" || ao_die "$AO_E_USAGE" "usage: lane.sh side KEY"
  lane_row "$1" || ao_die "$AO_E_USAGE" "no registry row for '$1'"
  printf '%s %s %s\n' "$R_CLIENT" "$R_SID" "$R_NAME"
}

# ---------------------------------------------------------------- check

_lane_check_cb() {
  ao_is_bridge_key "$OP_KEY" && return 0
  case $OP_SID in '' | - | pending)
    printf 'no active side: %s has no session in the registry\n' "$OP_KEY"; _bad=1; return 0 ;;
  esac
  printf 'ok: %s on %s (%s)\n' "$OP_KEY" "$OP_CLIENT" "$OP_SID"
}

lane_check() {
  _bad=0
  ao_registry_each _lane_check_cb
  # A session id may lead one operator only.
  _dup=$(awk -F'\t' '$1 !~ /^#/ && $4 != "" && $4 != "-" && $4 != "pending" { print $4 }' "$AO_REGISTRY" | sort | uniq -d)
  [ -z "$_dup" ] || { printf 'one session on several rows: %s\n' "$_dup"; _bad=1; }
  for _s in "$AO_STATE/switch"/*; do
    [ -f "$_s" ] || continue
    _at=$(st_get "$_s" started)
    printf 'open switch: %s since %s UTC (lane.sh verify %s)\n' "${_s##*/}" "$(ao_utc "${_at:-0}")" "${_s##*/}"
    _bad=1
  done
  for _h in "$AO_STATE/holds"/* "$AO_STATE/mailroom-pause"; do
    [ -f "$_h" ] || continue
    if ao_hold_active "$_h"; then
      printf 'hold: %s by %s until %s%s\n' "${_h##*/}" "$AO_H_OWNER" "$AO_H_UNTIL" "${AO_H_REASON:+ ($AO_H_REASON)}"
    else
      printf 'hold not honoured (expired, or no owner, expiry or reason): %s (lane.sh unhold %s)\n' "$_h" "${_h##*/}"
      _bad=1
    fi
  done
  _lk=$AO_HOME/operators/ORACLE-LOCK
  if [ ! -f "$_lk" ]; then printf 'no Oracle lock: %s (lane.sh oracle-lock take CLIENT --session ID)\n' "$_lk"; _bad=1
  else
    _hold=$(sed -n 's/^holder=//p' "$_lk" | head -n 1)
    if lane_family "$_hold"; then printf 'oracle: %s (%s)\n' "$_hold" "$(sed -n 's/^session=//p' "$_lk" | head -n 1)"
    else printf 'Oracle lock has no valid holder: %s\n' "$_lk"; _bad=1; fi
  fi
  exit "$_bad"
}

# ---------------------------------------------------------------- holds

lane_hold_file() {
  if [ "$1" = mailroom ]; then printf '%s/mailroom-pause\n' "$AO_STATE"
  else
    if ! ao_is_name "$1" || ! ao_registry_has "$1"; then ao_die "$AO_E_USAGE" "no registry row for '$1'"; fi
    printf '%s/holds/%s\n' "$AO_STATE" "$1"
  fi
}

lane_hold() {
  [ $# -ge 1 ] || ao_die "$AO_E_USAGE" "usage: lane.sh hold KEY|mailroom --owner WHO --until DATE --reason TEXT"
  _f=$(lane_hold_file "$1")
  shift
  _o='' _u='' _r=''
  while [ $# -gt 0 ]; do
    case $1 in
      --owner | --until | --reason)
        [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "$1 needs a value"
        case $2 in *"$AO_NL"*) ao_die "$AO_E_USAGE" "$1 must be one line" ;; esac
        case $1 in --owner) _o=$2 ;; --until) _u=$2 ;; --reason) _r=$2 ;; esac
        shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1'" ;;
    esac
    shift
  done
  [ -n "$_o" ] && [ -n "$_r" ] || ao_die "$AO_E_USAGE" "a hold names its owner, expiry and reason (--owner, --until, --reason; K-07)"
  _tmp=$(ao_tmp hold)
  printf 'owner=%s\nuntil=%s\nreason=%s\nset=%s\n' "$_o" "$_u" "$_r" "$AO_T_ISO" >"$_tmp"
  ao_hold_active "$_tmp" || ao_die "$AO_E_USAGE" "--until must be today or later: YYYY-MM-DD or YYYY-MM-DDTHH:MM"
  ao_write_atomic "$_f" <"$_tmp" || ao_die "$AO_E_FAIL" "cannot write $_f"
  echo "held: ${_f##*/} by $_o until $_u"
}

lane_unhold() {
  _f=$(lane_hold_file "${1-}")
  [ -f "$_f" ] || { echo "no hold: ${1-}"; return 0; }
  rm -f "$_f" && echo "released: ${1-}"
}

# ---------------------------------------------------------------- oracle lock

lane_oracle_lock() {
  _lk=$AO_HOME/operators/ORACLE-LOCK
  case ${1:-show} in
    show) [ -f "$_lk" ] || ao_die "$AO_E_FAIL" "no Oracle lock: $_lk"; cat "$_lk" ;;
    take)
      lane_family "${2-}" || ao_die "$AO_E_USAGE" "usage: lane.sh oracle-lock take claude|codex --session ID"
      if [ "${3-}" != --session ] || ! ao_is_name "${4-}"; then ao_die "$AO_E_USAGE" "usage: lane.sh oracle-lock take claude|codex --session ID"; fi
      printf 'holder=%s\nsession=%s\nsince=%s\nnote=The one active Oracle (K-13). Only the holder acts as Oracle; the other client stays dormant and redirects. Change only on the human'"'"'s word.\n' \
        "$2" "$4" "$AO_T_ISO" | ao_write_atomic "$_lk" || ao_die "$AO_E_FAIL" "cannot write $_lk"
      echo "Oracle lock: $2 ($4)" ;;
    *) ao_die "$AO_E_USAGE" "usage: lane.sh oracle-lock [show | take CLIENT --session ID]" ;;
  esac
}

main() {
  case ${1-} in
    -h | --help) ao_usage; exit 0 ;;
    '') ao_usage; exit "$AO_E_USAGE" ;;
  esac
  cmd=$1
  shift
  ao_load
  case $cmd in
    switch) lane_switch "$@" ;;
    verify) lane_verify "$@" ;;
    mark) lane_mark "$@" ;;
    ack) lane_ack "$@" ;;
    side) lane_side "$@" ;;
    check) lane_check ;;
    hold) lane_hold "$@" ;;
    unhold) lane_unhold "$@" ;;
    oracle-lock) lane_oracle_lock "$@" ;;
    *) ao_die "$AO_E_USAGE" "unknown command '$cmd' (see --help)" ;;
  esac
}

main "$@"
