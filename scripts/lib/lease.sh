# shellcheck shell=sh disable=SC2034,SC2154,SC2016
# (SC2034: the L_*, OP_* and AO_* globals set here are read by callers;
#  SC2154: L_* are assigned by eval in ao_lease_read; SC2016: backticks in
#  messages are literal Markdown.)
# lease.sh (library) - EXPERIMENTAL provider handoff: the advisory lease,
# operator homes, markers and the approval ledger helpers.
#
# Sourced after core.sh. Used by scripts/lease.sh, mail.sh, ask.sh and the
# doorbells, and by ao_operator_resolve (registry.sh) to route an operator
# to the provider and session that hold its lease.
#
# An operator home holds operator.conf (flat key=value, parsed literally)
# and a git-ignored, machine-local .operator/ directory:
#   .operator/lease          the lease, written only by scripts/lease.sh
#   .operator/lease.lock/    the lease lock (mkdir); never broken by a script
#   .operator/inbox/{tmp,new,cur,done}/   the mailbox (mail.sh)
#   .operator/markers/       dispatch markers; settled/ keeps settled ones
#   .operator/forwarded/     one entry per forwarded human turn (dedupe)
#
# The lease is advisory: it routes, redirects and fences the kit's own
# verbs; it cannot stop a session that ignores its instructions, and it does
# not stop a hostile process running as the same OS user.

# Refused by the lease: not the holder, wrong epoch, a marker in the way, a
# precondition the human must settle. Distinct from usage (2) and busy (3).
AO_E_REFUSED=5
# Seconds after which a lease lock is treated as stuck (fail closed).
AO_LEASE_LOCK_MAX=10
AO_LEASE_LOCKED=
_AO_LEASE_KEYS="operator provider session session_id instance generation host epoch state acquired heartbeat heartbeat_epoch prev_epoch prev_note prev_provider audit audit_note client_pid client_start"

# ---------------------------------------------------------------- basics

# _ao_crash POINT  Fault injection for the failure-window tests: when
# AO_TEST_CRASH_AT names POINT, die at once with SIGKILL (no traps run, so a
# held lock stays, exactly as after a real crash).
_ao_crash() {
  [ "${AO_TEST_CRASH_AT:-}" != "$1" ] || kill -KILL $$
}

# ao_hex BYTES  Print BYTES random bytes as lowercase hex.
ao_hex() {
  od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
}

# ao_hash  Print the SHA-256 of stdin as hex; fails with no hashing tool.
ao_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | sed 's/.*= *//'
  else
    return 1
  fi
}

# ao_token_hash TOKEN  Print the stored form of an instance token: the
# first 32 hex digits of its SHA-256. The lease never holds the token
# itself, so a session that reads the file cannot present it by mistake.
ao_token_hash() {
  _ao_th=$(printf '%s' "$1" | ao_hash) || return 1
  printf '%s\n' "$_ao_th" | cut -c1-32
}

# ao_utc EPOCH  Print EPOCH as YYYY-MM-DDTHH:MM:SSZ (GNU or BSD date).
ao_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# ao_text_ok STRING  True for a one-line value with no tab, no newline and no
# '|' (values go into flat files and Markdown table cells).
ao_text_ok() {
  case $1 in '' | *"$AO_TAB"* | *"$AO_NL"* | *'|'*) return 1 ;; esac
  return 0
}

# ao_host  Print this machine's short host name.
ao_host() {
  _ao_h=$(hostname 2>/dev/null) || _ao_h=unknown
  printf '%s\n' "${_ao_h%%.*}"
}

# ao_proc_start PID  Print PID's start time (ps lstart), or nothing.
ao_proc_start() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'
}

# ao_proc_state PID [START]  Print live, stopped or dead. A recorded START
# that no longer matches means the pid was reused: dead.
ao_proc_state() {
  ao_is_uint "$1" || { echo dead; return; }
  kill -0 "$1" 2>/dev/null || { echo dead; return; }
  if [ -n "${2:-}" ] && [ "$2" != - ]; then
    _ao_ps=$(ao_proc_start "$1")
    [ -z "$_ao_ps" ] || [ "$_ao_ps" = "$2" ] || { echo dead; return; }
  fi
  case $(ps -o stat= -p "$1" 2>/dev/null) in *T*) echo stopped ;; *) echo live ;; esac
}

