# shellcheck shell=sh disable=SC2034
# (SC2034: the AO_* globals set here are read by the sourcing scripts.)
# core.sh - shared foundation for the agent-operations scripts.
#
# Sourced, never executed. Provides: messages and exit codes, profile loading,
# path resolution, one-shot clock, file helpers, temp-file cleanup, locking,
# timeouts and secrets. POSIX sh; no bashisms. Every public function is
# prefixed `ao_`; every global it sets is prefixed `AO_`.
#
# Exit codes shared by every script:
#   0  success (or nothing to do)
#   1  runtime failure, or findings for check-style commands
#   2  usage or configuration error
#   3  busy: another instance holds the lock (callers treat it as benign)
#   4  a required role is not configured in the profile
#   124 a child command hit its timeout

AO_E_FAIL=1
AO_E_USAGE=2
AO_E_BUSY=3
AO_E_ROLE=4
AO_E_TIMEOUT=124

AO_PROG=${AO_PROG:-${0##*/}}
AO_TAB=$(printf '\t')
AO_NL='
'
AO_LOCK=
AO_LOCK_FD=
# Grace period (seconds) between TERM and KILL for timed-out or interrupted
# children. Tests lower it.
AO_GRACE=${AO_GRACE:-10}
case $AO_GRACE in '' | *[!0-9]*) AO_GRACE=10 ;; esac
# Byte-wise collation, so globs, sort and [A-Za-z] ranges behave the same
# under launchd's C locale and an interactive UTF-8 shell.
if [ -n "${LC_ALL:-}" ]; then
  LC_CTYPE=$LC_ALL
  export LC_CTYPE
  unset LC_ALL
fi
LC_COLLATE=C
export LC_COLLATE
# Child setup for ao_timeout: working directory and one secret variable,
# applied only inside the child. Callers set them and clear them after.
AO_RUN_DIR=
_AO_TOK_ENV='' _AO_TOK_VAL=''
# One private (0700) temp dir per process, removed on exit; see ao_tmp.
AO_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ao.XXXXXX") || {
  printf '%s: cannot create a temp dir\n' "$AO_PROG" >&2
  exit 1
}

# ---------------------------------------------------------------- messages

ao_msg() { printf '%s: %s\n' "$AO_PROG" "$*" >&2; }
ao_warn() { ao_msg "warning: $*"; }

# ao_die CODE MESSAGE...  Print MESSAGE and exit. If AO_ON_DIE names a
# function, it is called once first as `<fn> CODE MESSAGE`, so a scheduled
# job can route its own configuration or preflight failure somewhere a human
# will see it.
ao_die() {
  _ao_rc=$1
  shift
  ao_msg "$*"
  if [ -n "${AO_ON_DIE:-}" ]; then
    _ao_hook=$AO_ON_DIE
    AO_ON_DIE=
    "$_ao_hook" "$_ao_rc" "$*"
  fi
  exit "$_ao_rc"
}

# ao_usage  Print the calling script's header comment (from line 2 up to
# the first non-comment line) as its help text.
ao_usage() {
  sed -n '2,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "$0"
}

# ao_log FILE MESSAGE...  Append one timestamped line to a log file.
ao_log() {
  _ao_f=$1
  shift
  printf '%s %s\n' "$AO_T_ISO" "$*" >>"$_ao_f"
}

# ---------------------------------------------------------------- cleanup

