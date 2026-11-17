# shellcheck shell=sh disable=SC2153
# (SC2153: R_* globals come from ao_role_load in vendor.sh.)
# vendor-claude.sh - Claude Code behind the vendor interface (see vendor.sh).
#
# Every invocation is headless (`claude -p`), loads no tool servers
# (--strict-mcp-config without --mcp-config) and runs no hooks
# (disableAllHooks), so user or project customisation cannot act on the
# machine before or around the run.
#
# run:      no session persistence; tool allow-list defaulting to read-only
#           (Read,Grep,Glob).
# deliver:  a short run whose only job is one call of the harness's built-in
#           SendMessage tool, addressed to the session's display name. The
#           message is untrusted text in front of a model, so the run gets a
#           deny-list of effectful built-in tools (relay_claude_disallowed_tools,
#           `none` to drop it) and success is never taken from the model's
#           words: the event stream must show exactly one SendMessage call, to
#           this recipient, carrying this delivery's relay id, and a
#           successful tool result. Delivered is not read.
# activity: the registered session's transcript
#           ($CLAUDE_CONFIG_DIR/projects/<dir-slug>/<session>.jsonl) when the
#           registry holds a CLI session id; otherwise, e.g. for desktop-app
#           ids, the newest transcript in that project directory.
#
# The prompt is passed as the first argument after -p, before any option,
# because --tools and --disallowedTools take a variable number of values.

_VC_SETTINGS='{"disableAllHooks":true}'
_VC_RELAY_DENY='Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task,Skill'

vendor_claude_run() {
  _vc_dir=$1 _vc_out=$3 _vc_err=$4
  set -- "$R_CMD" -p "$(ao_prompt_text "$2")" --no-session-persistence \
    --strict-mcp-config --settings "$_VC_SETTINGS"
  [ -z "$R_MODEL" ] || set -- "$@" --model "$R_MODEL"
  [ -z "$R_MAX_TURNS" ] || set -- "$@" --max-turns "$R_MAX_TURNS"
  [ "$R_TOOLS" = default ] || set -- "$@" --tools "$R_TOOLS"
  (cd "$_vc_dir" && ao_timeout "$R_TIMEOUT" "$@" </dev/null >"$_vc_out" 2>"$_vc_err")
}

vendor_claude_deliver() {
  _vc_name=$1 _vc_msg=$3 _vc_out=$4 _vc_id=$5
  case $_vc_name in *'"'* | *\\*)
    echo "session name contains a quote or backslash" >"$_vc_out"
    return 1 ;;
  esac
  _vc_prompt="Use the SendMessage tool exactly once, to \"$_vc_name\" (the session with that exact name in ListAgents), with this exact message text (do not add commentary, do not change it, keep the relay id line):

$(cat "$_vc_msg")

After sending, print SENT. If SendMessage fails, print FAILED and the error."
  _vc_deny=${R_DISALLOWED:-$_VC_RELAY_DENY}
  set -- "$R_CMD" -p "$_vc_prompt" --output-format stream-json --verbose \
    --strict-mcp-config --settings "$_VC_SETTINGS"
  [ -z "$R_MODEL" ] || set -- "$@" --model "$R_MODEL"
  [ -z "$R_MAX_TURNS" ] || set -- "$@" --max-turns "$R_MAX_TURNS"
  [ "$_vc_deny" = none ] || set -- "$@" --disallowedTools "$_vc_deny"
  _vc_wd=$(ao_cfg_path relay_workdir "$AO_HOME")
  (cd "$_vc_wd" && ao_timeout "$R_TIMEOUT" "$@" </dev/null >"$_vc_out" 2>&1) || return 1
  _vendor_claude_receipt "$_vc_out" "$_vc_name" "$_vc_id"
}

# _vendor_claude_receipt STREAM NAME ID  True only if the stream-json events
# show exactly one SendMessage call, addressed to NAME, whose input carries
# ID, and a tool result reporting success. A mismatch is explained at the
# end of STREAM, which the relay logs.
_vendor_claude_receipt() {
  _vc_calls=$(grep -E '"name": *"SendMessage"' "$1" | grep -c '"tool_use"')
  if [ "$_vc_calls" -ne 1 ]; then
    echo "receipt: expected one SendMessage call, saw $_vc_calls" >>"$1"
    return 1
  fi
  _vc_call=$(grep -E '"name": *"SendMessage"' "$1" | grep '"tool_use"')
  case $_vc_call in *"\"to\":\"$2\""*"$3"* | *"$3"*"\"to\":\"$2\""*) ;; *)
    echo "receipt: the SendMessage call was not to \"$2\" with relay id $3" >>"$1"
    return 1 ;;
  esac
  _vc_use=$(printf '%s\n' "$_vc_call" | grep -o '"id": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
  if [ -z "$_vc_use" ] || ! grep '"tool_result"' "$1" | grep -F "$_vc_use" | grep -Eq 'success[\\"]*: *true'; then
    echo "receipt: no successful result for the SendMessage call" >>"$1"
    return 1
  fi
}

vendor_claude_activity() {
  _vc_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  if [ -n "$2" ] && ao_is_name "$2" && [ -f "$_vc_dir/$2.jsonl" ]; then
    ao_mtime "$_vc_dir/$2.jsonl"
    return
  fi
  # Transcript names are UUIDs, so parsing ls is safe here.
  # shellcheck disable=SC2012
  _vc_new=$(ls -t "$_vc_dir"/*.jsonl 2>/dev/null | head -n 1)
  [ -z "$_vc_new" ] || ao_mtime "$_vc_new"
}
