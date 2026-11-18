#!/bin/sh
# lease.sh - EXPERIMENTAL: the advisory lease that says which session holds
# an operator (one holder, one standby, across Claude Code and Codex).
#
# Usage: lease.sh [--home DIR] VERB [OPTIONS]
#
# Session verbs (run by the agent, in the operator home):
#   acquire --provider P --session NAME [--session-id ID] [--instance TOKEN]
#           Take a released or absent lease, or one a takeover assigned to
#           this provider and session. Prints the instance token ONCE:
#           keep it in the conversation and present it on every holder verb.
#           A replay with the holder's --instance returns the same epoch.
#   renew   --instance T --epoch N   First step of every turn. Failure (exit
#           5) means this session is the standby: do no work.
#   check   --instance T --epoch N   Exit 0 only for the holder.
#   dispatch-begin --instance T --epoch N --what TEXT [--ask ID] [--pid PID]
#           Under the lease lock: validate the holder and create a dispatch
#           marker, before any effect. Prints `marker: ID`. PID (default:
#           the caller) is the process doing the effect.
#   dispatch-end --instance T --epoch N --marker ID   Remove the marker.
#   dispatch-run --instance T --epoch N --what TEXT [--ask ID] -- CMD [ARG...]
#           The kit wrapper: begin (this process is the marker's pid), run
#           CMD, end on exit 0. A failed or interrupted CMD leaves the marker:
#           its effect is unknown until the human settles it.
#   note    --instance T --epoch N   Print a warm HANDOFF.md template.
#   release --instance T --epoch N   Needs a committed-or-committable warm
#           HANDOFF.md for this epoch and no markers; commits it, then
#           releases. Idempotent after a crash.
#   redirect --provider P   The standby's reply text (and the takeover offer
#           when the holder looks down).
#   status  [--evidence]    Holder, heartbeat age, markers, mail, lock;
#           --evidence adds the work-repo state a takeover shows.
#   audit-brief [--instance T --epoch N]   The switch-in audit checklist,
#           evidence and the incoming family's headless report, if written.
#           Required first step after a move to the other model family.
#   audit-done  [--instance T --epoch N] --report PATH   Record the committed
#           audit report (path and commit); until then dispatch and new asks
#           are refused. With a lease, only its holder; without one, for a
#           registry change that cross-review.sh recorded (needs AO_PROFILE).
#   init    Create .operator/ (inbox, markers); idempotent.
#
# Human verbs (refused inside an agent's tool shell and without a terminal;
# each asks for a typed confirmation on /dev/tty):
#   takeover --expect-epoch N --holder-stopped --provider P --session NAME
#           [--session-id ID] [--expect-generation G]
#           Move a down holder's lease to the named session: builds and
#           commits a cold HANDOFF.md, puts reserved asks on hold, bumps the
#           epoch and assigns the lease; that session then runs acquire.
#           Refused while any dispatch marker exists or the recorded client
#           process still runs.
#   settle  --marker ID --outcome landed|not-landed|unknown
#           Settle a marker whose process died (an unresolved effect).
#   unlock  --timers-off --sessions-stopped   Remove a stuck lease lock.
#
# The home is --home, else $AO_OPERATOR_HOME, else the nearest directory at
# or above $PWD with an operator.conf. The profile (AO_PROFILE) is optional
# here; it supplies lease_stale, work_root, the Oracle inbox for alerts and
# the state dir where registry switch-in audits are recorded.
#
# Exit codes: 0 ok; 1 runtime failure; 2 usage; 3 lease lock busy or stuck
# (fail closed); 5 refused by the lease (not the holder, wrong epoch, marker
# present, confirmation missing).
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"

refuse() {
  ao_msg "refused: $*"
  exit "$AO_E_REFUSED"
}

lease_profile() {
  if [ -r "$(ao_profile_path)" ]; then ao_load --no-state; else ao_clock; fi
}

# lease_stale_secs  lease_stale: Nh, Nm or N (minutes); default 4h.
lease_stale_secs() {
  _v=$(ao_cfg lease_stale 4h)
  case $_v in
    *h) _n=${_v%h} _m=3600 ;;
    *m) _n=${_v%m} _m=60 ;;
    *) _n=$_v _m=60 ;;
  esac
  ao_is_uint "$_n" || ao_die "$AO_E_USAGE" "lease_stale: expected Nh, Nm or minutes, got '$_v'"
  echo $((_n * _m))
}

need_token() {
  [ -n "$o_instance" ] && [ -n "$o_epoch" ] || ao_die "$AO_E_USAGE" "$verb needs --instance TOKEN and --epoch N"
}

standby() {
  ao_msg "not the holder: $(ao_lease_describe)"
  ao_msg "You are the standby: do no work, no edits, no effects, no asks. Reply with 'lease.sh redirect'; forward only a direct human turn, once (mail.sh forward)."
  exit "$AO_E_REFUSED"
}

need_holder() {
  need_token
  ao_lease_holder "$o_instance" "$o_epoch" || standby
}

