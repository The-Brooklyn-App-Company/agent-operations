# Profile: claude-only. Claude Code runs every role.
# Copy it outside git (default: ~/.config/agent-operations/profile) and edit.
# Format and every key, with defaults: scripts/README.md#profile.
# Values are literal: no quotes needed, no variables; only a leading ~/ expands.

oracle_home=~/oracle-home
oracle_key=oracle
path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Relay: a small model calls the harness's SendMessage tool once per inbox.
relay_default=claude
relay_claude_model=haiku
relay_claude_max_turns=4
relay_claude_timeout=300
# relay_claude_token_secret=claude-oauth-token

# Cheap worker: read-only tools, no tool servers.
worker_client=claude
worker_model=haiku
worker_timeout=600

# Reviewer: a different model of the same family, fresh context, neutral
# packet. Same-family review is a documented limitation: risky changes also
# get a human review.
reviewer_client=claude
reviewer_model=opus
reviewer_timeout=2400
review_family=same-family

secrets=os
