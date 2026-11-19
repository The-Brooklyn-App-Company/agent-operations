# Architecture

## What the kit is

Agent Operations is an operating kit for a person, or a team of up to about
five, who run coding agents across several repositories from their own
always-on machine. It is plain files: rules, docs, templates, thin skills
and POSIX sh scripts run by the OS scheduler. It is not a framework, a
daemon or an agent runtime, and it drives clients only through their own
documented command lines.

| Principle | Meaning |
| --- | --- |
| One home per rule | [K-14](../kit/KIT.md): each rule or fact lives in one place; everything else points to it |
| The repo is the state | [K-15](../kit/KIT.md): an operator can be resumed from its home repository alone |
| Roles, not vendors | The kit names capability roles; a [profile](profiles-and-integrations.md) maps them to the clients you have |
| Either client, any seat | The Oracle and every operator may run on Claude Code or Codex. Every harness claim carries a client, version and date, or says "unverified" |

## Roles

| Role | Who | Owns |
| --- | --- | --- |
| Human | The owner of an instance | All authority ([K-01](../kit/KIT.md)), product direction, consent |
| Oracle | One persistent session per person (generic word: orchestrator) | Cross-project priority, the backlog and journal, approvals, the schedule inventory, follow-through |
| Operator | One persistent session per outcome | Its mandate, its work repositories' queue, branches, review handling and release closeout |
| Cheap worker | A disposable headless run | One bounded read-only job; its answer goes to an inbox |
| Reviewer | A separate run, ideally from another model family | Findings on a neutral packet ([K-19](../kit/KIT.md)) |
| Maintainer | A human, in teams of two or more | The team repo and the kit pin ([Teams](#teams)) |

The human can talk to any operator directly; approvals still flow through
the Oracle ([K-08](../kit/KIT.md)). An operator's details, its home and how
it shares repositories are in [operators and repos](operators-and-repos.md).

## Three layers

| Layer | Where | Holds |
| --- | --- | --- |
| **Kit** (public) | A checkout pinned to a release tag | Rules with stable IDs, docs, templates, scripts, thin skills. No one's choices or identities |
| **Team** (private) | The team repo | The kit pin, `TEAM.md` (parameters, team rules, review bar, tracker and chat conventions), `PROJECTS.tsv`, team adapters |
| **Personal** (private) | The Oracle home, operator homes, the local profile | `KIT.local.md`, mandates, registry, backlog, journal, profile |

**Customize without forking.** Overlays hold deltas only: a parameter, an
added rule (`T-01` in the team layer, `P-01` in the personal layer) or
`override K-nn: <reason>`. The rules marked fixed in
[KIT.md](../kit/KIT.md) cannot be overridden.

**Upgrades flow kit, team, personal.** A tagged kit release; a pin-bump pull
request in the team repo, reviewed by rule ID against the
[changelog](../CHANGELOG.md); then each Oracle reconciles its own overlays.
A solo user skips the team step.

## Moving parts

| Part | What it does | Reference |
| --- | --- | --- |
| Tick | launchd or systemd runs `tick.sh` every 10 minutes: stall watchdog, period hooks, then the relay and the mailroom supervisor. Free unless there is mail | [Scheduling](hosts-and-ci.md#scheduling) |
| Inboxes and relay | Notes for a session are files in `inbox/<key>/`; `relay.sh` archives them and routes a pointer, or leaves them for the session to read | [scripts/README.md](../scripts/README.md#the-oracle-home) |
| Mailroom (experimental) | The relay routes, the in-app bridges deliver, a model-free supervisor keeps both bridges armed; a relay unit runs on every inbox change | [Mailroom](mailroom.md) |
| Recovery hook | `recover-context.sh`, a SessionStart hook: a capped digest after compaction | [Continuity](continuity.md#records) |
| Worker runner | `worker-run.sh` runs one cheap read-only job and routes its answer to an inbox unless it is exactly `NOTHING` | [Scheduled work](hosts-and-ci.md#scheduled-work) |
| Review runner | `review-run.sh` runs one boxed review pass on a neutral packet | [Review](review-and-release.md#review) |
| Cross-review | `cross-review.sh`, from an hourly hook, has the other model family review each operator weekly, and audits a move to the other family | [Cross-model accountability](review-and-release.md#cross-model-accountability) |
| Installer | `install.sh` creates homes, registry rows, worktrees, skill links and the tick unit | [Install](operators-and-repos.md#install-and-bootstrap) |
| Checks | `check.sh` (links, duplicate rule text, skill shape, privacy) and a weekly drift audit | [Drift](#drift-and-precedence) |
| Adapters | One small script per integration slot, so the free tick can poll and notify | [adapters/CONTRACT.md](../adapters/CONTRACT.md) |

**Mail is a notification, never authority.** Anything that can write an
inbox can put text in front of a model, so a relayed note starts nothing on
its own (K-01). The relay labels every message as automated and sends
pointers only. A direct Claude delivery is confirmed from the client's event
stream, never from the model's own words; a bridge's delivery is what the
bridge recorded, a weaker stage.

**Threat model.** All sessions run as one OS user. The kit's controls stop
confusion, stale state and injected text; they do not stop a hostile local
process running as that user.

## Drift and precedence

Kit rules beat mandates; mandates beat repository mechanics. `check.sh
kit` fails on dead links and on skills without a pointer into the docs,
and warns on rule-length text duplicated across the rules, docs and
skills; `check.sh home` fails a home whose `CLAUDE.md` does more than
import `AGENTS.md`, or a repository with two owners. An optional weekly cheap-worker
pass (`drift-check.sh`) reports contradictions between the rules,
mandates, repository instructions and schedules ([K-32](../kit/KIT.md)).

## Teams

A team of two or more names one **maintainer** and one **deputy** in
`TEAM.md` (`maintainer: alex`, `deputy: sam`, optional `away-until:`). Solo,
the person is the maintainer and this section does not apply.

| Question | Rule |
| --- | --- |
| Who owns the team repo? | The maintainer: merge rights and code owner on the kit pin, `TEAM.md` and `PROJECTS.tsv`. The deputy holds the same host rights at all times |
| Kit upgrades | The maintainer reads the changelog by rule ID and opens the pin-bump pull request; another member reviews. Each person's Oracle then applies it to their own instance |
| Shared conventions | Anyone proposes by pull request to `TEAM.md`; the maintainer approves after the affected people review. A team rule is `required` or `default`; only `default` rules may be overridden personally |
| Conflicts between people | Repository ownership, priority collisions, review deadlocks: the maintainer decides and records it in `TEAM.md`. If the maintainer is a party, the deputy decides; in a team of two that cannot agree, the status quo holds until both sign the pull request |
| Away | The deputy acts while `away-until` is set, or after the team's stated wait (default two working days) on a waiting pull request; for a security pin bump, immediately. With no third person to review, the deputy merges it marked `unreviewed` and the maintainer reviews on return |
| Limits | The maintainer never reads, writes or directs anyone's personal layer. Team rules bind only through `TEAM.md`. A maintainer's agents may prepare team-repo pull requests; approving them is the human's act |

Instances never share sessions ([K-18](../kit/KIT.md)): people meet on the
git host, the tracker and the team repo.

## Upgrading from 0.1.x

0.2 is a clean break. The 0.1.x material was guidance only, so nothing
installed needs undoing.

| 0.1.x | 0.2 |
| --- | --- |
| `START-HERE.md`, bootstrap prompt | [README quick start](../README.md#quick-start) and [install](operators-and-repos.md#install-and-bootstrap) |
| `VALIDATION.md` | The README's [what is proven](../README.md#what-is-proven) table |
| `docs/roles-and-context.md`, `team-collaboration.md`, `maintenance.md` | [kit/KIT.md](../kit/KIT.md) (the rules) and this page |
| `docs/delegation-review.md`, `releases.md`, `models.md` | [review and release](review-and-release.md) |
| `docs/scheduled-workers.md`, `host-lifecycle.md`, `self-hosted-ci.md` | [hosts and CI](hosts-and-ci.md) |
| JSON machine-local profile | The flat [profile](profiles-and-integrations.md) |
| Python helpers, worker fixture, `scheduled-worker` skill | The [scripts](../scripts/README.md) and their tests |
| `operator-handoff`, `worker-profile`, global and repo instruction templates | [templates/home/](../templates/home/) and [packets](../templates/packets/) |

To move: pin the 0.2 tag, run `scripts/install.sh --dry-run oracle <home>`
against your existing Oracle home (it creates only missing files), copy your
local rules into `KIT.local.md` as `P-nn` rules or `override K-nn` lines,
then re-point skills with `install.sh skills`.
