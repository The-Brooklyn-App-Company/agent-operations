# Profile: both. Claude Code and Codex, so review is cross-family.
# Copy it outside git (default: ~/.config/agent-operations/profile) and edit;
# install.sh oracle does this for you. Every key and its default:
# scripts/README.md#profile. Values are literal: no quotes needed, no
# variables; only a leading ~/ expands. Replace every CHANGE-ME: an unset
# model would silently use the client's default, so the examples fail
# loudly instead.

oracle_home=~/ops/oracle
oracle_key=oracle
work_root=~/src
path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Relay: Claude sessions get a pointer through SendMessage; a registry row
# can say file-only instead. Codex rows queue pointers by default when the
# owner has a real thread ID; set relay_codex=off to keep those rows passive.
# One isolated live round trip observed; see README.md for versions and limits.
# No guaranteed resume. doorbell_codex is a separate, default-off opt-in,
# fakes only; live unrun.
relay_default=claude
relay_codex=queue
relay_claude_model=CHANGE-ME-small-claude-model
relay_claude_max_turns=4
relay_claude_timeout=300
# relay_claude_token_secret=CHANGE-ME-secret-name

# Cheap worker on Codex: read-only sandbox, ephemeral, every tool server off.
worker_client=codex
worker_model=CHANGE-ME-small-codex-model
worker_timeout=600

# Release and delegation reviewer: the family that did not implement.
reviewer_client=codex
reviewer_model=CHANGE-ME-strong-codex-model
reviewer_effort=high
reviewer_timeout=2400
review_family=cross

# Per-seat preferences (K-22). Claude operators are reviewed by
# reviewer_codex, Codex operators by reviewer_claude; implementer_* are read
# by agents when they delegate.
implementer_claude_model=CHANGE-ME-strong-claude-model
implementer_codex_model=CHANGE-ME-strong-codex-model
reviewer_claude_model=CHANGE-ME-strong-claude-model
reviewer_claude_timeout=900
reviewer_codex_model=CHANGE-ME-strong-codex-model
reviewer_codex_effort=high
reviewer_codex_timeout=900
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
