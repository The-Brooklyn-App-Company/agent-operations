# shellcheck shell=sh disable=SC2153,SC2034
# (SC2153: R_* globals come from ao_role_load in vendor.sh; SC2034:
# AO_RUN_DIR is read by ao_timeout in core.sh.)
# vendor-codex.sh - Codex CLI behind the vendor interface (see vendor.sh).
#
# run:      `codex exec --ephemeral -s read-only`, final message via -o. The
#           read-only sandbox does not cover tool (MCP) servers, plugins or
#           apps, so plugins and apps are switched off (`--disable plugins
#           --disable apps`; a plugin's own servers cannot be switched off by
#           name), and every server the remaining configuration lists
#           (`codex mcp list --json`) is switched off, plus any named in
#           <role>_mcp_disable. If the list cannot be read (no jq, an error,
#           an unexpected name) the run fails closed. Verified with
#           codex-cli 0.169 on 2026-11-17; the plugin and app switches with
#           0.169.0-alpha.11.
# deliver:  `codex queue --thread SESSION --message POINTER --resume`.
#           One live isolated existing-account/machine round trip observed on
#           macOS, 2026-11-18, codex-cli 0.169.0-alpha.11.1: a later app turn
#           read the archived fixture and acknowledged its exact relay ID.
#           The configured exit-0 assumption means queue submission only;
#           that run also warned resume failed. Resume is not guaranteed.
#           Not a clean account/machine test. Both experimental lease-mail
#           doorbells remain fakes only; live unrun.
# activity: newest $CODEX_HOME/sessions/**/*<session>*.jsonl.

# Global switches for every Codex run: no plugins, no apps (connectors).
_VX_OFF='--disable plugins --disable apps'

# _vendor_codex_mcp_args WORKDIR  Print `-c mcp_servers.<name>.enabled=false` words
# for every configured server and every server in <role>_mcp_disable, or
# fail with the reason on stderr.
_vendor_codex_mcp_args() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required to list Codex tool servers" >&2; return 1; }
  # Listed from the run's own directory, so project configuration counts.
  AO_RUN_DIR=$1
  # shellcheck disable=SC2086 # fixed words
  _vx_list=$(ao_timeout 60 "$R_CMD" $_VX_OFF mcp list --json 2>/dev/null)
  _vx_rc=$?
  AO_RUN_DIR=
  [ "$_vx_rc" -eq 0 ] || {
    echo "cannot list Codex tool servers ($R_CMD mcp list --json)" >&2
    return 1
  }
  _vx_names=
  if printf '%s\n' "$_vx_list" | jq -e 'type == "array"' >/dev/null 2>&1; then
    _vx_names=$(printf '%s\n' "$_vx_list" | jq -r '.[] | .name // empty' 2>/dev/null)
  else
    echo "unreadable Codex tool-server list (expected a JSON array)" >&2
    return 1
  fi
  # One name per line; a name with any other character fails the run.
  printf '%s\n%s\n' "$_vx_names" "$R_MCP" | tr ',' '\n' | while IFS= read -r _vx_n; do
    [ -n "$_vx_n" ] || continue
    case $_vx_n in *[!A-Za-z0-9_-]*)
      echo "unexpected Codex tool-server name '$_vx_n'; not running" >&2
      exit 1 ;;
    esac
    printf -- '-c mcp_servers.%s.enabled=false\n' "$_vx_n"
  done
}

vendor_codex_run() {
  _vx_dir=$1 _vx_out=$3 _vx_err=$4 _vx_prompt=$2
  _vx_off=$(_vendor_codex_mcp_args "$_vx_dir" 2>"$_vx_err") || return "$AO_E_USAGE"
  # shellcheck disable=SC2086 # fixed words
  set -- "$R_CMD" $_VX_OFF exec --ephemeral --skip-git-repo-check -s read-only -C "$_vx_dir" -o "$_vx_out"
  [ -z "$R_MODEL" ] || set -- "$@" -m "$R_MODEL"
  [ -z "$R_EFFORT" ] || set -- "$@" -c "model_reasoning_effort=\"$R_EFFORT\""
  # Names are validated to [A-Za-z0-9_-] above, so splitting is safe.
  # shellcheck disable=SC2086
  set -- "$@" $_vx_off "$(ao_prompt_text "$_vx_prompt")"
  ao_timeout "$R_TIMEOUT" "$@" >/dev/null 2>"$_vx_err"
}

vendor_codex_deliver() {
  _vx_thread=$2 _vx_out=$4
  ao_codex_thread_addressable "$_vx_thread" || {
    echo "no addressable Codex thread" >"$_vx_out"; return 1
  }
  if ! [ "$R_TIMEOUT" -gt 0 ]; then
    echo "relay_codex_timeout must be positive" >"$_vx_out"
    return 1
  fi
  _vx_pointer=$(ao_prompt_text "$3") && [ -n "$_vx_pointer" ] &&
    [ "$(wc -c <"$3")" -le "$AO_ARG_MAX_BYTES" ] || {
    echo "invalid Codex pointer message" >"$_vx_out"
    return 1
  }
  ao_timeout "$R_TIMEOUT" "$R_CMD" queue --thread "$_vx_thread" --message "$_vx_pointer" --resume \
    >/dev/null 2>"$_vx_out.err"
  _vx_rc=$?
  if [ "$_vx_rc" -eq 0 ]; then
    # Preserve queue/resume diagnostics separately from the acceptance stage.
    tail -c 300 "$_vx_out.err" | tr '\n' ' ' >"$_vx_out"
    return 0
  fi
  printf 'queue acceptance unconfirmed (Codex exit %s)\n' "$_vx_rc" >"$_vx_out"
  tail -c 240 "$_vx_out.err" | tr '\n' ' ' >>"$_vx_out"
  return 1
}

vendor_codex_activity() {
  ao_is_name "$2" || return 0
  _vx_root=${CODEX_HOME:-$HOME/.codex}/sessions
  [ -d "$_vx_root" ] || return 0
  find "$_vx_root" -type f -name "*$2*.jsonl" 2>/dev/null |
    while IFS= read -r _vx_f; do ao_mtime "$_vx_f"; done | sort -n | tail -n 1
}
