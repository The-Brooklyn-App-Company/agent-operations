# shellcheck shell=sh disable=SC2034,SC2153
# (R_* globals set here are read by the vendor files; OP_* come from
# registry.sh.)
# vendor.sh - roles and the one interface every harness (vendor) implements.
#
# Sourced after core.sh. A role is a profile prefix (worker, reviewer,
# relay_claude, ...) whose keys say which client runs it and how:
#   <prefix>_client       claude | codex | custom | none
#   <prefix>_cmd          executable (name on PATH or a path); default: client
#   <prefix>_model        model id; empty = the client's own default
#   <prefix>_effort       reasoning effort, where the client supports it
#   <prefix>_timeout      hard limit in seconds (0 = none)
#   <prefix>_mcp_disable  extra tool servers to switch off (codex); every
#                         configured server is switched off anyway, and
#                         claude runs load no tool servers at all
#   <prefix>_tools        claude tool allow-list; default Read,Grep,Glob for
#                         runs, ListAgents,SendMessage for delivery
#   <prefix>_max_turns    claude turn cap
#   <prefix>_disallowed_tools  claude deny-list, added on top
#   <prefix>_token_secret secret name fetched via the `secrets` slot
#   <prefix>_token_env    env var that receives it (claude default:
#                         CLAUDE_CODE_OAUTH_TOKEN)
#
# Each vendor file lib/vendor-<client>.sh defines three functions:
#   vendor_<client>_run WORKDIR PROMPT_FILE OUT_FILE ERR_FILE
#       one headless, read-only, ephemeral run with stdin closed; the final
#       answer goes to OUT_FILE, diagnostics to ERR_FILE; returns the status
#   vendor_<client>_deliver NAME SESSION MESSAGE_FILE OUT_FILE RELAY_ID
#       submit MESSAGE_FILE (which contains RELAY_ID) for that session;
#       0 only on a client receipt. Codex treats exit 0 as queue submission,
#       not resume or recipient execution. One isolated live ordinary-relay
#       round trip is recorded in README; both lease-mail doorbells are unrun.
#       A confirmed delivery with a caveat writes `warning: ...` as the first
#       line of OUT_FILE.
#   vendor_<client>_activity DIR SESSION
#       print the epoch time of the session's last activity, or nothing
# Callers use ao_role_run, ao_role_deliver and ao_activity, never the vendor
# functions directly, so a new harness is one new file.

AO_VENDORS='claude codex custom'
# Clients with relay implementations; relay_codex=off can make Codex rows
# passive in relay.sh. Other rows read their inbox.
AO_RELAY_VENDORS='claude codex custom'
# One argv string: Linux caps a single argument at 128 KiB (MAX_ARG_STRLEN),
# so prompts and relay messages stay below that with room for wrappers.
AO_ARG_MAX_BYTES=120000

# ao_codex_thread_addressable ID  Reject placeholders and unsafe CLI addresses.
# This is not a UUID-format check; native clients may use other opaque IDs.
# Relay checks before claiming notes; doorbell and vendor share the same guard.
ao_codex_thread_addressable() {
  case ${1-} in
    '' | pending | -* | *"$AO_NL"* | *"$AO_TAB"*) return 1 ;;
  esac
  return 0
}

# ao_vendor_use CLIENT  Source lib/vendor-CLIENT.sh once.
ao_vendor_use() {
  case " $AO_VENDORS " in *" $1 "*) ;; *) return 1 ;; esac
  eval "_ao_loaded=\${_AO_VENDOR_$1-}"
  [ -n "$_ao_loaded" ] && return 0
  # shellcheck source=/dev/null
  . "$AO_SCRIPTS/lib/vendor-$1.sh" || return 1
  eval "_AO_VENDOR_$1=1"
}