ao_cleanup() {
  # A directory lock is released only if this process still owns it; a
  # kernel lock goes with the descriptor when the process exits.
  if [ -n "$AO_LOCK" ] && [ -z "$AO_LOCK_FD" ] && [ "$(cat "$AO_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$AO_LOCK"
  fi
  AO_LOCK=
  rm -rf "$AO_TMPDIR"
}
# ao_on_signal CODE  Stop a running timed child (TERM, a grace period, then
# KILL, to its process group where it has one) and wait for it, then exit;
# only then does the EXIT trap release the lock and temp files.
ao_on_signal() {
  if [ -n "${AO_CHILD:-}" ]; then
    kill -s TERM -- "-$AO_CHILD" 2>/dev/null || kill -s TERM "$AO_CHILD" 2>/dev/null
    # Twice the grace: the child may itself be supervising a timed client.
    _n=0
    while [ "$_n" -lt $((AO_GRACE * 2 + 1)) ] && kill -0 "$AO_CHILD" 2>/dev/null; do
      sleep 1
      _n=$((_n + 1))
    done
    kill -s KILL -- "-$AO_CHILD" 2>/dev/null || kill -s KILL "$AO_CHILD" 2>/dev/null
    wait "$AO_CHILD" 2>/dev/null
    _ao_reap "$AO_CHILD"
    AO_CHILD=
  fi
  exit "$1"
}
trap ao_cleanup EXIT
trap 'ao_on_signal 129' HUP
trap 'ao_on_signal 130' INT
trap 'ao_on_signal 143' TERM

# ao_tmp NAME  Create (empty) and print the path of a scratch file in this
# process's private temp dir. Safe inside $(...): nothing to register.
ao_tmp() {
  : >"$AO_TMPDIR/$1" || ao_die "$AO_E_FAIL" "cannot create $AO_TMPDIR/$1"
  printf '%s\n' "$AO_TMPDIR/$1"
}

# ---------------------------------------------------------------- validation

# ao_is_name STRING  True for a safe identifier: [A-Za-z0-9._-]+, no leading dot.
ao_is_name() {
  case $1 in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# ao_is_uint STRING  True for a non-negative decimal integer.
ao_is_uint() {
  case $1 in '' | *[!0-9]*) return 1 ;; esac
  return 0
}

# ao_repo_key URL  Print a canonical identity for a git remote, so the
# spellings of one repository compare equal: scheme, user and port dropped,
# scp-style host:path turned into host/path, host lowercased, a trailing
# slash and .git removed. git@host:o/r.git, ssh://git@host:22/o/r and
# https://host/o/r/ all give host/o/r.
ao_repo_key() {
  printf '%s\n' "$1" | sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|^[^@/]*@||' \
    -e 's|^\([^/:]*\):[0-9][0-9]*/|\1/|' -e 's|^\([^/:]*\):|\1/|' -e 's|/*$||' -e 's|\.git$||' |
    awk -F/ 'BEGIN { OFS = "/" } { $1 = tolower($1); print }'
}

# ao_slug STRING  Print STRING reduced to a filename-safe slug.
ao_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.-]*//' | cut -c1-60
}

# ao_is_nothing FILE  True when a model's whole answer is NOTHING, ignoring
# surrounding blank space, backticks, quotes, asterisks and a final period.
ao_is_nothing() {
  _ao_a=$(tr -d ' \t\r\n`"*' <"$1")
  [ "${_ao_a%.}" = NOTHING ]
}

# ---------------------------------------------------------------- profile

# Every key the kit reads. Unknown keys warn (typo guard); `x_*` keys are
# reserved for local hooks and adapters and never warn.
AO_KNOWN_KEYS='oracle_home oracle_key registry quiet_list inbox_dir sent_dir
state_dir hooks_dir path
watchdog_days watchdog_hours watchdog_idle_min watchdog_realert_min
daily_hour weekly_day weekly_hour hook_timeout
relay_default relay_codex relay_label relay_max_attempts relay_workdir work_root
drift_rules drift_files drift_repo_files drift_min_words drift_prompt
drift_prompt_extra drift_workdir drift_to
review_family cross_review cross_review_timeout cross_review_per_run
cross_review_days tracker chat githost ci secrets attribution
lease_stale doorbell_codex doorbell_rering_min
relay_bridge bridge_dir bridge_codex_node bridge_codex_server bridge_claude_t1
wake_link host_apps host_latency_jobs host_launchd_dirs owner_tz archive_dir'
# Host defaults (install.sh host, check.sh host): desktop apps whose App Nap
# is turned off, launchd label patterns that must not run as Background,
# and the launchd folders scanned.
AO_HOST_APPS='com.anthropic.claudefordesktop com.openai.codex'
AO_HOST_LATENCY_JOBS='*agent-operations*'
# shellcheck disable=SC2088 # expanded later by ao_expand_path
AO_HOST_LAUNCHD_DIRS='~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons'
# Role keys: <prefix>_<field> for these prefixes and fields.
AO_ROLE_PREFIXES='worker reviewer reviewer_claude reviewer_codex implementer_claude
implementer_codex relay_claude relay_codex relay_custom'
AO_ROLE_FIELDS='client cmd model effort timeout mcp_disable tools max_turns
disallowed_tools token_secret token_env'

_ao_key_known() {
  case $1 in x_*) return 0 ;; esac
  for _ao_k in $AO_KNOWN_KEYS; do [ "$_ao_k" = "$1" ] && return 0; done
  for _ao_p in $AO_ROLE_PREFIXES; do
    case $1 in "$_ao_p"_*)
      for _ao_fld in $AO_ROLE_FIELDS; do
        [ "$1" = "${_ao_p}_$_ao_fld" ] && return 0
      done ;;
    esac
  done
  return 1
}