# ao_client_pid PROVIDER  Print "PID START" of the client process that runs
# this command, where the client exposes it, else nothing. Claude Code sets
# CLAUDE_PID for tool commands (observed, not documented; see
# docs/continuity.md). Codex exposes no process id.
ao_client_pid() {
  case $1 in
    claude)
      [ "${CLAUDECODE:-}" = 1 ] && ao_is_uint "${CLAUDE_PID:-}" || return 0
      _ao_cs=$(ao_proc_start "$CLAUDE_PID")
      [ -z "$_ao_cs" ] || printf '%s %s\n' "$CLAUDE_PID" "$_ao_cs" ;;
  esac
}

# ao_agent_env  True when this command seems to run inside an agent's tool
# shell. Human-only verbs refuse there (defence in depth; the client's own
# deny rule is the boundary).
ao_agent_env() {
  [ -n "${CLAUDECODE:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SANDBOX:-}" ]
}

# ---------------------------------------------------------------- homes

# ao_home_find [DIR]  Print the operator home: DIR, else $AO_OPERATOR_HOME,
# else the nearest directory at or above $PWD holding operator.conf.
ao_home_find() {
  _ao_hd=${1:-${AO_OPERATOR_HOME:-}}
  if [ -n "$_ao_hd" ]; then
    [ -f "$_ao_hd/operator.conf" ] || return 1
    (CDPATH='' cd -- "$_ao_hd" && pwd -P)
    return
  fi
  _ao_hd=$(pwd -P)
  while :; do
    [ -f "$_ao_hd/operator.conf" ] && { printf '%s\n' "$_ao_hd"; return 0; }
    [ "$_ao_hd" != / ] || return 1
    _ao_hd=$(dirname -- "$_ao_hd")
  done
}

# ao_conf_get HOME KEY  Print KEY from HOME/operator.conf (last one wins).
# Literal: never sourced. Keys may contain dots.
ao_conf_get() {
  [ -r "$1/operator.conf" ] || return 1
  awk -v k="$2" '
    { sub(/^[ \t]+/, "") }
    /^#/ { next }
    index($0, k "=") == 1 { v = substr($0, length(k) + 2); sub(/[ \t]+$/, "", v) }
    END { if (v != "") print v }' "$1/operator.conf"
}

# ao_home_use HOME  Set H_HOME, H_KEY, H_OP (.operator) and H_LEASE.
ao_home_use() {
  H_HOME=$1
  H_KEY=$(ao_conf_get "$1" key) || H_KEY=
  ao_is_name "$H_KEY" || ao_die "$AO_E_USAGE" "$1/operator.conf: missing or invalid key="
  H_OP=$1/.operator
  H_LEASE=$H_OP/lease
}

# ao_home_init  Create the .operator layout (idempotent, private).
ao_home_init() {
  (umask 077 && mkdir -p "$H_OP/inbox/tmp" "$H_OP/inbox/new" "$H_OP/inbox/cur" \
    "$H_OP/inbox/done" "$H_OP/markers/settled" "$H_OP/forwarded") ||
    ao_die "$AO_E_FAIL" "cannot create $H_OP"
}

# ---------------------------------------------------------------- lease file

_ao_lease_reset() {
  for _ao_lk in $_AO_LEASE_KEYS; do eval "L_$_ao_lk="; done
}

