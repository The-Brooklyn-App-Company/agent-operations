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
- Freshness requirements: the head SHA, links and the source timestamps it must confirm, per field or source when the output combines several. A fresh read of one source, such as an unchanged list of tracked items, does not certify other fields or the latest owner instructions. Keep stale evidence dated and identify which current fields remain unknown; do not silently present it as current.

A worker's result checks protect actual boundaries: account identity, tool permissions, call/page caps, complete observations and no-action authority. Do not reject an allowed tool path merely because it differs from a preferred orchestration.

A metadata watcher only reports. It never reviews diffs, fixes code, posts comments or merges.

Verify capabilities in the actual receiving run. Use its exposed inventory and any supported deferred-tool discovery before declaring a tool unavailable; another conversation's catalog does not establish this run's access. A tool name mentioned in an instruction is not inventory evidence. Preserve the real result and never make an effectful provider call merely to test discovery. An unavailable external tool does not establish that an existing local receipt CLI is unavailable: attempt the permitted bounded local continuation and retain its exit code.

Carry applicable human communication authorization and its trusted source into the local worker profile. An agent handoff alone grants nothing, while an actual standing human grant must not be discarded merely because the run is disposable. Preserve destination and payload scope, and keep private provenance out of this public kit.

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

A completion summary, an inbox label or the words “eligible for archive” are not an archive operation. Verify the actual native operation or archive membership separately from result settlement; absence of a transcript item may limit the evidence, not justify inventing a receipt.

Runs that end failed, unknown or with uncertain delivery stay visible until they are resolved. A project's pending issue should keep only its affected workers visible, not every healthy worker.

If a human requested a digest, it is still due on quiet days, and it says "nothing changed". Synthesis across workers belongs to the operator, not to the workers.

## Coordinator return paths

Execution, operator handoff and human-facing publication are separate hops. When
clients differ, verify each supported hop with useful work: an owner event can
wake an idle intermediary; its returned result can notify the intended primary
conversation; and the primary can publish the requested brief. A successful
terminal callback alone does not prove independent event wake or scheduled
availability. Do not invent an endpoint, credential or hidden application-state
bridge to make a diagram work.

An event relay can reduce repeated cross-project status polling where the client
supports it. Keep it thin and change-only, use stable source/event identity in the
existing local receipt, and reconcile unknown delivery before retry. Retain the
working fallback until the replacement's actual acceptance. A read-only digest
collector consumes an existing writer's result; it does not become a second
writer or silently retire the old route. Record the relay's actual identity,
owner, lifetime and acceptance limits locally before treating it as permanent.

### Transport-only relay and receipt boundaries

Keep an accepted operator-to-local-intermediary-to-coordinator return route until
its replacement is actually verified. A destination that fails with an unknown
thread is not a working direct route. Bind each hop to its actual principal,
host, native identity and permitted scope in the existing private profile; a
matching title or another principal's successful run is insufficient.

The intermediary admits and returns bounded handoffs. It does not execute the
recipient's domain work, wait for its approvals or become another coordinator.
Domain work and approval waits stay with the owning operator so they cannot
block unrelated returns. Preserve denied and interrupted actions on their
original route; another hop is not permission to retry or evade a gate.

For one stable event and attempt, retain distinct evidence for transport
admission, recipient processing, recipient completion, coordinator return and
user publication. A terminal notification proves only that hop, not publication
or successful domain work. Keep actual message/turn references and timestamps
in existing local receipts, not a second queue. Reconcile unknown outcomes at
the relevant destination before retry; a failure at a later hop does not permit
resending an acknowledged earlier effect. Do not claim exactly-once delivery.

### Admitted request with no useful result

An accepted send may persist the request and start a turn that completes with
empty output. Treat that as a processing failure, not successful work or proof
of a transport outage. Inspect the exact recipient and turn through supported
native reads: request persistence, archive/loading state, tool calls, output,
terminal status and exposed errors. Do not infer a limit, cancellation or model
failure when the API reports none; do not inspect restricted session stores.

Keep the same correlation and distinguish a transport retry from a new bounded
instruction. Reconcile prior effects first. If the request was admitted and no
effect occurred, one authorized diagnostic follow-up may ask the same owner for
a read-only result. If it again completes empty, stop automated invocations and
report the exact evidence for native runtime diagnosis. Do not change models,
create a replacement worker or redirect a denied send to force a response.

The existing coordinator may summarize an already-produced artifact within its
own scope while the owner is unavailable. Label that coordinator processing;
never manufacture the owner's acknowledgement or mark its delivery complete.
Keep domain recovery and transport diagnosis separate. A lookup verifies a
destination exists, but does not reverse an approval-review identity denial.