# ao_profile_path  Print the profile path in effect.
ao_profile_path() {
  printf '%s\n' "${AO_PROFILE:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-operations/profile}"
}

# ao_profile_parse FILE  Read a flat key=value profile into AO_C_<key>
# variables. Never sources or evaluates the file's contents: values are
# assigned verbatim (one surrounding pair of quotes is stripped).
ao_profile_parse() {
  [ -r "$1" ] || ao_die "$AO_E_USAGE" "profile not readable: $1 (set AO_PROFILE; examples in profiles/)"
  # Only the file may set profile values: drop any AO_C_* from the
  # environment first.
  for _ao_v in $(env | sed -n 's/^\(AO_C_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$_ao_v"
  done
  _ao_n=0
  while IFS= read -r _ao_line || [ -n "$_ao_line" ]; do
    _ao_n=$((_ao_n + 1))
    _ao_line=${_ao_line#"${_ao_line%%[![:space:]]*}"}
    case $_ao_line in '' | '#'*) continue ;; esac
    case $_ao_line in *=*) ;; *) ao_die "$AO_E_USAGE" "$1:$_ao_n: expected key=value" ;; esac
    _ao_key=${_ao_line%%=*}
    _ao_key=${_ao_key%"${_ao_key##*[![:space:]]}"}
    _ao_val=${_ao_line#*=}
    _ao_val=${_ao_val#"${_ao_val%%[![:space:]]*}"}
    _ao_val=${_ao_val%"${_ao_val##*[![:space:]]}"}
    case $_ao_val in
      \"*\") _ao_val=${_ao_val#\"} _ao_val=${_ao_val%\"} ;;
      \'*\') _ao_val=${_ao_val#\'} _ao_val=${_ao_val%\'} ;;
    esac
    case $_ao_key in '' | *[!a-z0-9_]*)
      ao_die "$AO_E_USAGE" "$1:$_ao_n: invalid key '$_ao_key' (use a-z, 0-9, _)" ;;
    esac
    _ao_key_known "$_ao_key" || ao_warn "$1:$_ao_n: unknown key '$_ao_key' (ignored)"
    eval "AO_C_$_ao_key=\$_ao_val"
  done <"$1"
}

# ao_cfg KEY [DEFAULT]  Print the profile value of KEY, or DEFAULT when the
# key is absent or empty. KEY is a trusted identifier.
ao_cfg() {
  eval "_ao_cv=\${AO_C_$1-}"
  printf '%s\n' "${_ao_cv:-${2-}}"
}

# ao_cfg_uint KEY DEFAULT  As ao_cfg, but the value must be a non-negative
# integer; otherwise exits 2. Use as: v=$(ao_cfg_uint key 5) || exit
ao_cfg_uint() {
  _ao_v=$(ao_cfg "$1" "$2")
  ao_is_uint "$_ao_v" || ao_die "$AO_E_USAGE" "profile key $1 must be a non-negative integer, got '$_ao_v'"
  printf '%s\n' "$_ao_v"
}

# ao_expand_path PATH [BASE]  Print PATH with a leading ~/ expanded and, when
# relative, resolved against BASE (default: the Oracle home).
ao_expand_path() {
  case $1 in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "${2:-$AO_HOME}" "$1" ;;
  esac
}

# ao_cfg_path KEY DEFAULT  As ao_cfg, then ao_expand_path; empty stays empty.
ao_cfg_path() {
  _ao_cp=$(ao_cfg "$1" "$2")
  [ -z "$_ao_cp" ] || ao_expand_path "$_ao_cp"
}

