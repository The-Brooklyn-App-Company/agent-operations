# Conventions

The working conventions for running sessions in two desktop apps at once,
Claude Code and Codex. Rules are cited by ID ([kit/KIT.md](../kit/KIT.md));
this page says how to apply them, and which script applies each one.

## One active side

| Convention | Where it lives | Applied by |
| --- | --- | --- |
| **One active side per operator** ([K-13](../kit/KIT.md)): exactly one client and session run an operator; the other side is parked | The registry row (`client`, `session`) | `lane.sh switch` and `verify`; `lane.sh check` |
| **The parked side stays dormant**: it does not act, write or coordinate; asked anything, it replies "parked" and names the active side | The first recovery step of every home's `AGENTS.md` (`lane.sh side <key>`) | `install.sh operator` (the template) |
| **One active Oracle** ([K-13](../kit/KIT.md)): one client holds the Oracle role at a time | `operators/ORACLE-LOCK` in the Oracle home (`holder=`, `session=`, `since=`) | `lane.sh oracle-lock take`, only on the human's word ([K-01](../kit/KIT.md)); `lane.sh check`, `install.sh host` |
| **Delegation goes to workers, not to the standby Oracle** | [K-23](../kit/KIT.md) | `worker-run.sh` |

## Messages

| Convention | Applied by |
| --- | --- |
| **Same app goes direct**: Claude to Claude with `SendMessage`, Codex to Codex with `send_message_to_thread`, in real time. No inbox file, no bridge, no double delivery | The sessions themselves |
| **Cross-app, and anything a script sends, goes through the mailroom**: a note in the recipient's inbox, then the relay, a ring, and the receiving app's bridge ([mailroom](mailroom.md)) | `inbox-put.sh`, `relay.sh`, the bridges |
| **Messages are pointers**: the relay's fixed message names the archived note files and a relay id, never the note text ([K-01](../kit/KIT.md)) | `relay.sh` |
| **Steer or queue**: a note whose file name says `urgent` or `steer` steers (lands mid-turn); every other note queues until the target's turn ends | `relay.sh` (the ring name), the Codex watcher |
| **Lanes are never pre-woken** ([mailroom](mailroom.md#one-rule)) | The supervisor wakes only the bridges |
| **Short handoffs**: a task handed to another session says the outcome, a reference to its scope and authority (the mandate section, the ask id), the exact artifact or head, the acceptance test, what is excluded, and where to return; uncertainty and the one next step stay in the sender's notes | [Delegation packet](../templates/packets/delegation.md) |
| **Never a config-only message**: no message to an idle session exists only to change its model or settings ([K-26](../kit/KIT.md)) | `operator.sh model` |

## Sidebar and titles

The desktop apps' sidebars are how the human sees who is working. Keep
them true to the registry.

| App | Active | Inactive | The Mailroom |
| --- | --- | --- | --- |
| Claude | Operators active on Claude are **pinned**, titled with the operator's registry name | Parked operators sit in a sidebar section named **Inactive Operators** | Titled **Mailroom**; it may sit nested under the Oracle |
| Codex | Threads of operators active on Codex are **pinned** | Parked threads are unpinned | Titled **Mailroom**, **pinned** |

Both bridges are titled "Mailroom"; the registry keys `mailroom-claude`
and `mailroom-codex` tell them apart. Titles, pins and sections are set in
each app, by the human or by that side's own tools; no script writes them.
`install.sh host` lists them as in-app steps, and `lane.sh verify` will not
close a switch until they are marked done.

## Operator routines

Every routine is a guided script with a verifier ([K-36](../kit/KIT.md)):
it explains, asks only for the human's choices, does what a script can,
prints each in-app step with what to do, and closes only when every step
passes. Re-running is safe; `operator.sh verify KEY` re-checks the open
routine, `operator.sh mark KEY STEP` records an in-app step, `operator.sh
list` shows what is open (the nightly hygiene check lists any open over a
day).

| Routine | Command | Steps |
| --- | --- | --- |
| First run | `bootstrap.sh` | [First run](hosts-and-ci.md#first-run) |
| Create an operator | `operator.sh create KEY` | home, models (both clients, decided now with the human), session (created with that model), title, pin, mandate (the human's words), `check.sh home` |
| Archive an operator | `operator.sh archive KEY` | handoff, worktrees (verified local git bundles in `archive_dir` with the `KEY/*` branches and the worktree's HEAD, then removed; uncommitted or ignored files stop it for the human), jobs, sidebar, registry (last) |
| Switch between clients | `lane.sh switch KEY --to CLIENT --session ID` (or `operator.sh switch`) | [below](#switching-an-operator-between-clients) |
| Change an operator's model | `operator.sh model KEY --client C --model M --words "..."` | record (with the human's words, in the journal), apply (the app's own setting, or a new session and a switch) |
| Recover a Codex thread | `operator.sh recover KEY` (the supervisor opens it) | [thread recovery](mailroom.md#thread-recovery) |
| Record a session id | `operator.sh session KEY ID` | Also for the Oracle and both Mailrooms |

**Models are decided once.** An operator's model and effort, for both
clients, are chosen with the human at creation and recorded in its
`operator.conf`; the registry stays the one routing source (client and
session). Operators orchestrate and may spawn cheaper or stronger
subagents, but never change their own model; `operator.sh model` is the
separate, human-initiated path, and it refuses to run from the operator's
own session ([client capabilities](client-capabilities.md#models)).

## Switching an operator between clients

A switch is a scripted checklist ([K-36](../kit/KIT.md)): `lane.sh switch`
opens it, `lane.sh verify` checks every step in order and does the ones a
script can do, and the switch closes only when every step passes.

```sh
scripts/lane.sh switch web --to codex --session <thread-id>
scripts/lane.sh verify web          # repeat; it says what is left
scripts/lane.sh mark web labels --evidence 'sidebar listing shows "Web"'
```

| Step | What passes it | Who |
| --- | --- | --- |
| handoff | The outgoing session committed a warm `HANDOFF.md` in the home after the switch opened (`switch` asks it by an inbox note). Gone already: `lane.sh mark KEY handoff --cold REASON` | Outgoing session |
| routing | The registry row names the incoming client and session; `verify` writes it once the handoff passes, then sends the incoming session a switch-in note with a one-time token | Script |
| watchdog | No quiet-list entry silences the operator; no timed job in `JOBS.tsv` names the old session | Script checks; you fix |
| labels | Incoming session titled with the operator's name; outgoing retitled or archived | `mark --evidence` |
| pins-claude | Claude sidebar as in the table above | `mark --evidence` (passes by itself when no side is Claude) |
| pins-codex | Codex sidebar as in the table above | `mark --evidence` (passes by itself when no side is Codex) |
| models | The incoming session was created with the model and effort in `operator.conf` for its client | `mark --evidence` |
| switch-in | A move to the other model family has its switch-in audit recorded ([K-22](../kit/KIT.md)) | Incoming session (`lease.sh audit-done`) |
| ack | The incoming session ran `lane.sh ack KEY TOKEN` (from Codex, its thread id must match), or a note to the Oracle quotes the token | Incoming session |

In-app marks carry evidence: the app's own readback, or `gap: <why>` where
the app gives none ([client capabilities](client-capabilities.md)). The ACK
proves the note arrived, not that the app is set up. Each side's Oracle
manages its own app's titles and pins; the active Oracle runs the switch. A standby Oracle does only what the active one
asks of its own app, then confirms.

## Holds, pauses and switches

Every hold, pause or kill switch names an owner and an expiry
([K-07](../kit/KIT.md)); an expired one is not obeyed, and the nightly
hygiene check reports it.

| What | File | Set and clear |
| --- | --- | --- |
| Hold one operator (no relay, watchdog or doorbell) | `<state_dir>/holds/<key>` | `lane.sh hold KEY --owner WHO --until DATE --reason TEXT`; `lane.sh unhold KEY` |
| Pause the mailroom supervisor | `<state_dir>/mailroom-pause` | `lane.sh hold mailroom ...`; `lane.sh unhold mailroom` |
| Claude tier-1 kill switch (rings go to the bridge model) | `<bridge_dir>/claude/.watcher/t1-off` | create or remove it; `install.sh host` and `hygiene.sh` flag it while on |

## Reporting

- Times for people are in the owner's local timezone, with the date;
  convert UTC logs before quoting them ([K-12](../kit/KIT.md)).
- A claim names the mechanism and says whether it matches the agreed
  design ([K-10](../kit/KIT.md)); a delivery that went by a slower tier is
  a deviation the metrics show ([mailroom](mailroom.md#telemetry)).
- A rule derived from the human's words quotes them, dated, and is marked
  derived until the human confirms it ([K-32](../kit/KIT.md)).

## Clean as you go

The nightly `hygiene.sh` ([example hook](../examples/hooks/daily/30-hygiene))
lists what to clean: holds that expired or lack an owner, expiry or reason,
switches and routines open over a day, Codex threads marked unresponsive, the tier-1 kill switch left on, uncommitted work in any home,
an `AGENTS.md` over 8000 bytes, expired quiet-list rows, delivered logs to
rotate, and standing grants that differ from the client's permission
rules. For that last check, write the permission rule a grant needs in
backticks in the Scope cell of `MANDATE.md`'s standing grants table, for
example `` `Bash(sh ~/src/agent-operations/scripts/mailroom.sh:*)` ``.
Codex permission rules are not read yet.
