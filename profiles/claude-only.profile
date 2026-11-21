# Profile: claude-only. Claude Code runs every role.
# Copy it outside git (default: ~/.config/agent-operations/profile) and edit;
# install.sh oracle does this for you. Every key and its default:
# scripts/README.md#profile. Values are literal; only a leading ~/ expands.
# Replace every CHANGE-ME.

oracle_home=~/ops/oracle
oracle_key=oracle
work_root=~/src
path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Relay: a small model calls the client's SendMessage tool with a pointer.
relay_default=claude
relay_claude_model=CHANGE-ME-small-claude-model
relay_claude_max_turns=4
relay_claude_timeout=300
# relay_claude_token_secret=CHANGE-ME-secret-name

# Cheap worker: read-only tools, no tool servers, restricted mode.
worker_client=claude
worker_model=CHANGE-ME-small-claude-model
worker_timeout=600

# Reviewer: a different model of the same family, fresh context, neutral
# packet. Same-family review is labelled; risky changes also get a human
# read (K-21).
reviewer_client=claude
reviewer_model=CHANGE-ME-strong-claude-model
reviewer_timeout=2400
review_family=same-family

# Weekly cross-review (K-22) falls back to the same family, with a
# different model than the implementer; status.sh warns.
implementer_claude_model=CHANGE-ME-strong-claude-model
reviewer_claude_model=CHANGE-ME-other-claude-model
reviewer_claude_timeout=900
cross_review=on

# Mailroom (experimental, docs/mailroom.md): the relay writes rings for the
# in-app bridges (install.sh bridge claude|codex); the supervisor falls back
# to the relay transports above. off = deliver through the transports.
relay_bridge=on
# Claude tier 1 (opt-in): the bridge's watcher delivers to warm sessions
# with no model turn, through the client's undocumented local socket.
# bridge_claude_t1=socket
# The desktop app's link to a session, {session} where the id goes, for the
# supervisor's deep-link warm-up after an app restart (none shipped).
# wake_link=CHANGE-ME-app-session-link-with-{session}
# bridge_codex_node=CHANGE-ME-node-bundled-in-the-desktop-app
# bridge_codex_server=CHANGE-ME-codex-app-tools-server.mjs-in-the-desktop-app
# host_apps=com.anthropic.claudefordesktop com.openai.codex

secrets=os
