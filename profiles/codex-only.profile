# Profile: codex-only. Codex runs every role.
# Copy it outside git (default: ~/.config/agent-operations/profile) and edit.
# Format and every key, with defaults: scripts/README.md#profile.
# Values are literal: no quotes needed, no variables; only a leading ~/ expands.
# Replace every CHANGE-ME: an unset model would silently use the client's
# default, so the examples fail loudly instead.

oracle_home=~/oracle-home
oracle_key=oracle
path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Relay: Codex has no verified cross-session messaging, so sessions read
# their inbox at turn start and on recovery. The `codex` transport (one
# read-only `codex exec resume` turn) is EXPERIMENTAL.
relay_default=file-only
# relay_default=codex
# relay_codex_model=CHANGE-ME-small-model

# Cheap worker: read-only sandbox, ephemeral. List the tool servers in your
# Codex config that can act on the world (trading, mail, UI control...).
worker_client=codex
worker_model=CHANGE-ME-small-model
worker_timeout=600
worker_mcp_disable=CHANGE-ME-server-a,CHANGE-ME-server-b

# Reviewer: a different model of the same family, fresh context, neutral
# packet. Same-family review is a documented limitation: risky changes also
# get a human review.
reviewer_client=codex
reviewer_model=CHANGE-ME-strong-model
reviewer_effort=high
reviewer_timeout=2400
reviewer_mcp_disable=CHANGE-ME-server-a,CHANGE-ME-server-b
review_family=same-family

secrets=os
