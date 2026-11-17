# Continuity

Continuity is what lets work survive compaction, restarts, a changed client
or a person stepping away: the human says something once, and it is
remembered, owned and finished ([K-12](../kit/KIT.md), [K-15](../kit/KIT.md)).

## Records

These live in the Oracle's home and are stable in 0.2.0.

| Record | Holds | Rule |
| --- | --- | --- |
| `BACKLOG.md` | Every open commitment: owner, next action, due date, status | Written before the reply that makes the commitment; done items move to the journal |
| `JOURNAL.md` | Dated, append-only: the human's decisions, standing grants, promises made, deliveries | Written when it happens, never rewritten |
| `FACTS.md` | Verified facts agents may rely on and repeat: people, repositories, machines, accounts | Nothing is stated outward as fact unless it is listed here or freshly checked |

Each operator keeps its own `MANDATE.md` (scope, finish line, dated grants)
and `NOTES.md` (dated working memory) in its home.

**Recovery.** After a compaction, a restart or whenever unsure, a session
reads its `AGENTS.md` recovery list: the backlog's open items, the latest
journal entries, its mandate and notes, and what is scheduled. If a summary
disagrees with these files, the files win.

**Claims.** Report the highest stage with evidence
([K-10](../kit/KIT.md)): requested, received, working, returned, merged,
deployed, accepted.

## Experimental records

Useful in practice, but their formats may change.

| Record | Holds |
| --- | --- |
| `MISSES.md` | Continuity incidents: a re-ask, a replayed point, a stale fact, a rediscovery. Input to systemic fixes, not to new one-off rules |
| Return list | What the human must do or decide when back at their desk; feeds the [return-to-desk skill](../skills/return-to-desk/SKILL.md) and the [catch-up packet](../templates/packets/catch-up.md) |

## Lease and takeover

**Experimental, coming in 0.2.x.** Not part of 0.2.0.

Any operator may have a session on each client: one holder and one standby.
The 0.2.x layer adds an advisory lease in `.operator/lease` (one routed
holder per operator, a redirect from the wrong side, a human-confirmed
takeover with a cold handoff note), file mailboxes under
`.operator/inbox/` with optional per-client doorbells, and a committed asks
and approvals ledger. It will not claim hard exclusion or crash-safe resume.

Until it ships: give each operator one session on one client, and move it
by hand. Park the work, push its branches, write a short handoff in
`NOTES.md`, stop the old session, then start the new one in the same home
and update its registry row. Treat every external effect the old session
may have started as unknown until you have checked the target
([K-28](../kit/KIT.md)).

## Mailboxes and doorbells

**Experimental, coming in 0.2.x.** In 0.2.0 the transport is the Oracle
home's `inbox/<key>/` folders and `relay.sh`
([scripts/README.md](../scripts/README.md#the-oracle-home)).

## Asks and approvals ledger

**Experimental, coming in 0.2.x.** In 0.2.0 an operator sends one batched
ask to the Oracle and acts only on the human's answer in the Oracle's thread
([K-08](../kit/KIT.md)), for that exact target and revision.
