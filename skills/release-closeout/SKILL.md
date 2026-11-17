---
name: release-closeout
description: Use when declaring activation needs in a pull request, promoting a release, or following a release until it settles.
---

# Release closeout

`<kit>`: two levels above this skill's real path.
Stop if it does not resolve.

1. Read `<kit>/docs/review-and-release.md#release`.
2. Fill the activation section of `<kit>/templates/packets/release-record.md`
   in the pull request.
3. Use the repository's existing release record; never start a parallel one.
4. Confirm the target and acting principal from the execution route before
   any effect.
5. Check the promotion is covered by the release owner's yes or a written
   standing grant.
6. Execute the ordered activations; record each one's result.
7. Record each state separately: CI, merged, artifact, staging, runtime,
   accepted.
8. Own recovery until the release settles; never retry an ambiguous write.
9. Report the highest stage reached, with evidence, to the Oracle.