set_client_pid() {
  _me=$(ao_client_pid "$1")
  if [ -n "$_me" ]; then L_client_pid=${_me%% *} L_client_start=${_me#* }; else L_client_pid=- L_client_start=-; fi
}

stamp_heartbeat() {
  L_heartbeat=$(ao_utc "$AO_T_EPOCH")
  L_heartbeat_epoch=$AO_T_EPOCH
}

lock() {
  ao_lease_lock || exit "$AO_E_BUSY"
}

markers_present() {
  [ -n "$(ao_markers_open)" ]
}

mail_counts() {
  _new=$(count_dir "$H_OP/inbox/new") _cur=$(count_dir "$H_OP/inbox/cur")
  printf '%s new, %s unacked in cur/\n' "$_new" "$_cur"
}

count_dir() {
  _c=0
  for _f in "$1"/*; do [ -f "$_f" ] && _c=$((_c + 1)); done
  echo "$_c"
}

check_text() {
  ao_text_ok "$2" || ao_die "$AO_E_USAGE" "$1 must be one line with no tab or '|'"
}

check_provider() {
  ao_is_name "$o_provider" || ao_die "$AO_E_USAGE" "$verb needs --provider (claude, codex, ...)"
  check_text --session "$o_session"
  [ -z "$o_session_id" ] || ao_is_name "$o_session_id" || ao_die "$AO_E_USAGE" "--session-id must be [A-Za-z0-9._-]"
}

# confirm_tty PHRASE  The human types PHRASE on the controlling terminal.
confirm_tty() {
  if ! (exec 4</dev/tty) 2>/dev/null; then
    refuse "$verb must be confirmed by a human at a terminal (no /dev/tty here). Run it in your own terminal; agents are denied this command by the settings pattern"
  fi
  exec 4</dev/tty
  printf 'To confirm, type exactly: %s\n> ' "$1" >/dev/tty
  IFS= read -r _ans <&4 || _ans=
  exec 4<&-
  _ans=$(printf '%s' "$_ans" | tr -d '\r')
  [ "$_ans" = "$1" ] || refuse "confirmation did not match; nothing changed"
}

human_only() {
  ! ao_agent_env || refuse "$verb is human-only: run it in your own terminal, not through an agent's tool shell"
}

# ---------------------------------------------------------------- notes

handoff_header() {
  sed -n '1p' "$H_HOME/HANDOFF.md" 2>/dev/null
}

repo_state() {
  echo "- $1 ($2) $3"
  _br=$(git -C "$3" symbolic-ref --short -q HEAD 2>/dev/null) || _br='(detached)'
  _head=$(git -C "$3" rev-parse --short=12 HEAD 2>/dev/null) || _head=none
  _up=$(git -C "$3" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || _up=
  _track=
  if [ -n "$_up" ] && _lr=$(git -C "$3" rev-list --left-right --count "$_up...HEAD" 2>/dev/null); then
    # shellcheck disable=SC2086 # two counts from rev-list
    set -- "$1" "$2" "$3" $_lr
    if [ "$5" -eq 0 ]; then _track='; pushed'; else _track="; $5 unpushed"; fi
    [ "$4" -eq 0 ] || _track="$_track, $4 behind"
  fi
  echo "  - branch $_br at $_head; upstream ${_up:-none}$_track"
  _dirty=$(git -C "$3" status --porcelain 2>/dev/null | cut -c4- | LC_ALL=C sort)
  if [ -n "$_dirty" ]; then
    _n=$(printf '%s\n' "$_dirty" | wc -l | tr -d ' ')
    echo "  - dirty: $_n file(s): $(printf '%s\n' "$_dirty" | head -n 10 | tr '\n' ',' | sed 's/,$//;s/,/, /g')"
  fi
  git -C "$3" for-each-ref --format='%(refname:short) %(objectname:short) %(upstream:short) %(upstream:track)' \
    "refs/heads/$H_KEY/" 2>/dev/null | LC_ALL=C sort | while IFS=' ' read -r _b _s _u _t; do
    echo "  - branch $_b at $_s; upstream ${_u:-none} ${_t:-}"
  done
  echo "  - PRs: not queried (lease.sh uses no network); check the git host"
}

inflight() {
  # As core resolves it: relative to the Oracle home when a profile is loaded.
  _wr=$(ao_expand_path "$(ao_cfg work_root "$HOME/src")" "${AO_HOME:-$H_HOME}")
  _names=$(sed -n 's/^[[:space:]]*work\.\([A-Za-z0-9._-]*\)=.*/\1/p' "$H_HOME/operator.conf" | LC_ALL=C sort -u)
  if [ -z "$_names" ]; then
    echo "- no work repos declared in operator.conf"
    return
  fi
  for _name in $_names; do
    _val=$(ao_conf_get "$H_HOME" "work.$_name")
    _role=${_val##*|}
    [ "$_role" != "$_val" ] || _role=contributor
    _explicit=$(ao_conf_get "$H_HOME" "path.$_name") || _explicit=
    if [ -n "$_explicit" ]; then
      set -- "$(ao_expand_path "$_explicit" "$H_HOME")"
    else
      set -- "$_wr/$_name" "$_wr/.worktrees/$H_KEY/$_name"
    fi
    _found=
    for _d in "$@"; do
      [ -e "$_d/.git" ] || continue
      _found=1
      repo_state "$_name" "$_role" "$_d"
    done
    [ -n "$_found" ] || echo "- $_name ($_role): no local checkout found ($*)"
  done
}

# build_note KIND EPOCH FROM  Print a handoff note (§4.4 format).
build_note() {
  printf 'epoch: %s   from: %s   at: %s   kind: %s\n\n' "$2" "$3" "$(ao_utc "$AO_T_EPOCH")" "$1"
  audit_section "$1"
  echo '## In flight'
  inflight
  echo
  echo '## On hold'
  _hold=$(ao_asks_with_status "$H_HOME/ASKS.md" reserved held | sed 's/^/- ask /')
  for _m in "$H_OP/markers/settled"/*; do
    [ -f "$_m" ] || continue
    [ "$(ao_marker_get "$_m" generation)" = "$L_generation" ] || continue
    [ "$(ao_marker_get "$_m" outcome)" = unknown ] || continue
    _hold=$_hold${_hold:+$AO_NL}"- effect $(ao_marker_get "$_m" id): $(ao_marker_get "$_m" what) (outcome unknown: check the target, do not retry)"
  done
  if [ -n "$_hold" ]; then printf '%s\n' "$_hold"; else echo '- none'; fi
  echo
  echo '## Open asks'
  _open=$(ao_asks_with_status "$H_HOME/ASKS.md" open | sed 's/^/- /')
  if [ -z "$_open" ]; then
    echo '- none'
  elif [ "$1" = cold ]; then
    printf '%s\n' "$_open" | sed 's/$/ (from an ended epoch: void, re-ask if still needed)/'
  else
    printf '%s\n' "$_open"
  fi
  echo
  echo '## Next steps'
  if [ "$1" = cold ]; then
    echo 'None (cold note). Read MANDATE.md, the backlog and the items above; verify the target of every effect on hold before repeating anything.'
  else
    echo '1. (at most three, the best first)'
  fi
  echo
  echo '## Grants in play'
  if [ "$1" = cold ]; then
    echo 'Not recorded in a cold note. Re-read MANDATE.md; chat-only grants are void until re-recorded.'
  else
    echo '(mandate sections relied on; chat-only grants are void until re-recorded)'
  fi
}

# ---------------------------------------------------------------- switch-in audit
#
# When an operator moves to the other model family, the incoming family
# audits what the outgoing family left before it takes new work (kit rule
# K-22; one mechanism with cross-review.sh, see lib/registry.sh). Two
# triggers: a lease acquire or takeover onto another client (the lease
# carries audit=pending), or a registry family change seen by
# cross-review.sh without a lease (<state_dir>/audit/<key>). cross-review.sh
# writes the incoming family's headless report to audits/; the session
# triages and commits it and audit-done records it. Meanwhile dispatch-begin,
# dispatch-run and ask.sh new/reserve refuse.

# switch_audit OLD_PROVIDER NEW_PROVIDER  Print the audit state for a new
# holder: pending on a client change; an unfinished audit carries over.
switch_audit() {
  if [ "$1" != "$2" ] || [ "$L_audit" = pending ]; then echo pending; else echo -; fi
}

# audit_pending  Set a_kind (lease or registry), a_header, a_tag and
# a_trans for the pending switch-in audit; false when none is pending.
# Registry audits need the profile (its state dir); without one only the
# lease's own audit is known.
audit_pending() {
  if [ -n "$L_PRESENT" ] && [ "$L_audit" = pending ]; then
    a_kind=lease a_header=$(ao_audit_header "$H_KEY") a_tag=lease-$L_generation-$L_epoch
    a_trans="$L_prev_provider -> $L_provider"
  elif ao_audit_registry_pending "$H_KEY"; then
    if [ -n "$A_invalid" ]; then
      a_kind=invalid a_header='' a_tag=''
      a_trans="unknown: the audit record $(ao_audit_file "$H_KEY") is unreadable or invalid (failing closed; a human must inspect it)"
    else
      a_kind=registry a_header=$(ao_audit_registry_header "$H_KEY")
      a_tag=$(ao_audit_registry_tag) a_trans="$A_from -> $A_to"
    fi
  else
    return 1
  fi
}

audit_reminder() {
  audit_pending || return 0
  echo "REQUIRED FIRST STEP: switch-in audit (this operator moved $a_trans). Run lease.sh audit-brief, triage the incoming family's report (or write one), commit it, then lease.sh audit-done --report PATH. No new work, dispatch or asks until then."
}

audit_gate() {
  audit_pending || return 0
  ao_lease_unlock
  [ "$a_kind" != invalid ] || refuse "switch-in audit $a_trans"
  refuse "switch-in audit pending (moved $a_trans): finish it and run lease.sh audit-done first"
}

# audit_section KIND  The note's switch-in audit section.
audit_section() {
  echo '## Switch-in audit'
  if [ "$1" = cold ] && [ -n "$o_provider" ] && [ "$o_provider" != "$L_provider" ]; then
    echo "REQUIRED FIRST STEP for the incoming $o_provider session, before any new work: a full adversarial audit of what the $L_provider session left (lease.sh audit-brief), committed, then lease.sh audit-done."
  elif [ "$L_audit" = pending ]; then
    echo "REQUIRED FIRST STEP: the switch-in audit from the previous move is still pending (lease.sh audit-brief)."
  else
    echo "Required first step if the next holder runs on a different client than $L_provider: lease.sh audit-brief, then audit-done."
  fi
  echo
}

do_audit_brief() {
  ao_lease_load
  [ -z "$L_PRESENT" ] || need_holder
  audit_pending || { echo "no switch-in audit pending for $H_KEY"; return 0; }
  [ "$a_kind" != invalid ] || refuse "switch-in audit $a_trans"
  _base=$(ao_audit_report_base "$a_tag")
  if [ "$a_kind" = lease ]; then _args=" --instance <token> --epoch $L_epoch"; else _args=; fi
  cat <<BRIEF
$a_header

You are the incoming family. Review adversarially what the outgoing session
left; trust no note without checking it against the repos. cross-review.sh
writes a headless report by the incoming family's reviewer role to
$_base.md (see below). If it is there, triage every finding in it (fixed,
rejected with a reason, or deferred with an owner) and add what you find
yourself; otherwise write your own report in this home. Commit it, then run:
lease.sh audit-done$_args --report <path>
The report must start with the first line of this brief, exactly, and be
committed (after the handoff note, when there is one).

Check, at least:
1. Unfinished work: branches, PRs, half-applied changes, open asks, effects
   on hold (verify their targets; never retry an ambiguous write).
2. Cruft: dead code, debug leftovers, stray files, commented-out blocks,
   TODOs without owners.
3. Leftovers: worktrees and branches no longer needed, stale markers, mail
   left unacked.
4. Drift: NOTES.md, HANDOFF.md, ASKS.md and the backlog versus what the repos
   and the git host actually show; mandate versus what was done.
5. Blind spots the outgoing family tends to have (tests skipped, error
   paths, portability, overclaimed status).

## Evidence
BRIEF
  _found=
  for _r in "$H_HOME/$_base".md "$H_HOME/$_base"-*.md; do
    [ -f "$_r" ] || continue
    _found=1
    echo "- headless report: ${_r#"$H_HOME"/}"
  done
  [ -n "$_found" ] || echo "- headless report: none yet ($_base.md; cross-review.sh writes it when a reviewer of the incoming family is configured)"
  if [ "$a_kind" = lease ]; then
    echo "- handoff note: HANDOFF.md at $L_prev_note (epoch $L_prev_epoch)"
  else
    echo "- registry change: $a_trans at $A_since"
  fi
  [ ! -d "$H_OP" ] || echo "- mail: $(mail_counts)"
  echo "- asks: $(ao_asks_with_status "$H_HOME/ASKS.md" open reserved held | wc -l | tr -d ' ') open, reserved or held"
  inflight
}

# headless_reports REV BASE  Print each home-relative path of a headless
# report for BASE (BASE.md, BASE-N.md) committed at REV or present in the
# working tree.
headless_reports() {
  {
    GIT_LITERAL_PATHSPECS=1 git -C "$H_HOME" ls-tree --name-only "$1" -- "$(dirname -- "$2")/" 2>/dev/null
    for _f in "$H_HOME/$2".md "$H_HOME/$2"-*.md; do [ ! -f "$_f" ] || printf '%s\n' "${_f#"$H_HOME"/}"; done
  } | while IFS= read -r _f; do
    case $_f in "$2".md) printf '%s\n' "$_f" ;; "$2"-*.md)
      _n=${_f#"$2"-}; _n=${_n%.md}
      ! ao_is_uint "$_n" || printf '%s\n' "$_f" ;;
    esac
  done | LC_ALL=C sort -u
}

# triaged  True when the last Triage section of the report on stdin (the
# one cross-review.sh writes for the session) is non-empty and not the
# placeholder.
triaged() {
  awk '
    /^## Triage[[:space:]]*$/ { in_t = 1; ok = 0; next }
    /^## / { in_t = 0 }
    in_t && NF && $0 != "(the incoming session fills this in)" { ok = 1 }
    END { exit !ok }'
}

do_audit_done() {
  [ -n "$o_report" ] || ao_die "$AO_E_USAGE" "audit-done needs --report PATH (relative to the home, committed)"
  # A plain relative path inside the home: no option, pathspec magic, glob,
  # parent step or absolute path.
  case $o_report in
    /* | -* | :* | ../* | */../* | */.. | .. | *[!A-Za-z0-9._/-]*)
      refuse "--report must be a plain path inside the home, relative to it ([A-Za-z0-9._/-])" ;;
  esac
  # Under the lease lock whenever the home has .operator/, so no acquire
  # slips in between the check and the record; with a lease, only its
  # holder records an audit.
  [ ! -d "$H_OP" ] || lock
  ao_lease_load
  if [ -n "$L_PRESENT" ]; then
    need_token
    ao_lease_holder "$o_instance" "$o_epoch" || { ao_lease_unlock; standby; }
  fi
  audit_pending || { ao_lease_unlock; echo "no switch-in audit pending"; return 0; }
  [ "$a_kind" != invalid ] || { ao_lease_unlock; refuse "switch-in audit $a_trans"; }
  # Everything is read from one committed revision, never the working tree.
  _head=$(git -C "$H_HOME" rev-parse -q --verify HEAD 2>/dev/null) || _head=
  [ -n "$_head" ] || { ao_lease_unlock; refuse "$H_HOME has no commit to read the report from"; }
  _blob=$(git -C "$H_HOME" rev-parse -q --verify "$_head:./$o_report" 2>/dev/null) || _blob=
  _mode=$(git -C "$H_HOME" ls-tree "$_head" -- "./$o_report" 2>/dev/null | cut -c1-6)
  case $_mode in
    100644 | 100755) [ -n "$_blob" ] ;;
    *) false ;;
  esac || {
    ao_lease_unlock
    refuse "commit the report first, as a regular file: $o_report"
  }
  [ "$(git -C "$H_HOME" cat-file blob "$_blob" | sed -n 1p)" = "$a_header" ] || {
    ao_lease_unlock
    refuse "the report must start with: $a_header"
  }
  # The incoming family's headless report, when there is one for this
  # switch, is the report to record, and only once it is triaged.
  _base=$(ao_audit_report_base "$a_tag")
  _hl=$(headless_reports "$_head" "$_base")
  if [ -n "$_hl" ]; then
    printf '%s\n' "$_hl" | grep -qxF -- "$o_report" || {
      ao_lease_unlock
      refuse "a headless report exists for this switch: triage and record it instead ($(printf '%s' "$_hl" | tr '\n' ' '))"
    }
    git -C "$H_HOME" cat-file blob "$_blob" | triaged || {
      ao_lease_unlock
      refuse "$o_report has no triage yet: record a decision for each finding under '## Triage', commit, then run audit-done"
    }
  fi
  _sha=$(GIT_LITERAL_PATHSPECS=1 git -C "$H_HOME" log -1 --format=%H "$_head" -- "$o_report")
  [ -n "$_sha" ] || { ao_lease_unlock; refuse "no commit found for $o_report"; }
  if [ "$a_kind" = lease ] && [ "$L_prev_note" != none ]; then
    if [ "$(git -C "$H_HOME" rev-parse "$L_prev_note" 2>/dev/null)" = "$_sha" ] ||
      ! git -C "$H_HOME" merge-base --is-ancestor "$L_prev_note" "$_sha" 2>/dev/null; then
      ao_lease_unlock
      refuse "the report must be committed after the handoff note $L_prev_note"
    fi
  fi
  _short=$(printf '%s' "$_sha" | cut -c1-12)
  if [ "$a_kind" = lease ]; then
    L_audit="done" L_audit_note=$_short L_audit_report=$o_report
    ao_lease_write || ao_die "$AO_E_FAIL" "cannot write $H_LEASE"
  else
    printf 'change=%s\nsince=%s\nreport=%s\ncommit=%s\nat=%s\n' "$A_change" "$A_since" "$o_report" "$_short" "$(ao_utc "$AO_T_EPOCH")" |
      ao_write_atomic "$(ao_audit_file "$H_KEY" .done)" ||
      ao_die "$AO_E_FAIL" "cannot record the audit in $(ao_audit_file "$H_KEY" .done)"
  fi
  ao_lease_unlock
  echo "switch-in audit recorded ($a_kind, $a_trans): $o_report at $_short. New work may start."
  # A registry audit may still be pending behind a lease audit.
  ! audit_pending || echo "still pending: the $a_kind switch-in audit ($a_trans); run lease.sh audit-brief"
}

