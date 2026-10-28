# Worker profile: `<name>`

- **Kit version:** `<version>`
- **Repository / principal / role / effect scope:** `<repo>` / `<account>` / `<role>` / `<scope>`
- **Host:** `<host label>`. Exactly one active host.
- **Scheduler / native ID / status:** `<native scheduler>` / `<id>` / `<enabled or paused>`. Use its native controls.
- **Execution kind / destination / model and effort / cadence:** `<standalone or attached context>` / `<run location, separate from handoff target>` / `<selection>` / `<schedule and timezone>`. Compare actual native readback with this profile at each schedule audit or cutover.
- **Approved by and on:** `<who, date>`

## Deterministic gate

- **Eligibility:**
- **Time window or trigger event:**
- **Input schema:**
- **Lock:**

## Bounds

- **Tools allowed:**
- **Allowed effects:**
- **Forbidden effects:** reviewing diffs, fixing code, posting comments and merging, unless this is explicitly not a watcher.
- **Events watched:**
- **Freshness required:** head SHA, links and source timestamps.

## State

- **Store:** `<location>`. Store the event ID and a content fingerprint for each event.
- **Episode deduplication:**
- **Delivery target:** `<target>`. Keep a stable delivery key; use native idempotency only if supported. Reconcile uncertain delivery before retry. Mark delivered only after acknowledgement.

## Outcomes

- **Healthy-unchanged:** quiet; release the lock and archive.
- **Meaningful change for this recipient:** deliver the readable handoff; persist acknowledgement/results, release the lock and archive this successful chat last.
- **Handled or non-actionable observation:** persist the disposition and reason locally; stay quiet. Release the lock and archive if this run has no unresolved failure. Use the [recipient-aware escalation rule](../docs/scheduled-workers.md#escalation-belongs-to-the-recipient).
- **Failed, unknown or delivery-uncertain:** release the lock and stay visible.
- **Requested digest:** `<due even on quiet days, or not applicable>`

## Exceptions

| Exception | Reason | Owner | Stop condition / review deadline | Next natural-run acceptance |
| --- | --- | --- | --- | --- |

## Replacement or retirement

Stop the old worker and verify it has stopped. Only then enable the replacement. Record native configuration separately from natural-run acceptance. A failed replacement does not silently authorize an indefinite operator-context rollback; follow [routing and exceptions](../docs/scheduled-workers.md#verify-installed-routing).
