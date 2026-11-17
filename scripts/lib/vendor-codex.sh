# shellcheck shell=sh disable=SC2153
# (SC2153: R_* globals come from ao_role_load in vendor.sh.)
# vendor-codex.sh - Codex CLI behind the vendor interface (see vendor.sh).
#
# run:      `codex exec --ephemeral -s read-only`, each server in
#           <role>_mcp_disable switched off, final message via -o.
# deliver:  EXPERIMENTAL, unverified. `codex exec resume <session>` runs one
#           read-only turn in the target session carrying the message, with
#           the same tool servers switched off as for runs. Unlike
#           Claude's SendMessage this is an agent turn, not a notification.
#           Prefer `file-only` for Codex sessions until this is proven.
# activity: newest $CODEX_HOME/sessions/**/*<session>*.jsonl.

_vendor_codex_mcp_off() {
  _vx_args="$_vx_args mcp_servers.$1.enabled=false"
}

# _vendor_codex_mcp_args  Print `-c mcp_servers.<name>.enabled=false` words
# for every server in <role>_mcp_disable (names are [A-Za-z0-9_-] only).
_vendor_codex_mcp_args() {
  _vx_args=
  ao_mcp_each _vendor_codex_mcp_off
  for _vx_a in $_vx_args; do printf -- '-c %s ' "$_vx_a"; done
}

vendor_codex_run() {
  _vx_dir=$1 _vx_out=$3 _vx_err=$4 _vx_prompt=$2
  set -- "$R_CMD" exec --ephemeral --skip-git-repo-check -s read-only -C "$_vx_dir" -o "$_vx_out"
  [ -z "$R_MODEL" ] || set -- "$@" -m "$R_MODEL"
  [ -z "$R_EFFORT" ] || set -- "$@" -c "model_reasoning_effort=\"$R_EFFORT\""
  # Server names are validated to [A-Za-z0-9_-], so splitting is safe.
  # shellcheck disable=SC2046
  set -- "$@" $(_vendor_codex_mcp_args) "$(ao_prompt_text "$_vx_prompt")"
  ao_timeout "$R_TIMEOUT" "$@" </dev/null >/dev/null 2>"$_vx_err"
}

vendor_codex_deliver() {
  _vx_sid=$2 _vx_msg=$3 _vx_out=$4
  if [ -z "$_vx_sid" ]; then
    echo "codex delivery needs a session id in the registry" >"$_vx_out"
    return 1
  fi
  set -- "$R_CMD" exec resume --skip-git-repo-check -c 'sandbox_mode="read-only"'
  [ -z "$R_MODEL" ] || set -- "$@" -m "$R_MODEL"
  # shellcheck disable=SC2046 # validated server names, see above
  set -- "$@" $(_vendor_codex_mcp_args) "$_vx_sid" "$(ao_prompt_text "$_vx_msg")"
  _vx_wd=$(ao_cfg_path relay_workdir "$AO_HOME")
  (cd "$_vx_wd" && ao_timeout "$R_TIMEOUT" "$@" </dev/null >"$_vx_out" 2>&1)
}

vendor_codex_activity() {
  ao_is_name "$2" || return 0
  _vx_root=${CODEX_HOME:-$HOME/.codex}/sessions
  [ -d "$_vx_root" ] || return 0
  find "$_vx_root" -type f -name "*$2*.jsonl" 2>/dev/null |
    while IFS= read -r _vx_f; do ao_mtime "$_vx_f"; done | sort -n | tail -n 1
}