holder_id() {
  case $L_instance in -) printf '%s/unacquired\n' "$L_provider" ;; *) printf '%s/%s\n' "$L_provider" "$(printf '%s' "$L_instance" | cut -c1-8)" ;; esac
}

# ---------------------------------------------------------------- verbs

do_init() {
  ao_home_init
  if git -C "$H_HOME" rev-parse --git-dir >/dev/null 2>&1 &&
    ! git -C "$H_HOME" check-ignore -q .operator/lease 2>/dev/null; then
    ao_warn "$H_HOME/.operator/ is not git-ignored; add '.operator/' to .gitignore"
  fi
  echo "ready: $H_OP"
}

do_acquire() {
  check_provider
  ao_home_init
  lock
  ao_lease_load
  _replay=
  if [ -n "$L_PRESENT" ]; then
    case $L_state in
      held)
        if [ -n "$o_instance" ] && ao_lease_holder "$o_instance" "$L_epoch"; then
          _replay=1
        else
          ao_lease_unlock
          refuse "$(ao_lease_describe). Only release or a human takeover changes the holder; this session is the standby"
        fi ;;
      assigned)
        [ "$o_provider" = "$L_provider" ] && [ "$o_session" = "$L_session" ] || {
          ao_lease_unlock
          refuse "$(ao_lease_describe); this is $o_provider \`$o_session\`"
        } ;;
      released)
        L_epoch=$((L_epoch + 1))
        L_audit=$(switch_audit "$L_provider" "$o_provider")
        L_prev_provider=$L_provider ;;
    esac
  else
    L_operator=$H_KEY L_host=$(ao_host) L_generation=$(ao_hex 6) L_epoch=1
    L_prev_epoch=0 L_prev_note=none L_prev_provider=- L_audit=- L_audit_note=-
    # A first lease on the other family than the one cross-review.sh last
    # saw is a switch too (needs the profile's state dir).
    _base=
    ao_audit_read "$H_KEY"
    case $? in
      0) _base=$A_provider ;;
      1) _base=$(ao_audit_legacy "$H_KEY") ;;
    esac
    if ao_is_family "$_base" && ao_is_family "$o_provider" && [ "$_base" != "$o_provider" ]; then
      L_audit=pending L_prev_provider=$_base
    fi
  fi
  if [ -n "$_replay" ]; then
    ao_lease_unlock
    echo "acquired: $H_KEY (replay; you already hold it)"
    echo "epoch: $L_epoch"
    echo "generation: $L_generation"
    return 0
  fi
  _token=$(ao_hex 16)
  L_instance=$(ao_token_hash "$_token") || ao_die "$AO_E_FAIL" "no SHA-256 tool (sha256sum, shasum or openssl)"
  L_state=held L_provider=$o_provider L_session=$o_session L_session_id=${o_session_id:--}
  L_acquired=$(ao_utc "$AO_T_EPOCH")
  stamp_heartbeat
  set_client_pid "$o_provider"
  ao_lease_write || ao_die "$AO_E_FAIL" "cannot write $H_LEASE"
  L_PRESENT=1
  ao_lease_unlock
  echo "acquired: $H_KEY by $o_provider \`$o_session\`"
  echo "epoch: $L_epoch"
  echo "generation: $L_generation"
  echo "instance: $_token"
  echo "Keep this instance token in the conversation: present --instance $_token --epoch $L_epoch on every holder verb (renew, check, dispatch, release, mail claim and ack, ask). It is not printed again and is not stored in the lease."
  if [ "$L_prev_note" = none ]; then
    echo "resume from: no handoff note (first holder in this generation)"
  else
    echo "resume from: HANDOFF.md at $L_prev_note (epoch $L_prev_epoch)"
  fi
  audit_reminder
  echo "mail: $(mail_counts)"
}

