# Profile: custom. Any CLI that can take a prompt file and write a result.
# Copy it outside git (default: ~/.config/agent-operations/profile) and edit.
# Every key and its default: scripts/README.md#profile. The command
# contract (run / deliver / activity) is in scripts/lib/vendor-custom.sh.
# The kit enforces the timeout and closes stdin; your command must keep
# `run` read-only.

oracle_home=~/ops/oracle
oracle_key=oracle
work_root=~/src
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

# Also used by the weekly cross-review for custom rows (K-22).
reviewer_client=custom
reviewer_cmd=~/bin/my-agent
reviewer_model=CHANGE-ME-strong-model
reviewer_timeout=2400
review_family=single-model
cross_review=on

# Mailroom (experimental, docs/mailroom.md): the relay writes rings for the
# in-app bridges (install.sh bridge claude|codex); the supervisor falls back
# to the relay transports above. off = deliver through the transports.
relay_bridge=on
# bridge_codex_node=CHANGE-ME-node-bundled-in-the-desktop-app
# bridge_codex_server=CHANGE-ME-codex-app-tools-server.mjs-in-the-desktop-app
# host_apps=com.anthropic.claudefordesktop com.openai.codex

secrets=os