# ao_load [--no-state]  Load the profile and derive the common paths. Exports
# the AO_* variables hooks and adapters rely on. Creates the state dir.
ao_load() {
  AO_PROFILE=$(ao_profile_path)
  ao_profile_parse "$AO_PROFILE"
  AO_HOME=$(ao_cfg oracle_home '')
  [ -n "$AO_HOME" ] || ao_die "$AO_E_USAGE" "profile key oracle_home is required ($AO_PROFILE)"
  AO_HOME=$(ao_expand_path "$AO_HOME" /)
  [ -d "$AO_HOME" ] || ao_die "$AO_E_USAGE" "oracle_home is not a directory: $AO_HOME"
  AO_ORACLE_KEY=$(ao_cfg oracle_key oracle)
  ao_is_name "$AO_ORACLE_KEY" || ao_die "$AO_E_USAGE" "invalid oracle_key '$AO_ORACLE_KEY'"
  AO_REGISTRY=$(ao_cfg_path registry operators/REGISTRY.tsv)
  AO_QUIET=$(ao_cfg_path quiet_list operators/WATCHDOG-QUIET.tsv)
  AO_INBOX=$(ao_cfg_path inbox_dir inbox)
  AO_SENT=$(ao_cfg_path sent_dir "$AO_INBOX/sent")
  AO_STATE=$(ao_cfg_path state_dir "${XDG_STATE_HOME:-$HOME/.local/state}/agent-operations")
  AO_HOOKS=$(ao_cfg_path hooks_dir hooks)
  _ao_path=$(ao_cfg path '')
  [ -z "$_ao_path" ] || PATH=$_ao_path
  : "${AO_SCRIPTS:?scripts must set AO_SCRIPTS before ao_load}"
  export PATH AO_PROFILE AO_HOME AO_ORACLE_KEY AO_INBOX AO_STATE AO_SCRIPTS
  [ "${1-}" = --no-state ] || mkdir -p "$AO_STATE" || ao_die "$AO_E_FAIL" "cannot create state dir $AO_STATE"
  ao_clock
}

# ---------------------------------------------------------------- clock

# ao_clock  Read the clock once. AO_NOW (epoch seconds) pins it for tests.
# Sets AO_T_EPOCH, AO_T_DATE (YYYY-MM-DD), AO_T_HOUR (0-23, no padding),
# AO_T_DOW (1=Mon..7), AO_T_WEEK (ISO YYYY-Www), AO_T_STAMP, AO_T_ISO.
ao_clock() {
  _ao_fmt='+%s %Y-%m-%d %H %u %G-W%V %Y%m%dT%H%M%S %Y-%m-%dT%H:%M:%S%z'
  if [ -z "${AO_NOW:-}" ]; then
    _ao_now=$(date "$_ao_fmt")
  elif date -d "@$AO_NOW" +%s >/dev/null 2>&1; then
    _ao_now=$(date -d "@$AO_NOW" "$_ao_fmt")
  else
    _ao_now=$(date -r "$AO_NOW" "$_ao_fmt")
  fi
  # shellcheck disable=SC2086 # deliberate split of date's fixed-format output
  set -- $_ao_now
  AO_T_EPOCH=$1 AO_T_DATE=$2 AO_T_HOUR=$(($(printf '%s' "$3" | sed 's/^0//'))) AO_T_DOW=$4
  AO_T_WEEK=$5 AO_T_STAMP=$6 AO_T_ISO=$7
}

# ---------------------------------------------------------------- files

# ao_mtime FILE  Print FILE's modification time in epoch seconds.
ao_mtime() {
  if [ -z "${_AO_STAT:-}" ]; then
    if stat -c %Y / >/dev/null 2>&1; then _AO_STAT=gnu; else _AO_STAT=bsd; fi
  fi
  if [ "$_AO_STAT" = gnu ]; then stat -c %Y "$1"; else stat -f %m "$1"; fi
}

# ao_write_atomic DEST  Copy stdin to DEST via a temp file in the same
# directory, so readers never see a partial file.
ao_write_atomic() {
  _ao_dir=$(dirname -- "$1")
  mkdir -p "$_ao_dir" || return 1
  _ao_tmp=$(mktemp "$_ao_dir/.tmp.XXXXXX") || return 1
  if cat >"$_ao_tmp" && mv -f "$_ao_tmp" "$1"; then return 0; fi
  rm -f "$_ao_tmp"
  return 1
}

