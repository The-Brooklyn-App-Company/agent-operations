# Profile: both. Claude Code and Codex, so review is cross-family.
# Copy it outside git (default: ~/.config/agent-operations/profile) and edit.
# Format and every key, with defaults: scripts/README.md#profile.
# Values are literal: no quotes needed, no variables; only a leading ~/ expands.
# Replace every CHANGE-ME: an unset model would silently use the client's
# default, so the examples fail loudly instead.

oracle_home=~/oracle-home
oracle_key=oracle
path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Relay: Claude sessions get a SendMessage; a registry row can say
# `file-only` (or experimental `codex`) in its client column instead.
relay_default=claude
relay_claude_model=haiku
relay_claude_max_turns=4
relay_claude_timeout=300
relay_claude_disallowed_tools=Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch
# relay_claude_token_secret=claude-oauth-token

# Cheap worker on Codex: read-only sandbox, ephemeral, effectful servers off.
worker_client=codex
worker_model=CHANGE-ME-small-model
worker_timeout=600
worker_mcp_disable=CHANGE-ME-server-a,CHANGE-ME-server-b

# Reviewer from the other family than the implementer (here: Codex reviews
# Claude's work). Swap the clients if Codex implements.
reviewer_client=codex
reviewer_model=CHANGE-ME-strong-model
reviewer_effort=high
reviewer_timeout=2400
reviewer_mcp_disable=CHANGE-ME-server-a,CHANGE-ME-server-b
review_family=cross

secrets=os
