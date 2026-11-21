# Continuity

Continuity is what lets work survive compaction, restarts, a changed client
or a person stepping away: the human says something once, and it is
remembered, owned and finished ([K-12](../kit/KIT.md), [K-15](../kit/KIT.md)).

## Records

These live in the Oracle's home and are stable since 0.2.0.

| Record | Holds | Rule |
| --- | --- | --- |
| `BACKLOG.md` | Every open commitment: owner, next action, due date, status | Written before the reply that makes the commitment; done items move to the journal |
| `JOURNAL.md` | Dated, append-only: the human's decisions, standing grants, promises made, deliveries | Written when it happens, never rewritten |
| `FACTS.md` | Verified facts agents may rely on and repeat: people, repositories, machines, accounts | Dated, with how each was verified ([K-12](../kit/KIT.md)) |

Each operator keeps its own `MANDATE.md` (scope, finish line, dated grants)
and `NOTES.md` (dated working memory) in its home.

**Recovery.** After a compaction, a restart or whenever unsure, a session
reads its `AGENTS.md` recovery list: the backlog's open items, the latest
journal entries, its mandate and notes, and what is scheduled. If a summary
disagrees with these files, the files win. In Claude Code,
`scripts/recover-context.sh` as a SessionStart hook (`compact|resume`)
puts a digest in front of the session: rule titles, an order to read the
full files first, open backlog rows, recent journal headings and next
checks. Claude Code replaces hook output over about 10 KB with a short
preview, so the digest is capped at 8 KB and never pastes whole files;
a test fails above the cap. Register it from
[the settings template](../templates/home/settings/README.md).

**Claims.** Report the highest stage with evidence
([K-10](../kit/KIT.md)): requested, received, working, returned, merged,
deployed, accepted, and name the mechanism: "delivered by the bridge
(MATCHES the agreed mailroom design)" or "delivered by the 3-minute fallback
(DEVIATES: the bridge was down)". Say a deviation when it happens.

**Daily oversight** ([K-35](../kit/KIT.md)). Once a day the Oracle asks of
each operator: what moved toward the product outcome since yesterday? A day
spent on machinery (CI plumbing, review loops, tooling) with no product
movement gets a redirect the same day. Routine machinery under an approved
goal never goes to the human ([K-09](../kit/KIT.md)). Then it reads the
human's own words since the last check (requests, feedback, corrections)
against the backlog and journal: anything without a row gets one, so the
human never has to say it twice.

## Experimental records

Useful in practice, but their formats may change.

| Record | Holds |
| --- | --- |
| `MISSES.md` | Continuity incidents: a re-ask, a replayed point, a stale fact, a rediscovery. Input to systemic fixes, not to new one-off rules |
| Return list | What the human must do or decide when back at their desk; feeds the [return-to-desk skill](../skills/return-to-desk/SKILL.md) and the [catch-up packet](../templates/packets/catch-up.md) |

## Lease and takeover

**Experimental since 0.2.1:** [handoff across clients](handoff.md), tested
with [`TESTING.md`](../TESTING.md).

Any operator may have a session on each client: one holder and one standby.
The layer adds an advisory lease in `.operator/lease` (one routed holder per
operator, a redirect from the wrong side, a human-confirmed takeover with a
cold handoff note) and a switch-in audit gate shared with the weekly
cross-review ([K-22](../kit/KIT.md)). It does not claim hard exclusion or
crash-safe resume.

Without it (the stable path): give each operator one session on one client,
and move it by hand. Park the work, push its branches, write a short handoff
in `NOTES.md`, stop the old session, then start the new one in the same home
and update its registry row; `cross-review.sh` then records the switch-in
audit and `status.sh` shows it pending until the new session records the
report ([handoff](handoff.md#switch-in-audit)). Treat every external effect
the old session may have started as unknown until you have checked the
target ([K-28](../kit/KIT.md)).

## Mailboxes and doorbells

The Oracle home's `inbox/<key>/` folders and `relay.sh` are the stable
store ([scripts/README.md](../scripts/README.md#the-oracle-home)); the
[mailroom](mailroom.md) that delivers across the apps is experimental since
0.3.1. **Experimental since 0.2.1:** file mailboxes under
`.operator/inbox/` and per-client doorbells
([handoff](handoff.md#mailboxes-and-doorbells)), which ring the mailroom
when it is on.

## Asks and approvals ledger

**Experimental since 0.2.1:** a committed `ASKS.md` per home and the
Oracle's `APPROVALS.tsv`, bound to the lease epoch
([handoff](handoff.md#asks-and-approvals)). Without it, an operator sends one
batched ask to the Oracle and acts only on the human's answer in the
Oracle's thread ([K-08](../kit/KIT.md)), for that exact target and revision.