# ao_place SRC BASE EXT  Move SRC to BASE.EXT, or BASE-2.EXT, BASE-3.EXT...
# without ever replacing an existing file: link(2) refuses an existing name,
# so concurrent writers cannot overwrite each other. A SRC on another
# filesystem is copied once to a temp file beside the destination and that
# copy is linked; a destination filesystem without hard links fails closed.
# Fails (status 1) if SRC cannot be removed afterwards. Prints the path.
ao_place() {
  if _ao_dest=$(_ao_link_noclobber "$1" "$2" "$3"); then
    rm -f "$1" || return 1
    printf '%s\n' "$_ao_dest"
    return 0
  fi
  [ "$_ao_dest" = nolink ] || return 1
  _ao_stage=$(mktemp "$(dirname -- "$2")/.tmp.XXXXXX") || return 1
  if cp "$1" "$_ao_stage" && _ao_dest=$(_ao_link_noclobber "$_ao_stage" "$2" "$3"); then
    rm -f "$_ao_stage" "$1" || return 1
    printf '%s\n' "$_ao_dest"
    return 0
  fi
  rm -f "$_ao_stage"
  [ "$_ao_dest" != nolink ] || ao_warn "cannot hard-link in $(dirname -- "$2"); not placing $1"
  return 1
}

# _ao_link_noclobber SRC BASE EXT  Hard-link SRC to the first free name and
# print it. Prints `nolink` and fails when linking fails for any reason
# other than a taken name (other filesystem, no hard-link support).
_ao_link_noclobber() {
  _ao_to=$2$3
  _ao_i=1
  while ! ln "$1" "$_ao_to" 2>/dev/null; do
    if [ ! -e "$_ao_to" ]; then
      echo nolink
      return 1
    fi
    _ao_i=$((_ao_i + 1))
    [ "$_ao_i" -le 999 ] || return 1
    _ao_to=$2-$_ao_i$3
  done
  printf '%s\n' "$_ao_to"
}

# ---------------------------------------------------------------- locking

# ao_lock NAME  Take this process's one exclusive lock; returns 3 while
# another process holds it. The lock is a kernel lock on
# <state_dir>/locks/NAME.lock held through file descriptor 9: flock(1) on
# Linux, lockf(1) on macOS and the BSDs. The kernel drops it when the
# process exits, however it exits, so a crash, a reboot or a recycled pid
# can never leave it stuck. Children never inherit descriptor 9 (see
# ao_timeout). AO_LOCK_TOOL (flock, lockf or mkdir) forces a mechanism.
#
# Without either tool the fallback is a directory lock: mkdir is atomic, and
# a lock whose holder is gone is reclaimed under a marker named after that
# dead holder (<lock>.reclaim-<pid>), re-checked under the marker, so two
# processes never both hold it. Its known limit: liveness is `kill -0`, so a
# recycled pid keeps a stale lock until that process exits.
ao_lock() {
  [ -z "$AO_LOCK" ] || ao_die "$AO_E_FAIL" "ao_lock: already holding $AO_LOCK"
  mkdir -p "$AO_STATE/locks" || return "$AO_E_FAIL"
  _ao_tool=${AO_LOCK_TOOL:-}
  if [ -z "$_ao_tool" ]; then
    if command -v flock >/dev/null 2>&1; then _ao_tool=flock
    elif command -v lockf >/dev/null 2>&1; then _ao_tool=lockf
    else _ao_tool='mkdir'; fi
  fi
  case $_ao_tool in
    flock | lockf)
      _ao_lf=$AO_STATE/locks/$1.lk
      exec 9>>"$_ao_lf" || return "$AO_E_FAIL"
      if [ "$_ao_tool" = flock ]; then flock -n 9 2>/dev/null; else lockf -s -t 0 9 2>/dev/null; fi || {
        exec 9>&-
        return "$AO_E_BUSY"
      }
      AO_LOCK=$_ao_lf AO_LOCK_FD=9
      return 0 ;;
    mkdir) _ao_lock_dir "$AO_STATE/locks/$1.lock" ;;
    *) ao_die "$AO_E_USAGE" "AO_LOCK_TOOL must be flock, lockf or mkdir" ;;
  esac
}