# ao_lease_read FILE  Parse a lease into L_* variables. Returns 0 when read
# and valid, 1 when absent, 2 when unreadable or invalid (callers fail
# closed). Never sourced; unknown keys make it invalid.
ao_lease_read() {
  _ao_lease_reset
  [ -e "$1" ] || return 1
  [ -r "$1" ] || return 2
  while IFS= read -r _ao_ll || [ -n "$_ao_ll" ]; do
    case $_ao_ll in '' | '#'*) continue ;; *=*) ;; *) return 2 ;; esac
    _ao_lk=${_ao_ll%%=*}
    case " $_AO_LEASE_KEYS " in *" $_ao_lk "*) ;; *) return 2 ;; esac
    eval "L_$_ao_lk=\${_ao_ll#*=}"
  done <"$1"
  ao_is_name "$L_operator" && ao_is_name "$L_provider" || return 2
  ao_is_uint "$L_epoch" && ao_is_uint "$L_heartbeat_epoch" || return 2
  case $L_generation in '' | *[!0-9a-f]*) return 2 ;; esac
  case $L_instance in - ) ;; "" | *[!0-9a-f]*) return 2 ;; esac
  case $L_state in held | released | assigned) ;; *) return 2 ;; esac
  [ "$L_state" != held ] || [ "$L_instance" != - ] || return 2
  case $L_audit in - | pending | done) ;; *) return 2 ;; esac
  return 0
}

# ao_lease_write  Write the L_* variables to H_LEASE atomically (temp file
# in the same directory, then rename). Call only under the lease lock.
ao_lease_write() {
  _ao_lt=$(mktemp "$H_OP/.lease.XXXXXX") || return 1
  {
    for _ao_lk in $_AO_LEASE_KEYS; do
      eval "_ao_lv=\${L_$_ao_lk:--}"
      printf '%s=%s\n' "$_ao_lk" "$_ao_lv"
    done
  } >"$_ao_lt" || { rm -f "$_ao_lt"; return 1; }
  _ao_crash lease-before-rename
  mv -f "$_ao_lt" "$H_LEASE" || { rm -f "$_ao_lt"; return 1; }
}

# ao_lease_load  Read H_LEASE; exit on an invalid lease. Sets L_PRESENT.
ao_lease_load() {
  ao_lease_read "$H_LEASE"
  case $? in
    0) L_PRESENT=1 ;;
    1) L_PRESENT= ;;
    *) ao_die "$AO_E_FAIL" "lease unreadable or invalid: $H_LEASE (failing closed; a human must inspect it)" ;;
  esac
  if [ -n "$L_PRESENT" ]; then
    [ "$L_operator" = "$H_KEY" ] ||
      ao_die "$AO_E_FAIL" "lease names operator '$L_operator', but this home is '$H_KEY' (failing closed)"
    [ "$L_host" = "$(ao_host)" ] ||
      ao_die "$AO_E_REFUSED" "lease is from host '$L_host'; this is '$(ao_host)'. v0.2 runs one operator on one machine; a restore starts a new .operator/"
  fi
}

# ao_lease_is_holder TOKEN EPOCH  True when the loaded lease is held by TOKEN
# at EPOCH. A display name never counts.
ao_lease_is_holder() {
  [ -n "$L_PRESENT" ] && [ "$L_state" = held ] || return 1
  ao_is_uint "$2" && [ "$2" = "$L_epoch" ] || return 1
  [ -n "$1" ] && [ "$(ao_token_hash "$1")" = "$L_instance" ]
}

# ao_lease_describe  One line naming the holder, for refusals and replies.
ao_lease_describe() {
  if [ -z "$L_PRESENT" ]; then
    printf '%s has no lease yet\n' "$H_KEY"
    return
  fi
  case $L_state in
    held) printf '%s is held by %s `%s` (epoch %s) since %s; last heartbeat %s\n' \
      "$H_KEY" "$L_provider" "$L_session" "$L_epoch" "$L_acquired" "$L_heartbeat" ;;
    assigned) printf '%s is assigned to %s `%s` (epoch %s) by a takeover; that session has not acquired it yet\n' \
      "$H_KEY" "$L_provider" "$L_session" "$L_epoch" ;;
    released) printf '%s is released (epoch %s ended); the next session to acquire it holds it\n' \
      "$H_KEY" "$L_epoch" ;;
  esac
}

# ---------------------------------------------------------------- lock

