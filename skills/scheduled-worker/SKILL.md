---
name: scheduled-worker
description: Use when designing, reviewing, running, replacing or retiring a scheduled worker or watcher. Not for one-off tasks.
---

# Scheduled worker

## Locate the kit

1. Resolve this skill directory's real path by following symlinks.
2. Take the directory two levels up as the kit root.
3. On Windows, or if resolution fails, read `kit.kitRoot` from `~/.config/agent-operations/profile.local.json` or the alternate profile path explicitly recorded in local guidance.
4. If neither works, stop and report.

## Do

1. Follow `<kit-root>/docs/scheduled-workers.md`.
2. Fill in `<kit-root>/templates/worker-profile.md` before you enable anything.
3. Check the expected behavior against `<kit-root>/examples/scheduled-worker-fixture.json`.
4. Use only the scheduler controls that the client actually provides.
5. Report each outcome as one of: healthy-unchanged (quiet), changed, failed, unknown or delivery-uncertain.
6. Release your own lock, then archive last. Unresolved runs stay visible.

## Never

- Enable a worker without explicit approval.
- Run the same watcher on two hosts. Stop the old one and verify before enabling the new one.
- Review diffs, fix code, post comments or merge from a metadata watcher.
- Mark an event delivered before the transport acknowledges it.
