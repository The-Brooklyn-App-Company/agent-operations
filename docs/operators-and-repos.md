# Operators and repositories

An **operator** is exactly one home plus a declared list of work
repositories ([K-13](../kit/KIT.md)). The home is its identity and memory;
the work repositories are where it changes code.

## The operator home

Every operator's home has the same layout. `install.sh operator` creates it
from [templates/home/](../templates/home/).

```
<home>/
  AGENTS.md        canonical instructions: recovery list, kit pin, pointers
  CLAUDE.md        one line: @AGENTS.md
  MANDATE.md       scope, finish line, standing grants (dated)
  NOTES.md         dated working memory
  operator.conf    key, session names, work repos and roles
  settings/        per-client permission patterns (placeholders you fill in)
  .operator/       git-ignored, machine-local
```

`AGENTS.md` is canonical for both clients; `CLAUDE.md` only imports it, and
`check.sh home` fails a kit-managed home where it does anything else. Work
repositories may adopt the same convention by choice. Client-specific
permission text lives in `settings/`, which the human applies by hand: the
kit never edits client settings.

A home is normally its own private repository. A small setup may embed it
as a folder in the Oracle's home (`install.sh operator <key> --embedded`);
it then moves and backs up with the Oracle. Either way there is one home per
operator and one checkout of it per machine.

`ASKS.md`, `HANDOFF.md` and the `.operator/` lease and mailbox belong to
the experimental [handoff layer](handoff.md) (0.2.1), and `audits/` holds
switch-in audit reports ([K-22](../kit/KIT.md)).

### operator.conf

Flat `key=value`, parsed literally and never sourced:

```
key=workshop
session.claude=[OPS] Workshop
session.codex=ops-workshop
work.app-web=git@git.example.com:org/app-web.git|owner
work.infra=git@git.example.com:org/infra.git|contributor
```

`key` is the operator's stable ID (`[A-Za-z0-9._-]`), used for its inbox,
registry row, worktree folder and branch prefix. `session.<client>` is the
display name of its session on each client. Each `work.<name>` line is a
remote URL and this operator's role in it, `owner` or `contributor`.

## The Oracle's home

The Oracle's home has the same layout, plus the records it owns. It declares
no work repositories by default: it delegates. It is the only approval
endpoint ([K-08](../kit/KIT.md)), and its `MANDATE.md` is the charter of the
whole instance.

| File | Holds |
| --- | --- |
| `operators/REGISTRY.tsv` | One row per session the scripts know about ([format](../scripts/README.md#the-oracle-home)) |
| `SCHEDULES.md` | Every timed job ([K-24](../kit/KIT.md)) |
| `BACKLOG.md`, `JOURNAL.md`, `FACTS.md` | The [continuity records](continuity.md) |
| `KIT.local.md` | The kit pin and personal overlay rules (`P-nn`, `override K-nn`) |
| `inbox/` | Notes waiting for sessions; git-ignored |
| `hooks/` | Tick hooks, if any |
| `operators/<key>/` | Embedded operator homes |

The 0.2.0 registry row is
`key  name  home  session  [client]`, tab-separated: the session's display
name (what the relay addresses), the operator's home (where its session is
started, so its transcript can be found), a session id or `pending`, and
the client. An operator with a lease (experimental,
[handoff](handoff.md)) is routed to the lease's holder instead of the
session column.

## Shared work repositories

Each work repository has exactly one merge owner and any number of
contributors ([K-16](../kit/KIT.md), [K-17](../kit/KIT.md)).

| Question | Practice |
| --- | --- |
| Where does the owner work? | The primary checkout, `<work_root>/<repo>`. It alone updates the default branch, and it serializes merges |
| Where do contributors work? | A scoped repo-local seat, `<repo>/worktrees.noindex/<task-slug>`, on branches `<key>/<topic>` |
| Who reviews? | The reviewer role on a neutral packet, never the author. Across people: the reviewer named in `PROJECTS.tsv` |
| How does work reach the owner? | A pull request with the handoff section of the [delegation packet](../templates/packets/delegation.md) filled in. With no git host: the branch plus an inbox note, within one instance only; work that crosses people needs a git host |
| Who resolves conflicts? | The branch author rebases or merges forward; the owner never edits a contributor's branch |
| Avoiding collisions | One backlog or tracker item has one operator |
| What enforces it? | Between people: the git host (protected default branch, required review). Within one person, whose operators share a credential: convention and the drift audit. A bot credential per operator is the only hard boundary, and it is optional |

**Who is authoritative.** Repositories are identified by their remote URL.
The team's `PROJECTS.tsv` names the owning person and operator; each
`operator.conf` declares local participation; the registry locates homes;
the profile selects clients. Solo, exactly one local operator owns each
repository. In a team, one does if `PROJECTS.tsv` names this person, and
none otherwise.

```
# <team-repo>/PROJECTS.tsv
repo                        owner_person  owner_operator  reviewer  tracker_project
git.example.com/org/app-web alex          workshop        sam       WEB
```

## Install and bootstrap

1. Prerequisites: git, at least one signed-in client (two model families if
   you have them), an always-on machine. `jq` for Claude relay delivery.
2. Clone the kit and check out a release tag. Run
   `scripts/install.sh --dry-run oracle <home>`: it lists every file it
   would create.
3. `scripts/install.sh oracle <home> [--team <team-repo>]` creates the
   Oracle home, records the kit pin, copies a profile example outside git
   (default `~/.config/agent-operations/profile`) and commits.
4. Edit the profile: replace every `CHANGE-ME`. If a client needs a token,
   put it in the OS secret store yourself and name it in the profile.
5. Start a session in the home by hand and give it the name in the
   registry. Its first turn reads `AGENTS.md`.
6. For each operator:
   `scripts/install.sh operator <key> [--embedded] [--owns <url>]... [--contributes <url>]...`.
   It creates the home, the registry row and contributor worktrees for
   repositories already cloned, and prints the `git clone` lines for the
   rest and the session to start.
7. Apply each `settings/` pattern to your clients yourself.
8. Run `scripts/check.sh home <home>...` and `scripts/status.sh`, then
   `scripts/install.sh timers` and load the unit with the command it prints.
   Accept the setup: a test note reaches a session; an idle operator trips
   the watchdog; `review-run.sh` completes on a toy diff.
9. Run one real task through implement, review, merge and journal.

A second team member runs the same steps with `--team`. Pair acceptance is
one pull request each, reviewed and merged by the other through the git
host.

## Backup and moving machines

Back up three things: each home repository (a private remote, or local git
plus a machine backup); the profile, which lives outside git; and unmerged
work, which operators push to the work repository's remote at the end of
each working turn.

To restore, bring back the profile, then the Oracle home (it carries the
kit pin), then each operator home, and rerun `install.sh oracle` and
`install.sh operator` against them: they create only what is missing. Not
restored, by design: inbox contents and chat history. Two machines must
never run the same operator at once; stop the old host's timers and
sessions before starting the new one ([switching hosts](hosts-and-ci.md#switching-hosts)).

## Two-client operating walkthrough

See [the setup manual](../MANUAL.md) for verified roots, active-client routing,
deterministic watchers, backup-safe worktrees and cleanup custody. Existing
managed worktrees and documented live runtime exceptions are preserved.