do_renew() {
  need_token
  lock
  ao_lease_load
  ao_lease_holder "$o_instance" "$o_epoch" || { ao_lease_unlock; standby; }
  stamp_heartbeat
  set_client_pid "$L_provider"
  ao_lease_write || ao_die "$AO_E_FAIL" "cannot write $H_LEASE"
  ao_lease_unlock
  echo "renewed: $H_KEY epoch $L_epoch; mail: $(mail_counts)"
  audit_reminder
}

do_check() {
  need_token
  # Under the lock, so a stuck lock fails closed here too.
  lock
  ao_lease_load
  ao_lease_holder "$o_instance" "$o_epoch" || { ao_lease_unlock; standby; }
  ao_lease_unlock
  echo "holder: $H_KEY epoch $L_epoch"
}

do_dispatch_begin() {
  need_token
  check_text --what "$o_what"
  [ -z "$o_ask" ] || ao_is_name "$o_ask" || ao_die "$AO_E_USAGE" "--ask must be an ask id"
  # The marker must name a process that lives for the whole effect (a kit
  # wrapper); a short-lived shell would leave it dead at once. dispatch-run
  # is the wrapper.
  ao_is_uint "$o_pid" || ao_die "$AO_E_USAGE" "dispatch-begin needs --pid PID of the process doing the effect (or use dispatch-run)"
  [ "$(ao_proc_state "$o_pid")" = live ] || ao_die "$AO_E_USAGE" "--pid $o_pid is not a running process (or its state cannot be read)"
  _pid=$o_pid
  lock
  ao_lease_load
  ao_lease_holder "$o_instance" "$o_epoch" || { ao_lease_unlock; standby; }
  audit_gate
  _mk=$(ao_marker_create dispatch "$o_what" "$o_ask" "$_pid") || ao_die "$AO_E_FAIL" "cannot create a dispatch marker"
  _ao_crash dispatch-after-marker
  ao_lease_unlock
  echo "marker: $_mk"
}