# ao_lease_lock  Take .operator/lease.lock (mkdir is atomic). Waits while a
# young lock exists; a lock older than AO_LEASE_LOCK_MAX seconds is never
# broken: every verb fails closed (status 3) and the Oracle is told once.
# The human clears it with `lease.sh unlock`.
ao_lease_lock() {
  _ao_lck=$H_OP/lease.lock
  [ -d "$H_OP" ] || ao_die "$AO_E_USAGE" "$H_OP does not exist (run: lease.sh init)"
  while ! mkdir "$_ao_lck" 2>/dev/null; do
    _ao_lm=$(ao_mtime "$_ao_lck" 2>/dev/null) || continue
    if [ $(($(date +%s) - _ao_lm)) -gt "$AO_LEASE_LOCK_MAX" ]; then
      _ao_lease_stuck "$_ao_lck"
      return "$AO_E_BUSY"
    fi
    sleep 1
  done
  printf '%s\n' "$$" >"$_ao_lck/pid"
  AO_LEASE_LOCKED=$_ao_lck
}

_ao_lease_stuck() {
  ao_msg "lease lock $1 is older than ${AO_LEASE_LOCK_MAX}s: failing closed. A human must check that no lease verb is running, then run: lease.sh unlock --timers-off --sessions-stopped"
  # Tell the Oracle once per stuck lock (the marker sits beside the lock).
  [ ! -e "$1.reported" ] || return 0
  : >"$1.reported" 2>/dev/null || return 0
  if [ -n "${AO_INBOX:-}" ]; then
    ao_note_oracle "lease-lock-$H_KEY" "Lease lock stuck for $H_KEY ($1): every lease verb fails closed until a human runs lease.sh unlock there." ||
      ao_warn "could not tell the Oracle about the stuck lock"
  fi
}

# ao_lease_unlock  Release the lease lock if this process holds it.
ao_lease_unlock() {
  if [ -n "$AO_LEASE_LOCKED" ] && [ "$(cat "$AO_LEASE_LOCKED/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$AO_LEASE_LOCKED"
  fi
  AO_LEASE_LOCKED=
}

# ao_lease_traps  Release the lease lock on every exit path this process
# controls (die, signal, normal exit). A SIGKILL leaves it: fail closed.
ao_lease_traps() {
  trap 'ao_lease_unlock; ao_cleanup' EXIT
}

# ---------------------------------------------------------------- markers

# ao_marker_create KIND WHAT ASK PID  Create a dispatch marker for the
# loaded lease (call under the lease lock) and print its id.
ao_marker_create() {
  _ao_mid=$AO_T_STAMP-$(ao_hex 4)
  _ao_mt=$(mktemp "$H_OP/markers/.tmp.XXXXXX") || return 1
  {
    printf 'id=%s\nkind=%s\nwhat=%s\nask=%s\n' "$_ao_mid" "$1" "$2" "${3:--}"
    printf 'pid=%s\npid_start=%s\n' "$4" "$(ao_proc_start "$4")"
    printf 'generation=%s\nepoch=%s\ninstance=%s\ncreated=%s\n' \
      "$L_generation" "$L_epoch" "$L_instance" "$(ao_utc "$AO_T_EPOCH")"
  } >"$_ao_mt" || { rm -f "$_ao_mt"; return 1; }
  mv "$_ao_mt" "$H_OP/markers/$_ao_mid" || { rm -f "$_ao_mt"; return 1; }
  printf '%s\n' "$_ao_mid"
}

# ao_marker_get FILE KEY  Print one field of a marker file.
ao_marker_get() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# ao_markers_open  Print one line per open marker:
#   id <TAB> state (live|stopped|dead) <TAB> pid <TAB> ask <TAB> what
ao_markers_open() {
  for _ao_m in "$H_OP/markers"/*; do
    [ -f "$_ao_m" ] || continue
    _ao_pid=$(ao_marker_get "$_ao_m" pid)
    printf '%s\t%s\t%s\t%s\t%s\n' "${_ao_m##*/}" \
      "$(ao_proc_state "$_ao_pid" "$(ao_marker_get "$_ao_m" pid_start)")" "$_ao_pid" \
      "$(ao_marker_get "$_ao_m" ask)" "$(ao_marker_get "$_ao_m" what)"
  done
}

# ---------------------------------------------------------------- routing