_ao_lock_dir() {
  _ao_ld=$1
  if ! _ao_lock_take "$_ao_ld"; then
    _ao_gen=$(_ao_lock_owner "$_ao_ld")
    _ao_lock_live "$_ao_ld" "$_ao_gen" && return "$AO_E_BUSY"
    _ao_mark=$_ao_ld.reclaim-$_ao_gen
    if ! mkdir "$_ao_mark" 2>/dev/null; then
      # A reclaimer that died mid-way leaves its marker: clear it once its
      # own pid is gone (or it never wrote one and is old), and try again
      # on the next run.
      _ao_rp=$(_ao_lock_owner "$_ao_mark")
      if ! _ao_lock_live "$_ao_mark" "$_ao_rp"; then
        ao_warn "clearing an abandoned reclaim marker $_ao_mark"
        rm -rf "$_ao_mark"
      fi
      return "$AO_E_BUSY"
    fi
    printf '%s\n' "$$" >"$_ao_mark/pid"
    _ao_got=$AO_E_BUSY
    if [ "$(_ao_lock_owner "$_ao_ld")" = "$_ao_gen" ] && ! _ao_lock_live "$_ao_ld" "$_ao_gen"; then
      ao_warn "reclaiming stale lock $_ao_ld (holder $_ao_gen is gone)"
      rm -rf "$_ao_ld"
      _ao_lock_take "$_ao_ld" && _ao_got=0
    fi
    rm -rf "$_ao_mark"
    [ "$_ao_got" -eq 0 ] || return "$AO_E_BUSY"
  fi
  AO_LOCK=$_ao_ld
}

_ao_lock_take() {
  mkdir "$1" 2>/dev/null && printf '%s\n' "$$" >"$1/pid"
}

# _ao_lock_owner DIR  Print the holder's pid, `nopid` if none is recorded
# yet, or `gone` if DIR no longer exists.
_ao_lock_owner() {
  if _ao_pid=$(cat "$1/pid" 2>/dev/null) && ao_is_uint "$_ao_pid"; then
    printf '%s\n' "$_ao_pid"
  elif [ -d "$1" ]; then
    echo nopid
  else
    echo gone
  fi
}

# _ao_lock_live DIR OWNER  True while OWNER is alive, or DIR has no pid yet
# and is too young to judge.
_ao_lock_live() {
  case $2 in
    gone) return 1 ;;
    nopid) _ao_young "$1" ;;
    *) kill -0 "$2" 2>/dev/null ;;
  esac
}

_ao_young() {
  _ao_m=$(ao_mtime "$1" 2>/dev/null) || return 1
  [ $(($(date +%s) - _ao_m)) -lt 60 ]
}

# ---------------------------------------------------------------- timeouts

# ao_timeout SECONDS CMD [ARG...]  Run an external command with stdin from
# /dev/null and a hard time limit (0 = none). Returns the command's status,
# or 124 on timeout. Uses coreutils timeout/gtimeout when present, otherwise
# a portable watcher; either way TERM, then KILL 10 s later, go to the
# command's process group, so descendants do not outlive the limit (the
# portable watcher has a process group only in shells that allow job control
# without a terminal, such as bash's sh; dash signals the direct child). A
# HUP, INT or TERM to the caller is forwarded to the child the same way,
# provided the caller runs ao_timeout in its own shell (not inside a
# foreground subshell, whose wait would defer the trap): see ao_bg.
# The child starts in AO_RUN_DIR when set, gets _AO_TOK_ENV=_AO_TOK_VAL in
# its environment when set (so a token never enters the caller's), and never
# inherits the lock descriptor 9. AO_TIMEOUT_BIN=none forces the portable
# path; AO_GRACE sets the TERM-to-KILL grace (default 10 s).
ao_timeout() {
  _ao_secs=$1
  shift
  ao_is_uint "$_ao_secs" || ao_die "$AO_E_USAGE" "timeout must be an integer, got '$_ao_secs'"
  if [ -z "${_AO_TBIN+x}" ]; then
    _AO_TBIN=${AO_TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || true)}
    [ "$_AO_TBIN" != none ] || _AO_TBIN=
  fi
  _ao_core=
  if [ "$_ao_secs" -gt 0 ] && [ -n "$_AO_TBIN" ]; then
    set -- "$_AO_TBIN" -k "$AO_GRACE" "$_ao_secs" "$@"
    _ao_core=1
  fi
  _ao_mark=$AO_TMPDIR/timeout.$$
  rm -f "$_ao_mark"
  # Subshells start with default traps; re-arm forwarding for this child.
  trap 'ao_on_signal 129' HUP
  trap 'ao_on_signal 130' INT
  trap 'ao_on_signal 143' TERM
  # Job control gives the background command its own process group.
  set -m 2>/dev/null
  _ao_child "$@" </dev/null 9>&- &
  AO_CHILD=$!
  set +m 2>/dev/null
  _ao_pg=$AO_CHILD _ao_wpid=
  if [ -z "$_ao_core" ] && [ "$_ao_secs" -gt 0 ]; then
    _ao_watch "$AO_CHILD" "$_ao_secs" "$_ao_mark" &
    _ao_wpid=$!
  fi
  wait "$AO_CHILD"
  _ao_rc=$?
  AO_CHILD=
  if [ -n "$_ao_wpid" ]; then
    kill "$_ao_wpid" 2>/dev/null
    wait "$_ao_wpid" 2>/dev/null
    [ ! -e "$_ao_mark" ] || _ao_rc=$AO_E_TIMEOUT
    rm -f "$_ao_mark"
  elif [ -n "$_ao_core" ] && [ "$_ao_rc" -eq 137 ]; then
    _ao_rc=$AO_E_TIMEOUT
  fi
  # The timed command may be gone while descendants that ignored TERM live
  # on in its process group: give them the grace period, then KILL.
  [ "$_ao_rc" -ne "$AO_E_TIMEOUT" ] || _ao_reap "$_ao_pg"
  return "$_ao_rc"
}

