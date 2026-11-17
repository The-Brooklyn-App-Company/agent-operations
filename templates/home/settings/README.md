# Client permission patterns

Placeholders for the human to adapt and apply in each client's own
settings. The kit never edits client settings; agents do not apply these.

## Claude Code

Applied in the client's settings for this home (for example a local
settings file next to the project). Fill in the paths and commands.

```json
{
  "permissions": {
    "allow": ["Bash(git status:*)", "Bash(git diff:*)", "Bash(<kit-dir>/scripts/status.sh:*)"],
    "ask": ["Bash(git push:*)"],
    "deny": ["Bash(git push --force:*)", "Read(<secrets-dir>/**)"]
  }
}
```

## Codex

Applied in the Codex configuration for this home: sandbox level and
approval policy, for example `sandbox_mode = "workspace-write"` with
`approval_policy = "on-request"`, and every tool server that can act on the
outside world disabled unless this operator's mandate needs it.

## What a pattern allows, and never allows

| Allows | Never allows |
| --- | --- |
| Reading and editing this home and its work repositories | Anything on the never-relayed list (K-03) |
| Running the kit's read-only scripts and the repositories' tests | Reading secrets or printing credentials (K-05) |
| Committing and pushing to this operator's own branches | Force-pushing, or pushing to a branch it does not own (K-16) |
| | Changing its own permission settings |
