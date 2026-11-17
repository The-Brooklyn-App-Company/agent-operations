# shellcheck shell=sh disable=SC2153
# (SC2153: R_* globals come from ao_role_load in vendor.sh.)
# vendor-claude.sh - Claude Code behind the vendor interface (see vendor.sh).
#
# run:      `claude -p` with no session persistence, no tool servers
#           (--strict-mcp-config without --mcp-config), and a tool
#           allow-list that defaults to read-only (Read,Grep,Glob).
# deliver:  a short headless run that calls the harness's SendMessage tool
#           once, addressed to the session's display name. Delivered is not
#           read: the target sees it on its next turn.
# activity: newest transcript in $CLAUDE_CONFIG_DIR/projects/<dir-slug>/.
#
# The prompt is passed as the first argument after -p, before any option,
# because --tools and --disallowedTools take a variable number of values.

vendor_claude_run() {
  _vc_dir=$1 _vc_out=$3 _vc_err=$4
  set -- "$R_CMD" -p "$(ao_prompt_text "$2")" --no-session-persistence --strict-mcp-config
  [ -z "$R_MODEL" ] || set -- "$@" --model "$R_MODEL"
  [ -z "$R_MAX_TURNS" ] || set -- "$@" --max-turns "$R_MAX_TURNS"
  [ "$R_TOOLS" = default ] || set -- "$@" --tools "$R_TOOLS"
  (cd "$_vc_dir" && ao_timeout "$R_TIMEOUT" "$@" </dev/null >"$_vc_out" 2>"$_vc_err")
}

vendor_claude_deliver() {
  _vc_name=$1 _vc_msg=$3 _vc_out=$4
  case $_vc_name in *'"'*) echo "session name contains a double quote" >"$_vc_out"; return 1 ;; esac
  _vc_prompt="Use the SendMessage tool exactly once, to \"$_vc_name\" (the session with that exact name in ListAgents), with this exact message text (do not add commentary, do not change it):

$(cat "$_vc_msg")

After sending, print SENT. If SendMessage fails, print FAILED and the error."
  set -- "$R_CMD" -p "$_vc_prompt"
  [ -z "$R_MODEL" ] || set -- "$@" --model "$R_MODEL"
  [ -z "$R_MAX_TURNS" ] || set -- "$@" --max-turns "$R_MAX_TURNS"
  [ -z "$R_DISALLOWED" ] || set -- "$@" --disallowedTools "$R_DISALLOWED"
  _vc_wd=$(ao_cfg relay_workdir "$AO_HOME")
  (cd "$(ao_expand_path "$_vc_wd")" && ao_timeout "$R_TIMEOUT" "$@" </dev/null >"$_vc_out" 2>&1) || return 1
  grep -q '^[[:space:]]*FAILED' "$_vc_out" && return 1
  grep -Eq '^[[:space:]]*SENT[.!]?[[:space:]]*$' "$_vc_out"
}

vendor_claude_activity() {
  _vc_slug=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  # Transcript names are UUIDs, so parsing ls is safe here.
  # shellcheck disable=SC2012
  _vc_new=$(ls -t "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$_vc_slug"/*.jsonl 2>/dev/null | head -n 1)
  [ -z "$_vc_new" ] || ao_mtime "$_vc_new"
}