# _ao_child CMD [ARG...]  Body of ao_timeout's child: apply AO_RUN_DIR and
# the token variable, then become CMD.
_ao_child() {
  if [ -n "$AO_RUN_DIR" ]; then cd "$AO_RUN_DIR" || exit "$AO_E_USAGE"; fi
  if [ -n "$_AO_TOK_ENV" ]; then
    eval "$_AO_TOK_ENV=\$_AO_TOK_VAL"
    eval "export $_AO_TOK_ENV"
  fi
  exec "$@"
}

# ao_bg CMD [ARG...]  Run CMD (often a shell function, which then runs in a
# subshell) in the background and wait for it, so a signal to this shell is
# handled at once and forwarded to it rather than deferred until it ends.
# Returns CMD's status.
ao_bg() {
  "$@" 9>&- &
  AO_CHILD=$!
  wait "$AO_CHILD"
  _ao_bgrc=$?
  AO_CHILD=
  return "$_ao_bgrc"
}

# _ao_watch PID SECONDS MARK  Portable watchdog for ao_timeout: after
# SECONDS, mark the timeout, TERM PID (its group where it has one) and KILL
# it 10 s later if it is still there. Polls once a second, so it ends on its
# own soon after PID does.
_ao_watch() {
  _n=0
  while kill -0 "$1" 2>/dev/null; do
    if [ "$_n" -ge "$2" ]; then
      : >"$3"
      kill -s TERM -- "-$1" 2>/dev/null || kill -s TERM "$1" 2>/dev/null
      _n=0
      while [ "$_n" -lt "$AO_GRACE" ] && kill -0 "$1" 2>/dev/null; do
        sleep 1
        _n=$((_n + 1))
      done
      kill -s KILL -- "-$1" 2>/dev/null || kill -s KILL "$1" 2>/dev/null
      exit 0
    fi
    sleep 1
    _n=$((_n + 1))
  done
}

# _ao_reap PGID  After a timeout: TERM the process group, wait up to 10 s
# for it to empty, then KILL whatever is left. No-op without a group.
_ao_reap() {
  kill -s TERM -- "-$1" 2>/dev/null || return 0
  _n=0
  while [ "$_n" -lt "$AO_GRACE" ] && kill -0 -- "-$1" 2>/dev/null; do
    sleep 1
    _n=$((_n + 1))
  done
  kill -s KILL -- "-$1" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- secrets

# ao_secret NAME  Print a secret from the `secrets` slot to stdout: `os` uses
# the macOS keychain or libsecret (Linux, untested), `none` yields nothing,
# anything else is an adapter run as `<adapter> get NAME`. Never logs it.
ao_secret() {
  _ao_slot=$(ao_cfg secrets os)
  case $_ao_slot in
    none) return 1 ;;
    os)
      if command -v security >/dev/null 2>&1; then
        security find-generic-password -s "$1" -w 2>/dev/null
      elif command -v secret-tool >/dev/null 2>&1; then
        secret-tool lookup service "$1" 2>/dev/null
      else
        return 1
      fi ;;
    *) "$(ao_expand_path "$_ao_slot")" get "$1" </dev/null 2>/dev/null ;;
  esac
}
