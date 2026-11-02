---
name: release-closeout
description: Use when declaring activation needs in a pull request, promoting a release, or following a release until it settles.
---

# Release closeout

## Locate the kit

1. Resolve this skill directory's real path by following symlinks.
2. Take the directory two levels up as the kit root.
3. On Windows, or if resolution fails, read `kit.kitRoot` from `~/.config/agent-operations/profile.local.json` or the alternate profile path explicitly recorded in local guidance.
4. If neither works, stop and report.

## Do

1. Follow `<kit-root>/docs/releases.md`.
2. Use `<kit-root>/templates/release-record.md` in the repository's existing release record or index. Do not create a parallel one.
3. Match the intended target and acting principal through the actual execution route before effects.
4. Record source, artifact, deployment and intended-persona acceptance separately, following the guide.
5. Follow the activations and any recovery until the release settles.

## Never

- Treat release approval as covering UI control, authentication, email, purchases or expanded spend.
- Invent soak periods, manual cloud logins or paid test runs that the repository does not require.
