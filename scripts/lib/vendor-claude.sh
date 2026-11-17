# shellcheck shell=sh disable=SC2153
# (SC2153: R_* globals come from ao_role_load in vendor.sh.)
# vendor-claude.sh - Claude Code behind the vendor interface (see vendor.sh).
#
# Every invocation is headless (`claude -p`), loads no tool servers
# (--strict-mcp-config without --mcp-config) and runs no hooks
# (disableAllHooks), so user or project customisation cannot act on the
# machine before or around the run.
#
# run:      no session persistence; built-in tools limited to <role>_tools,
#           default read-only (Read,Grep,Glob).
# deliver:  a short run whose only job is one call of the built-in
#           SendMessage tool (Claude Code 2.1.224+), addressed to the
#           session's display name. The message is untrusted text in front of
#           a model, so the run may use only <role>_tools, default
#           ToolSearch,ListAgents,SendMessage, and success is never taken from
#           the model's words: the JSON event stream must show exactly one
#           SendMessage call, addressed to this name, whose text is this batch
#           (exact, ignoring only leading and trailing blank space), and a
#           successful, non-error result for
#           that call. Verifying needs jq; without it delivery fails closed.
#           Delivered is not read.
# activity: the registered session's transcript
#           ($CLAUDE_CONFIG_DIR/projects/<dir-slug>/<session>.jsonl). A
#           registered CLI session id (a UUID) must match exactly; other ids,
#           such as desktop-app ones, fall back to the newest transcript in
#           that project directory.
#
# The prompt is passed as the first argument after -p, before any option,
# because --tools and --disallowedTools take a variable number of values.

_VC_SETTINGS='{"disableAllHooks":true}'
_VC_RUN_TOOLS='Read,Grep,Glob'
_VC_RELAY_TOOLS='ToolSearch,ListAgents,SendMessage'
_VC_UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

vendor_claude_run() {
  _vc_dir=$1 _vc_out=$3 _vc_err=$4
  set -- "$R_CMD" -p "$(ao_prompt_text "$2")" --no-session-persistence \
    --strict-mcp-config --settings "$_VC_SETTINGS"
  [ -z "$R_MODEL" ] || set -- "$@" --model "$R_MODEL"
  [ -z "$R_MAX_TURNS" ] || set -- "$@" --max-turns "$R_MAX_TURNS"
  _vc_tools=${R_TOOLS:-$_VC_RUN_TOOLS}
  [ "$_vc_tools" = default ] || set -- "$@" --tools "$_vc_tools"
  [ -z "$R_DISALLOWED" ] || set -- "$@" --disallowedTools "$R_DISALLOWED"
  (cd "$_vc_dir" && ao_timeout "$R_TIMEOUT" "$@" >"$_vc_out" 2>"$_vc_err")
}

vendor_claude_deliver() {
  _vc_name=$1 _vc_msg=$3 _vc_out=$4
  case $_vc_name in *'"'* | *\\*)
    echo "session name contains a quote or backslash" >"$_vc_out"
    return 1 ;;
  esac
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to verify Claude deliveries; not delivering" >"$_vc_out"
    return 1
  fi
  _vc_prompt="Use the SendMessage tool exactly once, to \"$_vc_name\" (the session with that exact name in ListAgents), with this exact message text (do not add commentary, do not change it):

$(cat "$_vc_msg")

After sending, print SENT. If SendMessage fails, print FAILED and the error."
  set -- "$R_CMD" -p "$_vc_prompt" --output-format stream-json --verbose \
    --strict-mcp-config --settings "$_VC_SETTINGS"
  [ -z "$R_MODEL" ] || set -- "$@" --model "$R_MODEL"
  [ -z "$R_MAX_TURNS" ] || set -- "$@" --max-turns "$R_MAX_TURNS"
  _vc_tools=${R_TOOLS:-$_VC_RELAY_TOOLS}
  [ "$_vc_tools" = default ] || set -- "$@" --tools "$_vc_tools"
  [ -z "$R_DISALLOWED" ] || set -- "$@" --disallowedTools "$R_DISALLOWED"
  _vc_wd=$(ao_cfg_path relay_workdir "$AO_HOME")
  if ! (cd "$_vc_wd" && ao_timeout "$R_TIMEOUT" "$@" >"$_vc_out" 2>"$_vc_out.err"); then
    tail -n 5 "$_vc_out.err" >>"$_vc_out"
    return 1
  fi
  _vc_verdict=$(_vendor_claude_receipt "$_vc_out" "$_vc_name" "$_vc_msg")
  [ "$_vc_verdict" = ok ] && return 0
  echo "receipt: ${_vc_verdict:-unreadable event stream}" >>"$_vc_out"
  return 1
}

# _vendor_claude_receipt STREAM NAME MESSAGE_FILE  Print `ok` if the event
# stream proves the delivery, else the reason. Lines that are not JSON are
# ignored; every tool_use block in every assistant event is counted.
_vendor_claude_receipt() {
  jq -nrR --arg to "$2" --rawfile msg "$3" '
    def norm: sub("^\\s+"; "") | sub("\\s+$"; "");
    def text: if type == "string" then .
      elif type == "array" then map(.text? // "") | join("")
      else tostring end;
    [inputs | fromjson? | objects] as $ev
    | [$ev[] | select(.type == "assistant") | .message.content[]?
        | select(.type? == "tool_use" and .name == "SendMessage")] as $sends
    | if ($sends | length) != 1 then "expected one SendMessage call, saw \($sends | length)"
      else $sends[0] as $s
      | if ($s.input.to // "") != $to then "SendMessage was addressed to \($s.input.to // "nobody"), not \($to)"
        elif ([$s.input.message, $s.input.content] | map(select(type == "string") | norm)
              | any(. == ($msg | norm))) | not then "SendMessage text differs from the batch"
        else ([$ev[] | select(.type == "user") | .message.content[]?
                | select(.type? == "tool_result" and .tool_use_id == $s.id)] | first) as $r
        | if $r == null then "no result for the SendMessage call"
          elif $r.is_error == true then "SendMessage returned an error"
          elif ($r.content | text | (fromjson? // {}) | .success?) != true then "SendMessage did not report success"
          else "ok" end
        end
      end' <"$1" 2>/dev/null
}

vendor_claude_activity() {
  _vc_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  if [ -n "$2" ] && ao_is_name "$2" && [ -f "$_vc_dir/$2.jsonl" ]; then
    ao_mtime "$_vc_dir/$2.jsonl"
    return
  fi
  # A registered CLI session with no transcript is reported as such, never
  # masked by another session in the same project.
  if printf '%s\n' "$2" | grep -Eqx "$_VC_UUID"; then
    return 0
  fi
  # Transcript names are UUIDs, so parsing ls is safe here.
  # shellcheck disable=SC2012
  _vc_new=$(ls -t "$_vc_dir"/*.jsonl 2>/dev/null | head -n 1)
  [ -z "$_vc_new" ] || ao_mtime "$_vc_new"
}