# ao_lease_route  Called by ao_operator_resolve with OP_* set. When the
# operator's home (OP_DIR) has a lease: OP_LEASE = its state, OP_AUDIT = its
# switch-in audit state, OP_CLIENT = its provider in every state (a registry
# client of file-only stays file-only), and unless released OP_NAME = its
# session display name, OP_SID = its session id (empty when unknown).
# OP_LEASE=none when there is no lease (registry row only, unchanged),
# invalid when it cannot be trusted. ao_gate holds every state but held.
# OP_PROVIDER is the family that owns the operator whatever the transport:
# the lease's provider, else the registry client. Pick reviewers from it.
ao_lease_route() {
  OP_LEASE=none
  OP_AUDIT=-
  OP_PROVIDER=$OP_CLIENT
  [ -e "$OP_DIR/.operator/lease" ] || return 0
  if ! ao_lease_read "$OP_DIR/.operator/lease" || [ "$L_operator" != "$OP_KEY" ]; then
    OP_LEASE=invalid
    return 0
  fi
  OP_LEASE=$L_state OP_AUDIT=$L_audit
  OP_PROVIDER=$L_provider
  # The client is reported for every state (the outgoing provider while
  # released, the incoming one while assigned), so callers that pick a
  # reviewer from the opposite family follow a handoff at once. Only a held
  # lease routes delivery: ao_gate holds the others.
  [ "$OP_CLIENT" = file-only ] || OP_CLIENT=$L_provider
  [ "$L_state" != released ] || return 0
  OP_NAME=$L_session
  OP_SID=$L_session_id
  [ "$OP_SID" != - ] || OP_SID=
}

# ---------------------------------------------------------------- git

# ao_git_commit HOME MESSAGE FILE...  Commit exactly FILE... (paths relative
# to HOME) when they differ from HEAD; other staged changes are untouched.
ao_git_commit() {
  _ao_gh=$1 _ao_gm=$2
  shift 2
  git -C "$_ao_gh" rev-parse --git-dir >/dev/null 2>&1 || { ao_msg "$_ao_gh is not in a git repository"; return 1; }
  git -C "$_ao_gh" add -- "$@" || return 1
  if git -C "$_ao_gh" diff --cached --quiet HEAD -- "$@" 2>/dev/null; then
    return 0
  fi
  git -C "$_ao_gh" commit -q -m "$_ao_gm" --only -- "$@" >/dev/null || return 1
}

# ao_git_clean HOME FILE  True when FILE has no uncommitted change.
ao_git_clean() {
  git -C "$1" diff --quiet HEAD -- "$2" 2>/dev/null &&
    git -C "$1" diff --cached --quiet HEAD -- "$2" 2>/dev/null
}

# ---------------------------------------------------------------- asks

# ASKS.md table rows: | id | generation | epoch | action | target |
# revision | risk | rollback | status |

# ao_ask_row FILE ID  Print the row's fields tab-separated (trimmed), or
# fail when there is no such row.
ao_ask_row() {
  [ -r "$1" ] || return 1
  awk -F'|' -v id="$2" '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    NF >= 11 && t($2) == id {
      print t($2) "\t" t($3) "\t" t($4) "\t" t($5) "\t" t($6) "\t" t($7) "\t" t($8) "\t" t($9) "\t" t($10)
      found = 1; exit
    }
    END { exit !found }' "$1"
}

# ao_ask_set_status FILE ID STATUS  Rewrite one row's status (atomic).
ao_ask_set_status() {
  _ao_at=$(mktemp "$(dirname -- "$1")/.asks.XXXXXX") || return 1
  awk -F"|" -v id="$2" -v st="$3" '
    BEGIN { OFS = "|" }
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    NF >= 11 && t($2) == id { $10 = " " st " "; print; next }
    { print }' "$1" >"$_ao_at" || { rm -f "$_ao_at"; return 1; }
  mv -f "$_ao_at" "$1" || { rm -f "$_ao_at"; return 1; }
}

# ao_asks_with_status FILE STATUS...  Print "id action target revision"
# for every row whose status is one of STATUS.
ao_asks_with_status() {
  _ao_af=$1
  shift
  [ -r "$_ao_af" ] || return 0
  awk -F'|' -v want=" $* " '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    NF >= 11 && t($2) ~ /-[0-9]+$/ && index(want, " " t($10) " ") {
      print t($2) " (epoch " t($4) "): " t($5) " " t($6) " at " t($7) " [" t($10) "]"
    }' "$_ao_af"
}