do_dispatch_run() {
  need_token
  check_text --what "$o_what"
  [ $# -gt 0 ] || ao_die "$AO_E_USAGE" "dispatch-run needs -- CMD [ARG...]"
  [ -z "$o_ask" ] || ao_is_name "$o_ask" || ao_die "$AO_E_USAGE" "--ask must be an ask id"
  lock
  ao_lease_load
  ao_lease_holder "$o_instance" "$o_epoch" || { ao_lease_unlock; standby; }
  audit_gate
  _mk=$(ao_marker_create dispatch "$o_what" "$o_ask" $$) || ao_die "$AO_E_FAIL" "cannot create a dispatch marker"
  ao_lease_unlock
  ao_msg "marker: $_mk"
  "$@"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    ao_msg "the command failed (exit $_rc): its effect is unknown. Marker $_mk stays until the human checks the target and settles it"
    exit "$_rc"
  fi
  lock
  rm -f "$H_OP/markers/$_mk" || ao_die "$AO_E_FAIL" "cannot remove marker $_mk"
  ao_lease_unlock
  ao_msg "ended: $_mk"
}

do_dispatch_end() {
  need_token
  ao_is_name "$o_marker" || ao_die "$AO_E_USAGE" "dispatch-end needs --marker ID"
  lock
  ao_lease_load
  ao_lease_holder "$o_instance" "$o_epoch" || { ao_lease_unlock; standby; }
  _mf=$H_OP/markers/$o_marker
  [ -f "$_mf" ] || { ao_lease_unlock; refuse "no open marker $o_marker"; }
  [ "$(ao_marker_get "$_mf" instance)" = "$(ao_token_hash "$o_instance")" ] &&
    [ "$(ao_marker_get "$_mf" epoch)" = "$o_epoch" ] &&
    [ "$(ao_marker_get "$_mf" generation)" = "$L_generation" ] || {
    ao_lease_unlock
    refuse "marker $o_marker belongs to another holder or epoch"
  }
  # Only positive evidence that the marker's process still runs lets it end
  # the marker; dead or unknown (no ps) leaves it for the human.
  _mst=$(ao_proc_state "$(ao_marker_get "$_mf" pid)" "$(ao_marker_get "$_mf" pid_start)")
  if [ "$_mst" != live ]; then
    ao_lease_unlock
    refuse "marker $o_marker's process is $_mst: its effect is unknown until a human checks the target and settles it (lease.sh settle)"
  fi
  rm -f "$_mf" || ao_die "$AO_E_FAIL" "cannot remove $_mf"
  ao_lease_unlock
  echo "ended: $o_marker"
}

do_note() {
  ao_lease_load
  need_holder
  build_note warm "$L_epoch" "$(holder_id)"
}

do_release() {
  need_token
  # Under the lock from the first check to the lease write, so a stuck lock
  # refuses before anything is committed.
  lock
  ao_lease_load
  if [ -n "$L_PRESENT" ] && [ "$L_state" = released ] && [ "$L_prev_epoch" = "$o_epoch" ] &&
    [ "$L_instance" = "$(ao_token_hash "$o_instance")" ]; then
    ao_lease_unlock
    echo "released: $H_KEY epoch $o_epoch (already); note $L_prev_note"
    return 0
  fi
  ao_lease_holder "$o_instance" "$o_epoch" || { ao_lease_unlock; standby; }
  ! markers_present || { ao_lease_unlock; refuse "a dispatch marker is open (an effect may be in flight): finish it, or have the human settle it, before releasing"; }
  _hdr=$(handoff_header)
  _he=$(printf '%s\n' "$_hdr" | sed -n 's/^epoch: *\([0-9][0-9]*\) .*/\1/p')
  _hk=$(printf '%s\n' "$_hdr" | sed -n 's/.*kind: *\([a-z]*\).*/\1/p')
  [ "$_he" = "$L_epoch" ] && [ "$_hk" = warm ] || {
    ao_lease_unlock
    refuse "HANDOFF.md must start with 'epoch: $L_epoch ... kind: warm' (lease.sh note prints a template)"
  }
  ao_git_commit "$H_HOME" "handoff: $H_KEY epoch $L_epoch (warm)" HANDOFF.md ||
    ao_die "$AO_E_FAIL" "cannot commit HANDOFF.md; lease unchanged"
  ao_git_clean "$H_HOME" HANDOFF.md || ao_die "$AO_E_FAIL" "HANDOFF.md differs from HEAD; lease unchanged"
  _sha=$(git -C "$H_HOME" log -1 --format=%h -- HANDOFF.md)
  [ -n "$_sha" ] || ao_die "$AO_E_FAIL" "HANDOFF.md has no commit; lease unchanged"
  _ao_crash release-after-commit
  L_state=released L_prev_epoch=$L_epoch L_prev_note=$_sha
  ao_lease_write || ao_die "$AO_E_FAIL" "cannot write $H_LEASE"
  ao_lease_unlock
  echo "released: $H_KEY epoch $L_epoch; note $_sha. The standby can now acquire."
}

do_redirect() {
  ao_lease_load
  if [ -z "$L_PRESENT" ] || [ "$L_state" = released ]; then
    echo "$(ao_lease_describe). This session may acquire it (lease.sh acquire)."
    return 0
  fi
  if [ "$L_state" = assigned ]; then
    echo "$(ao_lease_describe). Go to that session."
    return 0
  fi
  echo "$H_KEY is held by $L_provider \`$L_session\` since $L_acquired; last heartbeat $L_heartbeat. Go there."
  _age=$((AO_T_EPOCH - L_heartbeat_epoch))
  if [ "$_age" -gt "$(lease_stale_secs)" ] && ! markers_present &&
    [ "$(ao_proc_state "$L_client_pid" "$L_client_start")" = dead ]; then
    echo "The holder looks down (no heartbeat for $((_age / 60)) min, no open dispatch). Say so if you want this side to take over; a human confirms it with lease.sh takeover in a terminal."
  fi
}

do_status() {
  ao_lease_load
  echo "operator: $H_KEY ($H_HOME)"
  if [ -z "$L_PRESENT" ]; then
    echo "lease: none"
  else
    echo "lease: $(ao_lease_describe)"
    echo "generation: $L_generation  epoch: $L_epoch  previous: epoch $L_prev_epoch note $L_prev_note"
    _age=$((AO_T_EPOCH - L_heartbeat_epoch))
    _st=fresh
    [ "$_age" -le "$(lease_stale_secs)" ] || _st=stale
    echo "heartbeat: $L_heartbeat ($((_age / 60)) min ago, $_st)"
    if [ "$L_client_pid" != - ] && [ -n "$L_client_pid" ]; then
      echo "client process: pid $L_client_pid $(ao_proc_state "$L_client_pid" "$L_client_start")"
    else
      echo "client process: not recorded (client exposes none)"
    fi
  fi
  _mk=$(ao_markers_open)
  if [ -n "$_mk" ]; then
    echo "dispatch markers (block release and takeover):"
    printf '%s\n' "$_mk" | while IFS="$AO_TAB" read -r _id _s _p _a _w; do
      echo "  $_id  $_s (pid $_p)  ask=$_a  $_w"
    done
  else
    echo "dispatch markers: none"
  fi
  echo "mail: $(mail_counts)"
  if audit_pending; then
    echo "switch-in audit: pending ($a_kind, $a_trans)"
  elif [ -n "$L_PRESENT" ]; then
    echo "switch-in audit: $L_audit (report ${L_audit_report:--} at ${L_audit_note:--})"
  fi
  if [ -d "$H_OP/lease.lock" ]; then echo "lock: present ($H_OP/lease.lock)"; else echo "lock: free"; fi
  echo "takeover: terminal-only on every client (no client validated for a fresh permission prompt; docs/handoff.md)"
  if [ -n "$o_evidence" ]; then
    echo "work repos:"
    inflight | sed 's/^/  /'
  fi
}

# takeover_ok  Preconditions, checked before the prompt and again under
# the lock.
takeover_ok() {
  [ -n "$L_PRESENT" ] || refuse "no lease: a session can simply acquire it"
  [ "$L_state" != released ] || refuse "the lease is released: the standby can acquire it (warm), no takeover needed"
  [ "$o_expect_epoch" = "$L_epoch" ] || refuse "epoch is $L_epoch, not $o_expect_epoch: the lease changed; look again"
  [ "$L_generation" = "$_gen0" ] || refuse "the lease generation changed; look again"
  ! markers_present || refuse "a dispatch marker exists: an effect may be in flight or paused. Let it finish, or stop its process and settle it (lease.sh settle)"
  [ "$(ao_proc_state "$L_client_pid" "$L_client_start")" = dead ] ||
    refuse "the holder's client process (pid $L_client_pid) is still running: close that session first"
  # takeover rewrites these and restores them from HEAD if its commit
  # fails: uncommitted work in them would be lost.
  for _f in HANDOFF.md ASKS.md; do
    if git -C "$H_HOME" cat-file -e "HEAD:./$_f" 2>/dev/null; then
      if [ ! -e "$H_HOME/$_f" ] || ! ao_git_clean "$H_HOME" "$_f"; then
        refuse "$_f has uncommitted changes (or was deleted): commit them first (takeover rewrites it)"
      fi
    elif [ -e "$H_HOME/$_f" ]; then
      refuse "$_f is untracked: commit it or move it aside first (takeover rewrites it)"
    fi
  done
}

do_takeover() {
  human_only
  [ -n "$o_holder_stopped" ] || refuse "--holder-stopped is required: close the old session (or see that it cannot run), then assert it"
  ao_is_uint "$o_expect_epoch" || ao_die "$AO_E_USAGE" "takeover needs --expect-epoch N (from lease.sh status)"
  check_provider
  ao_lease_load
  _gen0=${o_expect_generation:-$L_generation}
  takeover_ok
  do_status_evidence
  confirm_tty "takeover $H_KEY $L_epoch"
  lock
  ao_lease_load
  takeover_ok
  _from=$(holder_id)
  if [ -f "$H_HOME/ASKS.md" ]; then
    for _id in $(ao_asks_with_status "$H_HOME/ASKS.md" reserved | sed 's/ .*//'); do
      ao_ask_set_status "$H_HOME/ASKS.md" "$_id" held || ao_die "$AO_E_FAIL" "cannot update ASKS.md"
    done
  fi
  build_note cold "$L_epoch" "$_from" | ao_write_atomic "$H_HOME/HANDOFF.md" || ao_die "$AO_E_FAIL" "cannot write HANDOFF.md"
  # The lock is held through the commit, so no marker or holder change can
  # slip in between the note and the lease write (a slow commit makes other
  # verbs fail closed meanwhile, which is the safe direction).
  set -- HANDOFF.md
  [ ! -f "$H_HOME/ASKS.md" ] || set -- "$@" ASKS.md
  if ! ao_git_commit "$H_HOME" "handoff: $H_KEY epoch $o_expect_epoch (cold, takeover)" "$@"; then
    for _f in "$@"; do
      if git -C "$H_HOME" cat-file -e "HEAD:./$_f" 2>/dev/null; then
        git -C "$H_HOME" checkout -q HEAD -- "$_f"
      else
        rm -f "$H_HOME/$_f"
      fi
    done
    ao_die "$AO_E_FAIL" "cannot commit the cold note; HANDOFF.md and ASKS.md restored, lease unchanged"
  fi
  _sha=$(git -C "$H_HOME" log -1 --format=%h -- HANDOFF.md)
  _ao_crash takeover-after-commit
  L_prev_epoch=$L_epoch L_epoch=$((L_epoch + 1)) L_prev_note=$_sha
  L_audit=$(switch_audit "$L_provider" "$o_provider") L_prev_provider=$L_provider
  L_state=assigned L_provider=$o_provider L_session=$o_session L_session_id=${o_session_id:--}
  L_instance=- L_acquired=- L_client_pid=- L_client_start=-
  ao_lease_write || ao_die "$AO_E_FAIL" "cannot write $H_LEASE"
  ao_lease_unlock
  echo "takeover: $H_KEY epoch $L_epoch assigned to $o_provider \`$o_session\`; cold note $_sha"
  echo "Next: in that session, run: lease.sh acquire --provider $o_provider --session '$o_session'"
  echo "Approvals from epoch $L_prev_epoch are dead; reserved ones are on hold. Close the old session if it is still open. Mail: $(mail_counts)"
}

do_status_evidence() {
  o_evidence=1
  do_status
}

do_settle() {
  human_only
  ao_is_name "$o_marker" || ao_die "$AO_E_USAGE" "settle needs --marker ID"
  case $o_outcome in landed | not-landed | unknown) ;; *) ao_die "$AO_E_USAGE" "--outcome must be landed, not-landed or unknown" ;; esac
  ao_lease_load
  _mf=$H_OP/markers/$o_marker
  [ -f "$_mf" ] || refuse "no open marker $o_marker"
  _ps=$(ao_proc_state "$(ao_marker_get "$_mf" pid)" "$(ao_marker_get "$_mf" pid_start)")
  [ "$_ps" = dead ] || refuse "the marker's process is $_ps: stop it first"
  echo "marker $o_marker: $(ao_marker_get "$_mf" what) (ask $(ao_marker_get "$_mf" ask))"
  confirm_tty "settle $o_marker $o_outcome"
  lock
  [ -f "$_mf" ] || { ao_lease_unlock; refuse "marker $o_marker is gone"; }
  _ask=$(ao_marker_get "$_mf" ask)
  _changed=
  if [ "$_ask" != - ] && ao_ask_row "$H_HOME/ASKS.md" "$_ask" >/dev/null; then
    case $o_outcome in landed) _to=used ;; not-landed) _to=void ;; *) _to=held ;; esac
    ao_ask_set_status "$H_HOME/ASKS.md" "$_ask" "$_to" || ao_die "$AO_E_FAIL" "cannot update ASKS.md"
    _changed=1
  fi
  printf 'outcome=%s\nsettled=%s\n' "$o_outcome" "$(ao_utc "$AO_T_EPOCH")" >>"$_mf"
  mv "$_mf" "$H_OP/markers/settled/" || ao_die "$AO_E_FAIL" "cannot move $_mf"
  if [ -n "$_changed" ]; then
    ao_git_commit "$H_HOME" "asks: $_ask settled ($o_outcome)" ASKS.md || ao_warn "ASKS.md updated but not committed"
  fi
  ao_lease_unlock
  echo "settled: $o_marker ($o_outcome)"
}