### Native lifecycle acceptance

A documented wait budget does not prove that a worker stayed alive. Qualify the
actual supported execution/session lifecycle: an early wake must await its
original bounded process through terminal output in the same turn, without a
final answer while it is still running. A missing session is an unresolved
failure, not a due result or permission to restart the effect.

Before adoption, verify native traces for an early wake through due/claim and
acknowledged delivery, an interrupted or lost session with no fabricated due
result, uncertain delivery reconciled without duplicate publication, and failure
retention without self-archive. Verify successful settlement and archive last
separately. Offline clock/receipt fixtures do not certify those native behaviors.
Preserve the existing single writer and timely fallback; label supervised or
manual recovery separately from unattended success. Each adopting principal and
host must demonstrate its own round trip, not inherit another account's proof.

Quiet output does not establish low model cost. Inspect the actual model wake,
profile size, tool steps and available usage evidence; a deterministic gate may
run only after the model has started. Prefer a short current execution contract
linked to detailed diagnosis/identity references. Preserve source checks,
detection needs, receipt semantics and domain bounds when reducing overhead; do
not claim savings percentages from elapsed time alone.

## Uniqueness and replacement

Run one watcher per repository, principal, role and effect scope. Two accounts with distinct roles are distinct watchers. For example, an author-side watcher and a reviewer-side watcher must not suppress each other's detection of review requests.

When you replace a worker or move it to another host, stop the old one and verify that it has stopped before you enable the new one. Never run the same watcher on two hosts at once.

## Verify installed routing

At each schedule audit or cutover, read the supported native inventory for the
scope being audited or changed. Compare each definition with its owning local
profile: native ID, enabled/paused status, execution kind, execution destination,
model/effort and cadence. Distinguish where the run executes from where it sends
a useful handoff. A quiet prompt or a job's legitimate purpose does not prove it
runs outside the operator chat. Retain the small readback in the existing profile
or handoff; do not create another inventory service.

Check for duplicate active routes and expired exceptions before calling the
setup compliant. Inspect paused replacements without resuming them. Verify the
post-change native definition, then use the next natural run to establish actual
execution, durable settlement, required delivery or unchanged-result silence,
and disposal. Configuration alone does not establish those outcomes.

## Exceptions and temporary rollback

A deviation, including rollback to an operator-context schedule, records a
reason, responsible owner, stop condition and review deadline in the existing
local profile, plus the next natural-run acceptance needed to return to the
intended route. Expiry is a review/stop boundary, not automatic renewal. A later
audit must reconcile it with the installed configuration; historical use does
not make the exception permanent.

Carry observation and delivery state across a replacement or rollback in both
directions, so events already delivered on one route are not re-sent as new
alerts on the other.

If a replacement fails, preserve the failure and pending events and make the
coverage gap explicit. Repair it within the approved scope. Do not silently
reactivate an operator-context schedule: use an already authorized finite
exception or obtain the actual changed-scope decision. Keep one active route,
requested briefs and domain limits. Use existing run history and owner follow-up;
no new timer or approval for each ordinary in-scope repair is required.

## Example

[../examples/scheduled-worker-fixture.json](../examples/scheduled-worker-fixture.json) can be exercised offline with `python3 scripts/check_worker_example.py`. It shows captured single-event transitions for unchanged and non-actionable observations, acknowledged change/repeat, identical versus distinct failure episodes, unknown reads, uncertain delivery and reconciled acknowledgement without resend. The fixture supplies the recipient assessment; it does not implement model-assisted classification. These check captured decisions, not real scheduling or transport.

## Native setup recipe

Apply [installed routing verification](#verify-installed-routing), then ask the existing operator to prepare one standalone scheduled task using the approved repo/profile, model, effort, cadence/timezone and verified operator destination. The client may expose a native scheduling tool or its Scheduled controls; use the actual supported schema, not hand-edited app databases, automation files or OS cron wrappers. If the only path is UI, obtain app/task consent or guide the owner. Do not enable until the profile and old-to-new ownership are concrete.

A starter prompt is: “Run the bounded metadata check in the owning local worker profile. Use its deterministic eligibility/result packet and exact destination. Keep unchanged healthy runs quiet, send only eligible meaningful events or requested due briefs, persist results and acknowledged delivery, release the lease, then archive this successful worker chat last. Retain unresolved current-run failures. Do not review diffs, post, push, merge or deploy.”

Verify configuration, one safe execution, first natural run, delivery/content and disposal separately. Metadata collection can wake an operator for actionable review requests/check failures; substantive review, repair and approved backlog execution belong to that operator.
