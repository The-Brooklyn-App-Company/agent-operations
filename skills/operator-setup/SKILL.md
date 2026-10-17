---
name: operator-setup
description: Use when adopting Agent Operations in a conversation or repository, or when re-checking an existing adoption. Not for routine repository work.
---

# Operator setup

## Locate the kit

1. Resolve this skill directory's real path by following symlinks.
2. Take the directory two levels up as the kit root: `<kit-root>/skills/operator-setup` becomes `<kit-root>`.
3. On Windows, or if resolution fails, read `kit.kitRoot` from `~/.config/agent-operations/profile.local.json` or the alternate profile path explicitly recorded in local guidance.
4. If neither works, stop and report. Do not guess paths.

## Do

1. Read `<kit-root>/START-HERE.md` and follow its staged acceptance checkpoints within the actual approved scope.
2. Use `<kit-root>/docs/roles-and-context.md` for role boundaries.
3. Inventory read-only first: existing tasks, client version, native tools and signed-in accounts.
4. Label every item as either existing or proposed new. Reuse what exists.
5. Continue already-approved steps; pause only for missing authority, a consequential decision or owner-controlled authentication/UI consent. Record the state with `<kit-root>/templates/operator-handoff.md`.

## Never

- Create tasks, schedules, worktrees or remote connections outside the approved setup scope.
- Start login flows or control UIs without explicit consent.
- Copy credentials or print secrets.
- Edit application databases or internal state to simulate a missing capability.
