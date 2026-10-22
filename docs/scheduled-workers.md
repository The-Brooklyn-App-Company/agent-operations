# Scheduled workers

A scheduled worker is a disposable, narrowly scoped run. It starts from a profile ([../templates/worker-profile.md](../templates/worker-profile.md)), does one job and is archived when it succeeds. Use the scheduler that your client actually supports. Use its native controls to pause, resume, edit and archive. No routine is active until a human approves it.

## Deterministic first

Run cheap, deterministic checks before any model reasoning:

- Eligibility
- Time window or triggering event
- Input schema validity
- Lock acquisition

If nothing is eligible and all required reads are fresh and healthy, the run ends quietly. Failed or stale reads take the explicit unknown/failure route, not the empty-events route.

An early invocation does not complete a later requested occurrence. Use bounded waiting within the supported run or a verified retry path; do not assume the scheduler will invoke it again that day. Keep the intended occurrence and acknowledged delivery separate from invocation time.

## Profile bounds

Each worker declares:

- A local profile
- The tools it may use
- The effects it may have
- The exact events it watches
- Freshness requirements: the head SHA, links and the source timestamps it must confirm

A metadata watcher only reports. It never reviews diffs, fixes code, posts comments or merges.

## State and outcomes

- **Healthy and unchanged** stays quiet.
- **Failed** and **unknown** are distinct outcomes. Neither one may look like "unchanged".
- Store each event's durable ID **and** a fingerprint of its content. A cursor alone cannot tell you whether a known event's content changed.
- Group repeated identical failures into one episode using source identity and a failure fingerprint, not just a broad error category. Distinct sources or materially changed failures must remain detectable. Define recovery for the monitored purpose; a single transient successful read need not close an intermittent failure episode.
- Mark an event delivered only after the transport acknowledges it. If delivery is uncertain after a crash or timeout, retain the pending event and stable delivery key. Reconcile the destination/history first. Retry with the same idempotency key only when the transport actually supports it; otherwise recover under the profile’s bounded duplicate-aware procedure. Never claim exactly-once delivery across crashes.

## Escalation belongs to the recipient

A new event is a candidate observation, not an automatic message. Before interrupting an operator, compare current owner evidence and the owning queue. Identify what this recipient needs to do or know, why it matters now, and why the owning lane has not already handled or reported it. An ordinary failed experiment with a safe owner response, routine progress, an existing question and a repair already reported to the human stay in local state for the next requested digest. Do not invent an action to justify forwarding an event.

For bounded model-assisted classification, save the source identity/fingerprint, disposition and short reason in the existing local state. A deterministic gate should require a complete current assessment; legacy references, stale assessments and unclassified events remain local rather than generating triage-only messages. Uncertainty is retained for bounded follow-up or the requested digest, never silently marked healthy. A new unresolved monitoring failure may still need one useful escalation under its episode policy.

Send a brief readable handoff: what changed, the actual recipient action or attention needed, and source evidence. Keep cursor maps, acknowledgement IDs, JSON envelopes and delivery bookkeeping in local state. Reconcile superseded events before sending. If the receiving operator discovers no follow-through is needed, record that disposition silently; do not add a “checked, nothing needed” commentary or final reply. Explicitly requested digests remain due even on quiet days.

## Ending a run

1. Persist the actual result and any delivery acknowledgement; advance only acknowledged delivery state. A tool accepting a handoff is not proof that a requested user-facing brief was published.
2. Release your own lock/lease.
3. Archive only this successful worker chat last, using its supported native archive route. Archiving may immediately end the turn; do not rely on a later finalizer. A finite follow-up also pauses or retires its recurring schedule at settlement/expiry; archiving individual worker chats alone does not stop future runs.

Runs that end failed, unknown or with uncertain delivery stay visible until they are resolved. A project's pending issue should keep only its affected workers visible, not every healthy worker.

If a human requested a digest, it is still due on quiet days, and it says "nothing changed". Synthesis across workers belongs to the operator, not to the workers.

## Uniqueness and replacement

Run one watcher per repository, principal, role and effect scope. Two accounts with distinct roles are distinct watchers. For example, an author-side watcher and a reviewer-side watcher must not suppress each other's detection of review requests.

When you replace a worker or move it to another host, stop the old one and verify that it has stopped before you enable the new one. Never run the same watcher on two hosts at once.

## Exceptions

Any deviation from this guidance records a reason, an owner and an expiry date.

## Example

[../examples/scheduled-worker-fixture.json](../examples/scheduled-worker-fixture.json) can be exercised offline with `python3 scripts/check_worker_example.py`. It shows captured single-event transitions for unchanged and non-actionable observations, acknowledged change/repeat, identical versus distinct failure episodes, unknown reads, uncertain delivery and reconciled acknowledgement without resend. The fixture supplies the recipient assessment; it does not implement model-assisted classification. These check captured decisions, not real scheduling or transport.

## Native setup recipe

Ask the existing operator to inspect native schedules, then prepare one standalone scheduled task using the approved repo/profile, model, effort, cadence/timezone and verified operator destination. The client may expose a native scheduling tool or its Scheduled controls; use the actual supported schema, not hand-edited app databases, automation files or OS cron wrappers. If the only path is UI, obtain app/task consent or guide the owner. Do not enable until the profile and old-to-new ownership are concrete.

A starter prompt is: “Run the bounded metadata check in the owning local worker profile. Use its deterministic eligibility/result packet and exact destination. Keep unchanged healthy runs quiet, send only eligible meaningful events or requested due briefs, persist results and acknowledged delivery, release the lease, then archive this successful worker chat last. Retain unresolved current-run failures. Do not review diffs, post, push, merge or deploy.”

Verify configuration, one safe execution, first natural run, delivery/content and disposal separately. Metadata collection can wake an operator for actionable review requests/check failures; substantive review, repair and approved backlog execution belong to that operator.