# ao_role_load PREFIX [CLIENT]  Read a role's keys into R_* variables.
# CLIENT fixes the client (relay transports); otherwise <prefix>_client is
# read. Returns 4 when the role is unset or `none`.
ao_role_load() {
  R_PREFIX=$1
  R_CLIENT=${2:-$(ao_cfg "$1_client" none)}
  [ "$R_CLIENT" != none ] || return "$AO_E_ROLE"
  ao_vendor_use "$R_CLIENT" || ao_die "$AO_E_USAGE" "$1_client: unknown client '$R_CLIENT' (expected: $AO_VENDORS, none)"
  _ao_dflt=$R_CLIENT
  [ "$R_CLIENT" != custom ] || _ao_dflt=
  R_CMD=$(ao_cfg "$1_cmd" "$_ao_dflt")
  [ -n "$R_CMD" ] || ao_die "$AO_E_USAGE" "$1_cmd is required for a custom client"
  case $R_CMD in
    */* | '~'*) R_CMD=$(ao_expand_path "$R_CMD" "$PWD") ;;
    *) R_CMD=$(command -v "$R_CMD") || ao_die "$AO_E_USAGE" "$1: '$R_CMD' not found on PATH ($PATH)" ;;
  esac
  [ -x "$R_CMD" ] || ao_die "$AO_E_USAGE" "$1: not executable: $R_CMD"
  R_MODEL=$(ao_cfg "$1_model" '')
  R_EFFORT=$(ao_cfg "$1_effort" '')
  _ao_timeout_default=600
  [ "$1" != relay_codex ] || _ao_timeout_default=30
  R_TIMEOUT=$(ao_cfg_uint "$1_timeout" "$_ao_timeout_default") || exit
  R_MCP=$(ao_cfg "$1_mcp_disable" '')
  R_TOOLS=$(ao_cfg "$1_tools" '')
  R_MAX_TURNS=$(ao_cfg "$1_max_turns" '')
  R_DISALLOWED=$(ao_cfg "$1_disallowed_tools" '')
  R_TOKEN_SECRET=$(ao_cfg "$1_token_secret" '')
  R_TOKEN_ENV=$(ao_cfg "$1_token_env" '')
  case $R_MODEL in *[!A-Za-z0-9._:/@-]*) ao_die "$AO_E_USAGE" "$1_model: invalid model id '$R_MODEL'" ;; esac
  case $R_EFFORT in *[!a-z]*) ao_die "$AO_E_USAGE" "$1_effort: expected a lowercase word, got '$R_EFFORT'" ;; esac
  case $R_MCP in *[!A-Za-z0-9_,-]*) ao_die "$AO_E_USAGE" "$1_mcp_disable: expected a comma list of server names" ;; esac
  case $R_TOOLS$R_DISALLOWED in *[!A-Za-z0-9_,*:\(\)-]*) ao_die "$AO_E_USAGE" "$1: tool lists must be comma lists of tool names" ;; esac
  [ -z "$R_MAX_TURNS" ] || ao_is_uint "$R_MAX_TURNS" || ao_die "$AO_E_USAGE" "$1_max_turns must be an integer"
  case $R_TOKEN_ENV in *[!A-Za-z0-9_]*) ao_die "$AO_E_USAGE" "$1_token_env: invalid variable name" ;; esac
  if [ -n "$R_TOKEN_SECRET" ] && [ -z "$R_TOKEN_ENV" ]; then
    [ "$R_CLIENT" = claude ] || ao_die "$AO_E_USAGE" "$1_token_env is required with $1_token_secret"
    R_TOKEN_ENV=CLAUDE_CODE_OAUTH_TOKEN
  fi
  return 0
}

# _ao_role_token  Stage the role's token for the next client child only
# (ao_timeout exports it inside that child). A secret that cannot be read
# falls back to the client's normal sign-in, with a warning.
_ao_role_token() {
  _AO_TOK_ENV='' _AO_TOK_VAL=''
  [ -n "$R_TOKEN_SECRET" ] || return 0
  if _AO_TOK_VAL=$(ao_secret "$R_TOKEN_SECRET") && [ -n "$_AO_TOK_VAL" ]; then
    _AO_TOK_ENV=$R_TOKEN_ENV
  else
    _AO_TOK_VAL=
    ao_warn "$R_PREFIX: secret '$R_TOKEN_SECRET' not readable; using the client's own sign-in"
  fi
}

_ao_role_token_clear() {
  _AO_TOK_ENV='' _AO_TOK_VAL=''
}

# ao_prompt_text FILE  Print a prompt file for use as one argv word. A leading
# '-' is shielded with a space so no CLI parses the prompt as an option.
ao_prompt_text() {
  _ao_pt=$(cat "$1") || return 1
  case $_ao_pt in -*) _ao_pt=" $_ao_pt" ;; esac
  printf '%s' "$_ao_pt"
}

# ao_role_run WORKDIR PROMPT OUT ERR  Run the loaded role once, in this
# shell (so signals reach it at once); the token, if any, is visible only to
# the client process.
ao_role_run() {
  [ -d "$1" ] || ao_die "$AO_E_USAGE" "working directory not found: $1"
  [ -r "$2" ] || ao_die "$AO_E_USAGE" "prompt file not readable: $2"
  [ "$(wc -c <"$2")" -le "$AO_ARG_MAX_BYTES" ] ||
    ao_die "$AO_E_USAGE" "prompt file over $AO_ARG_MAX_BYTES bytes (one-argument limit): $2"
  _ao_role_token
  "vendor_${R_CLIENT}_run" "$@"
  _ao_rr=$?
  _ao_role_token_clear
  return "$_ao_rr"
}

# ao_role_deliver NAME SESSION MESSAGE OUT ID  Deliver through the loaded role.
ao_role_deliver() {
  _ao_role_token
  "vendor_${R_CLIENT}_deliver" "$@"
  _ao_rr=$?
  _ao_role_token_clear
  return "$_ao_rr"
}

# ao_activity CLIENT DIR SESSION  Print the session's last-activity epoch,
# or nothing when unknown or unsupported (file-only, unknown clients).
ao_activity() {
  ao_vendor_use "$1" 2>/dev/null || return 0
  "vendor_$1_activity" "$2" "$3"
}

# ao_idle_state  For the current operator (OP_*), print one of:
#   idle_min=<n> | no-transcript | pending | unknown
ao_idle_state() {
  case $OP_CLIENT in claude | codex | custom) ;; *) echo unknown; return ;; esac
  if [ -z "$OP_SID" ]; then echo pending; return; fi
  _ao_last=$(ao_activity "$OP_CLIENT" "$OP_DIR" "$OP_SID")
  if [ -z "$_ao_last" ]; then
    [ "$OP_CLIENT" = custom ] && echo unknown || echo no-transcript
    return
  fi
  echo "idle_min=$(((AO_T_EPOCH - _ao_last) / 60))"
}
