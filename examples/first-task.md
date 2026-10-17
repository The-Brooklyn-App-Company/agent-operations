# First low-risk task: Example App

This walkthrough exercises the full loop without paid provider calls, deployments or runtime effects. Two synthetic accounts take part: `author` and `reviewer`.

## 1. Observe

The operator for Example App reads the queue and finds an existing task: "README setup section is out of date." It reuses that task and does not create a new one.

## 2. Propose

The operator writes a handoff ([../templates/operator-handoff.md](../templates/operator-handoff.md)) with the following sections:

- **Observed:** The README names a removed setup step.
- **Proposed:** A docs-only change on a scoped branch from base SHA `<sha>`. The acceptance criterion is that the steps match the current Makefile targets.
- **Authority:** The existing task or approved setup permits the scoped docs branch/PR; if that boundary is absent, present the concrete proposed scope once.

## 3. Approve

Use the actual task/standing approval. A new human decision is needed only for missing scope, not each edit or check.

## 4. Execute

The operator edits the README, runs the repository's existing documentation checks, pushes and opens the pull request as `author`. It records the head SHA in the handoff under **Executed**.

Optionally, the operator can delegate the edit using [../templates/delegation-packet.md](../templates/delegation-packet.md) instead of making it directly.

## 5. Review

The review comes from the `reviewer` account, at the exact head SHA. It checks the change against the acceptance criterion. Any finding receives a disposition: fixed with a SHA, rejected with a reason, or deferred with an owner.

## 6. Close

After the required checks pass on the last push, the change is merged through the repository's normal route. The PR notes "no operational activation"; no production release record is needed unless a production promotion actually occurs. Close the task only at its actual acceptance boundary.

## Checkpoint

Confirm all of the following:

- The existing task was reused.
- Actual task authority was identified; no consent was fabricated.
- The opposite account performed the review.
- No credentials, paid calls or UI control were involved.

## If you work alone

Use an independent bounded agent review under your own account, preserving its actual authorship and all checks. Follow the repository's explicitly authorized solo integration route, or stop at an approval-ready local artifact/PR if no merge authority exists. Do not create or impersonate a second human principal just to satisfy the example. A two-account team must later prove real reviews in both directions; solo review is not evidence of that.
