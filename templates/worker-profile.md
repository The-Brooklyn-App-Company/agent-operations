# Worker profile: `<name>`

- **Kit version:** `<version>`
- **Repository / principal / role / effect scope:** `<repo>` / `<account>` / `<role>` / `<scope>`
- **Host:** `<host label>`. Exactly one active host.
- **Scheduler:** `<native scheduler>`. Use its native pause, edit and archive controls.
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
- **Changed:** deliver; persist acknowledgement/results, release the lock and archive this successful chat last.
- **Failed, unknown or delivery-uncertain:** release the lock and stay visible.
- **Requested digest:** `<due even on quiet days, or not applicable>`

## Exceptions

| Exception | Reason | Owner | Expiry |
| --- | --- | --- | --- |

## Replacement or retirement

Stop the old worker and verify it has stopped. Only then enable the replacement. Record the result.
