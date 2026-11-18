# Profile: codex-only. Codex runs every role.
# Copy it outside git (default: ~/.config/agent-operations/profile) and edit;
# install.sh oracle does this for you. Every key and its default:
# scripts/README.md#profile. Values are literal; only a leading ~/ expands.
# Replace every CHANGE-ME.

oracle_home=~/ops/oracle
oracle_key=oracle
work_root=~/src
path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Relay: Codex rows queue pointers by default when the owner has a real
# thread ID. Set relay_codex=off for passive inbox pickup, or file-only on
# an individual registry row. One isolated live round trip observed; see
# README.md for versions and existing-account/machine limits. No guaranteed resume.
# doorbell_codex is a separate, default-off opt-in, fakes only; live unrun.
# Queued does not mean read.
relay_default=codex
relay_codex=queue

# Cheap worker: read-only sandbox, ephemeral; every tool server in your
# Codex configuration is switched off for the run.
worker_client=codex
worker_model=CHANGE-ME-small-codex-model
worker_timeout=600

# Reviewer: a different model of the same family, fresh context, neutral
# packet. Same-family review is labelled; risky changes also get a human
# read (K-21).
reviewer_client=codex
reviewer_model=CHANGE-ME-strong-codex-model
reviewer_effort=high
reviewer_timeout=2400
review_family=same-family

# Weekly cross-review (K-22) falls back to the same family, with a
# different model than the implementer; status.sh warns.
implementer_codex_model=CHANGE-ME-strong-codex-model
reviewer_codex_model=CHANGE-ME-other-codex-model
reviewer_codex_effort=high
reviewer_codex_timeout=900
cross_review=on

secrets=os
