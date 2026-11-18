# Handoff permission patterns (both clients)

For an operator with a session on each client (experimental handoff layer,
see the kit's `docs/handoff.md`). The kit never edits client settings: apply
these yourself, in each client's settings for this home.

## Claude Code

```json
{ "permissions": { "deny": [
  "Bash(*lease.sh*takeover*)", "Bash(*lease.sh*unlock*)", "Bash(*lease.sh*settle*)"
] } }
```

## Codex

A rules file (for example `~/.codex/rules/operator.rules`). Prefix rules
match exact leading tokens only; the scripts refuse these verbs inside an
agent's tool shell anyway.

```
prefix_rule(pattern=["@KIT_DIR@/scripts/lease.sh", "takeover"], decision="forbidden")
prefix_rule(pattern=["sh", "@KIT_DIR@/scripts/lease.sh", "takeover"], decision="forbidden")
prefix_rule(pattern=["@KIT_DIR@/scripts/lease.sh", ["unlock", "settle"]], decision="forbidden")
```

## Both

Every turn starts with `lease.sh renew --instance <token> --epoch <n>`
once this operator uses the lease; a refused renew means this session is
the standby: no work, reply with `lease.sh redirect`.
