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
AO_LOCKS=
# One private (0700) temp dir per process, removed on exit; see ao_tmp.
AO_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ao.XXXXXX") || {
  printf '%s: cannot create a temp dir\n' "$AO_PROG" >&2
  exit 1
}

# ---------------------------------------------------------------- messages

ao_msg() { printf '%s: %s\n' "$AO_PROG" "$*" >&2; }
ao_warn() { ao_msg "warning: $*"; }

# ao_die CODE MESSAGE...
ao_die() {
  _ao_rc=$1
  shift
  ao_msg "$*"
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
  for _ao_l in $AO_LOCKS; do rm -rf "$_ao_l"; done
  rm -rf "$AO_TMPDIR"
  AO_LOCKS=
}
trap ao_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

# ao_slug STRING  Print STRING reduced to a filename-safe slug.
ao_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.-]*//' | cut -c1-60
}

# ---------------------------------------------------------------- profile

# Every key the kit reads. Unknown keys warn (typo guard); `x_*` keys are
# reserved for local hooks and adapters and never warn.
AO_KNOWN_KEYS='oracle_home oracle_key registry quiet_list inbox_dir sent_dir
state_dir hooks_dir path
watchdog_days watchdog_hours watchdog_idle_min watchdog_realert_min
daily_hour weekly_day weekly_hour hook_timeout
relay_default relay_label relay_max_bytes relay_workdir
drift_rules drift_files drift_repo_files drift_min_words drift_prompt
drift_prompt_extra drift_workdir drift_to
review_family tracker chat githost ci secrets attribution'
# Role keys: <prefix>_<field> for these prefixes and fields.
AO_ROLE_PREFIXES='worker reviewer relay_claude relay_codex relay_custom'
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

# ---------------------------------------------------------------- locking

# ao_lock NAME  Take an exclusive, self-releasing lock (mkdir is atomic).
# Returns 3 when a live process holds it. A lock whose holder is gone is
# reclaimed; one with no pid yet is treated as live for 60 s.
ao_lock() {
  _ao_ld=$AO_STATE/locks/$1.lock
  mkdir -p "$AO_STATE/locks" || return "$AO_E_FAIL"
  if ! mkdir "$_ao_ld" 2>/dev/null; then
    _ao_pid=$(cat "$_ao_ld/pid" 2>/dev/null) || _ao_pid=
    if [ -n "$_ao_pid" ]; then
      kill -0 "$_ao_pid" 2>/dev/null && return "$AO_E_BUSY"
    elif [ $(($(date +%s) - $(ao_mtime "$_ao_ld"))) -lt 60 ]; then
      return "$AO_E_BUSY"
    fi
    ao_warn "reclaiming stale lock $_ao_ld (holder ${_ao_pid:-unknown} is gone)"
    rm -rf "$_ao_ld"
    mkdir "$_ao_ld" 2>/dev/null || return "$AO_E_BUSY"
  fi
  printf '%s\n' "$$" >"$_ao_ld/pid"
  AO_LOCKS="$AO_LOCKS $_ao_ld"
}

# ---------------------------------------------------------------- timeouts

# ao_timeout SECONDS CMD [ARG...]  Run an external command with a hard time
# limit; 0 means none. Returns the command's status, or 124 on timeout.
# Uses coreutils timeout/gtimeout when present (kills the whole process
# group); otherwise a portable watcher that signals the direct child only.
# AO_TIMEOUT_BIN=none forces the portable path.
ao_timeout() {
  _ao_secs=$1
  shift
  ao_is_uint "$_ao_secs" || ao_die "$AO_E_USAGE" "timeout must be an integer, got '$_ao_secs'"
  [ "$_ao_secs" -gt 0 ] || { "$@"; return; }
  if [ -z "${_AO_TBIN+x}" ]; then
    _AO_TBIN=${AO_TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || true)}
    [ "$_AO_TBIN" != none ] || _AO_TBIN=
  fi
  if [ -n "$_AO_TBIN" ]; then
    "$_AO_TBIN" -k 10 "$_ao_secs" "$@"
    _ao_rc=$?
    [ "$_ao_rc" -eq 137 ] && _ao_rc=$AO_E_TIMEOUT
    return "$_ao_rc"
  fi
  _ao_mark=$(mktemp "${TMPDIR:-/tmp}/ao.to.XXXXXX") && rm -f "$_ao_mark"
  "$@" &
  _ao_cpid=$!
  (
    _n=0
    while kill -0 "$_ao_cpid" 2>/dev/null; do
      if [ "$_n" -ge "$_ao_secs" ]; then
        : >"$_ao_mark"
        kill -TERM "$_ao_cpid" 2>/dev/null
        sleep 5
        kill -KILL "$_ao_cpid" 2>/dev/null
        exit 0
      fi
      sleep 1
      _n=$((_n + 1))
    done
  ) &
  _ao_wpid=$!
  wait "$_ao_cpid"
  _ao_rc=$?
  kill "$_ao_wpid" 2>/dev/null
  wait "$_ao_wpid" 2>/dev/null
  if [ -e "$_ao_mark" ]; then
    rm -f "$_ao_mark"
    _ao_rc=$AO_E_TIMEOUT
  fi
  return "$_ao_rc"
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
