# shellcheck shell=sh disable=SC2153,SC2034
# (SC2153: R_* globals come from ao_role_load in vendor.sh; SC2034:
# AO_RUN_DIR is read by ao_timeout in core.sh.)
# vendor-claude.sh - Claude Code behind the vendor interface (see vendor.sh).
#
# Every invocation is headless (`claude -p`) and --restricted (user,
# project and local settings ignored; code-running tools and WebFetch
# removed; file tools confined to the working directory), loads no tool
# servers (--strict-mcp-config without --mcp-config) and runs no hooks
# (disableAllHooks). Verified with Claude Code 2.1.322 on 2026-11-17.
#
# run:      no session persistence; built-in tools limited to <role>_tools,
#           which must be a subset of the read-only set Read,Grep,Glob
#           (anything else, `default` included, is refused).
# deliver:  a short run whose only job is one call of the built-in
#           SendMessage tool, addressed to the session's display name. The
#           message is the relay's fixed-shape pointer (never note text), the
#           run may use only <role>_tools (default ListAgents,SendMessage),
#           and success is never taken from the model's words: the JSON event
#           stream must show exactly one SendMessage call, addressed to this
#           name, and a successful, non-error result for that call. The
#           stream is checked even when the client exits non-zero or times
#           out, so a send that landed is never repeated. If the text differs,
#           or the run made other SendMessage calls as well, the delivery
#           still counts, with a warning.
#           Verifying needs jq; without it delivery fails closed. Delivered
#           is not read. AO_KEEP_STREAM=<file> keeps a copy of the event
#           stream, for diagnosis.
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
_VC_RELAY_TOOLS='ListAgents,SendMessage'
_VC_UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

vendor_claude_run() {
  _vc_dir=$1 _vc_out=$3 _vc_err=$4
  _vc_tools=${R_TOOLS:-$_VC_RUN_TOOLS}
  for _vc_t in $(printf '%s' "$_vc_tools" | tr ',' ' '); do
    case ",$_VC_RUN_TOOLS," in *",$_vc_t,"*) ;; *)
      echo "$R_PREFIX: tool '$_vc_t' is not read-only; runs may use only $_VC_RUN_TOOLS" >"$_vc_err"
      return "$AO_E_USAGE" ;;
    esac
  done
  set -- "$R_CMD" -p "$(ao_prompt_text "$2")" --no-session-persistence \
    --restricted --strict-mcp-config --settings "$_VC_SETTINGS"
  [ -z "$R_MODEL" ] || set -- "$@" --model "$R_MODEL"
  [ -z "$R_MAX_TURNS" ] || set -- "$@" --max-turns "$R_MAX_TURNS"
  set -- "$@" --tools "$_vc_tools"
  [ -z "$R_DISALLOWED" ] || set -- "$@" --disallowedTools "$R_DISALLOWED"
  AO_RUN_DIR=$_vc_dir
  ao_timeout "$R_TIMEOUT" "$@" >"$_vc_out" 2>"$_vc_err"
  _vc_rc=$?
  AO_RUN_DIR=
  return "$_vc_rc"
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
    --restricted --strict-mcp-config --settings "$_VC_SETTINGS"
  [ -z "$R_MODEL" ] || set -- "$@" --model "$R_MODEL"
  [ -z "$R_MAX_TURNS" ] || set -- "$@" --max-turns "$R_MAX_TURNS"
  _vc_tools=${R_TOOLS:-$_VC_RELAY_TOOLS}
  [ "$_vc_tools" = default ] || set -- "$@" --tools "$_vc_tools"
  [ -z "$R_DISALLOWED" ] || set -- "$@" --disallowedTools "$R_DISALLOWED"
  AO_RUN_DIR=$(ao_cfg_path relay_workdir "$AO_HOME")
  ao_timeout "$R_TIMEOUT" "$@" >"$_vc_out" 2>"$_vc_out.err"
  _vc_rc=$?
  AO_RUN_DIR=
  [ -z "${AO_KEEP_STREAM:-}" ] || cp "$_vc_out" "$AO_KEEP_STREAM" 2>/dev/null
  _vc_verdict=$(_vendor_claude_receipt "$_vc_out" "$_vc_name" "$_vc_msg")
  case $_vc_verdict in
    ok) return 0 ;;
    altered)
      _vc_tail=$(cat "$_vc_out")
      printf 'warning: delivered, but the run changed the text or made other SendMessage calls (client exit %s)\n%s\n' "$_vc_rc" "$_vc_tail" >"$_vc_out"
      return 0 ;;
  esac
  echo "receipt: ${_vc_verdict:-unreadable event stream} (client exit $_vc_rc)" >>"$_vc_out"
  [ "$_vc_rc" -eq 0 ] || tail -n 5 "$_vc_out.err" >>"$_vc_out"
  return 1
}

# _vendor_claude_receipt STREAM NAME MESSAGE_FILE  Print `ok` if the event
# stream proves exactly one successful SendMessage to NAME with the message
# text; `altered` if it proves a successful send to NAME but the text
# differs or other SendMessage calls were made too (delivered, with a
# warning: never re-sent); else the reason nothing was delivered. Lines
# that are not JSON are ignored; every tool_use block in every assistant
# event is counted. The tool result's text is JSON with "success": true in
# Claude Code 2.1.322 (see tests/fixtures/).
_vendor_claude_receipt() {
  jq -nrR --arg to "$2" --rawfile msg "$3" '
    def norm: sub("^\\s+"; "") | sub("\\s+$"; "");
    def text: if type == "string" then .
      elif type == "array" then map(.text? // "") | join("")
      else tostring end;
    [inputs | fromjson? | objects] as $ev
    | [$ev[] | select(.type == "assistant") | .message.content[]?
        | select(.type? == "tool_use" and .name == "SendMessage")] as $sends
    | [$ev[] | select(.type == "user") | .message.content[]?
        | select(.type? == "tool_result")] as $results
    | def result($s): [$results[] | select(.tool_use_id == $s.id)] | first;
      def verdict($s): result($s) as $r
        | if $r == null then "no result for the SendMessage call"
          elif $r.is_error == true then "SendMessage returned an error"
          elif ($r.content | text | (fromjson? // {}) | .success?) != true then "SendMessage did not report success"
          else "sent" end;
    [$sends[] | select((.input.to // "") == $to)] as $mine
    | [$mine[] | select(verdict(.) == "sent")] as $landed
    | if ($sends | length) == 0 then "no SendMessage call"
      elif ($mine | length) == 0 then "SendMessage was addressed to \($sends[0].input.to // "nobody"), not \($to)"
      elif ($landed | length) == 0 then verdict($mine[0])
      elif ($sends | length) == 1 and ([$landed[0].input.message, $landed[0].input.content]
              | map(select(type == "string") | norm) | any(. == ($msg | norm))) then "ok"
      else "altered" end' <"$1" 2>/dev/null
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