# lock_identity DIR  Print the lock directory's inode, recorded pid and
# mtime: what unlock confirms is what it removes.
lock_identity() {
  # shellcheck disable=SC2012 # one known path; ls -di is the portable inode read
  _li=$(ls -di "$1" 2>/dev/null | awk '{ print $1 }') || return 1
  [ -n "$_li" ] || return 1
  printf '%s %s %s\n' "$_li" "$(cat "$1/pid" 2>/dev/null || echo nopid)" "$(ao_mtime "$1" 2>/dev/null)"
}

do_unlock() {
  human_only
  [ -n "$o_timers_off" ] && [ -n "$o_sessions_stopped" ] ||
    refuse "unlock needs --timers-off --sessions-stopped: stop the tick and every session of this operator first"
  _lk=$H_OP/lease.lock
  [ -d "$_lk" ] || { echo "no lease lock"; return 0; }
  _id0=$(lock_identity "$_lk") || refuse "the lock changed while reading it; look again"
  _lp=$(cat "$_lk/pid" 2>/dev/null) || _lp=
  [ -z "$_lp" ] || [ "$(ao_proc_state "$_lp")" = dead ] || refuse "the lock's process (pid $_lp) is still running"
  confirm_tty "unlock $H_KEY"
  # From the final check to the removal, hold the guard every lock
  # acquisition takes: no new lock can appear in between, so only the lock
  # the human confirmed is removed.
  ao_lease_guard || refuse "the lease guard stays taken; nothing removed"
  [ "$(lock_identity "$_lk")" = "$_id0" ] || { ao_lease_unguard; refuse "the lock was replaced or removed while you confirmed; nothing removed. Look again"; }
  [ -z "$_lp" ] || [ "$(ao_proc_state "$_lp")" = dead ] || { ao_lease_unguard; refuse "the lock's process (pid $_lp) is running"; }
  rm -rf "$_lk" "$_lk.reported" || { ao_lease_unguard; ao_die "$AO_E_FAIL" "cannot remove $_lk"; }
  ao_lease_unguard
  echo "unlocked. Now check: lease.sh status (open markers are unresolved effects) and ASKS.md."
}

