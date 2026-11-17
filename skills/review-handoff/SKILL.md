---
name: review-handoff
description: Use when preparing a delegation packet, implementing from one, reviewing work at an exact commit, or triaging cross-review findings.
---

# Review handoff

`<kit>`: two levels above this skill's real path.
Stop if it does not resolve.

1. Read `<kit>/docs/review-and-release.md#delegation` and `#review`.
2. Build the packet from `<kit>/templates/packets/delegation.md`: goal,
   exact base commit, scope, acceptance, stop criteria.
3. Implementer: work from the base commit on a scoped branch; return the
   implementer notes.
4. Reviewer: verify the checkout and head, then review the neutral packet
   only; never ask for the implementer's reasoning.
5. Run the review with `<kit>/scripts/review-run.sh`, and record the
   `review_family` it prints.
6. Give every finding a disposition: fixed (commit), rejected (reason) or
   deferred (owner, link).
7. Stop after a clean round or three rounds; escalate open P0 and P1.
8. Cross-review findings in your inbox: triage the same way within a
   working day (`<kit>/docs/review-and-release.md#cross-model-accountability`).
9. Hand the branch to the merge owner with the packet's handoff section.
