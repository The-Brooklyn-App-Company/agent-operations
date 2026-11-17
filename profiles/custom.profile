# Profile: custom. Any CLI that can take a prompt file and write a result.
# Copy it outside git (default: ~/.config/agent-operations/profile) and edit.
# Format and every key, with defaults: scripts/README.md#profile.
# The command contract (run / deliver / activity) is in
# scripts/lib/vendor-custom.sh. The kit enforces the timeout and closes
# stdin; your command must keep `run` read-only.

oracle_home=~/oracle-home
oracle_key=oracle
path=/usr/local/bin:/usr/bin:/bin

# Relay through your own command, or leave notes for sessions to read.
relay_default=custom
relay_custom_cmd=~/bin/my-agent
relay_custom_timeout=300
# relay_default=file-only

worker_client=custom
worker_cmd=~/bin/my-agent
worker_model=CHANGE-ME-small-model
worker_timeout=600

reviewer_client=custom
reviewer_cmd=~/bin/my-agent
reviewer_model=CHANGE-ME-strong-model
reviewer_timeout=2400
review_family=single-model

secrets=os
