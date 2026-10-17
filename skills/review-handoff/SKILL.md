---
name: review-handoff
description: Use when preparing a delegation packet, implementing from one, or reviewing delegated work at an exact SHA.
---

# Review handoff

## Locate the kit

1. Resolve this skill directory's real path by following symlinks.
2. Take the directory two levels up as the kit root.
3. On Windows, or if resolution fails, read `kit.kitRoot` from `~/.config/agent-operations/profile.local.json` or the alternate profile path explicitly recorded in local guidance.
4. If neither works, stop and report.

## Do

1. Follow `<kit-root>/docs/delegation-review.md`.
2. Build or read the packet from `<kit-root>/templates/delegation-packet.md`.
3. If you are the implementer: work from the base SHA, stay in scope and return implementer notes.
4. If you are the reviewer: record independent findings against the exact head SHA and the acceptance criteria.
5. Give every existing finding a disposition: fixed with a SHA, rejected with a reason, or deferred with an owner.
6. Stop when the stop criteria are met or the round limit is reached, then escalate open items.

## Never

- Switch billing, plans or providers when quota runs out. Stop and report instead.
- As a delegated implementer/reviewer, exceed the packet’s integration boundary. The operator retains its actual authorized merge/release scope.
- Approve a SHA other than the current head.
