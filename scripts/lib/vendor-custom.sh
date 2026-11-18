# shellcheck shell=sh disable=SC2153
# (SC2153: R_* globals come from ao_role_load in vendor.sh.)
# vendor-custom.sh - any CLI behind the vendor interface (see vendor.sh).
#
# The role's <prefix>_cmd is an executable with this contract, always run
# with stdin from /dev/null and AO_ROLE, AO_MODEL, AO_EFFORT in its env:
#   <cmd> run <workdir> <prompt-file> <out-file>
#       write the final answer to <out-file>; diagnostics to stderr
#   <cmd> deliver <name> <session|-> <message-file> <relay-id>
#       exit 0 only once the message reached the session
#   <cmd> activity <dir> <session|->
#       print the last-activity epoch, or nothing; optional (exit 1 = unknown)
# The kit guarantees the timeout; the command guarantees read-only behaviour
# for `run`.

# Runs in the caller's shell (signals reach it at once); AO_ROLE, AO_MODEL
# and AO_EFFORT are not secret, so they are simply exported.
_vendor_custom() {
  AO_ROLE=$R_PREFIX AO_MODEL=$R_MODEL AO_EFFORT=$R_EFFORT
  export AO_ROLE AO_MODEL AO_EFFORT
  ao_timeout "$R_TIMEOUT" "$R_CMD" "$@" </dev/null
}

vendor_custom_run() {
  _vendor_custom run "$1" "$2" "$3" >"$4" 2>&1
}

vendor_custom_deliver() {
  _vendor_custom deliver "$1" "${2:--}" "$3" "$5" >"$4" 2>&1
}

# Resolved like the relay role (a name on PATH, or a path).
vendor_custom_activity() {
  _vu_cmd=$(ao_cfg relay_custom_cmd '')
  [ -n "$_vu_cmd" ] || return 0
  case $_vu_cmd in
    */* | '~'*) _vu_cmd=$(ao_expand_path "$_vu_cmd" "$PWD") ;;
    *) _vu_cmd=$(command -v "$_vu_cmd") || return 0 ;;
  esac
  [ -x "$_vu_cmd" ] || return 0
  _vu_t=$(ao_timeout 30 "$_vu_cmd" activity "$1" "${2:--}" </dev/null 2>/dev/null) || return 0
  ao_is_uint "$_vu_t" && printf '%s\n' "$_vu_t"
}
