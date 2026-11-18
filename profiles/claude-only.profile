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

secrets=os