main() {
  o_home=
  while [ $# -gt 0 ]; do
    case $1 in
      -h | --help) ao_usage; exit 0 ;;
      --home) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--home needs a value"; o_home=$2; shift 2 ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || ao_die "$AO_E_USAGE" "usage: lease.sh [--home DIR] VERB [OPTIONS] (see --help)"
  verb=$1
  shift
  o_provider='' o_session='' o_session_id='' o_instance='' o_epoch='' o_what='' o_ask=''
  o_pid='' o_marker='' o_expect_epoch='' o_expect_generation='' o_holder_stopped=''
  o_outcome='' o_timers_off='' o_sessions_stopped='' o_evidence='' o_report=''
  while [ $# -gt 0 ]; do
    case $1 in
      --holder-stopped) o_holder_stopped=1 ;;
      --timers-off) o_timers_off=1 ;;
      --sessions-stopped) o_sessions_stopped=1 ;;
      --evidence) o_evidence=1 ;;
      --provider | --session | --session-id | --instance | --epoch | --what | --ask | --pid | --marker | \
        --expect-epoch | --expect-generation | --outcome | --report)
        [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "$1 needs a value"
        _var=o_$(printf '%s' "${1#--}" | tr - _)
        eval "$_var=\$2"
        shift ;;
      --) shift; break ;;
      -h | --help) ao_usage; exit 0 ;;
      *) ao_die "$AO_E_USAGE" "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  _h=$(ao_home_find "$o_home") || ao_die "$AO_E_USAGE" "no operator home (operator.conf) at ${o_home:-$PWD or above}; use --home"
  ao_home_use "$_h"
  lease_profile
  ao_lease_traps
  case $verb in
    init) do_init ;;
    acquire) do_acquire ;;
    renew) do_renew ;;
    check) do_check ;;
    dispatch-begin) do_dispatch_begin ;;
    dispatch-end) do_dispatch_end ;;
    dispatch-run) do_dispatch_run "$@" ;;
    note) do_note ;;
    release) do_release ;;
    redirect) do_redirect ;;
    status) do_status ;;
    audit-brief) do_audit_brief ;;
    audit-done) do_audit_done ;;
    takeover) do_takeover ;;
    settle) do_settle ;;
    unlock) do_unlock ;;
    *) ao_die "$AO_E_USAGE" "unknown verb '$verb' (see --help)" ;;
  esac
}

main "$@"
