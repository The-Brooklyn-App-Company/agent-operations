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
# can say file-only instead. Codex sessions read their inbox.
relay_default=claude
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

secrets=os
