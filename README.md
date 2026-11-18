# Agent Operations

An operating kit for running coding agents across several repositories
from your own always-on machine: rules with stable IDs, short docs,
templates, thin skills, and POSIX sh scripts run by the OS scheduler. It
works with Claude Code and Codex in any seat. It is not a framework, a
daemon or an agent runtime.

Version 0.3.0 draft. [Changelog](CHANGELOG.md).

## Who it is for

A person, or a team of up to about five, who already use coding agents and
want them to behave like a small, accountable team:

- one persistent main session per person, the **Oracle**, that holds
  priorities, approvals and follow-through;
- one persistent **operator** per outcome, each with a home repository that
  holds everything needed to resume it;
- cheap disposable **workers** for polling, and an independent
  **reviewer** from another model family;
- a free scheduled **tick** that notices stalls and delivers notes, so no
  expensive session ever polls.

## Three layers

| Layer | Holds |
| --- | --- |
| **Kit** (this repository, public) | [The rules](kit/KIT.md) (`K-01`...), [docs](docs/), [templates](templates/), [scripts](scripts/), [skills](skills/). No one's choices or identities |
| **Team** (private repository) | The kit pin, `TEAM.md`, `PROJECTS.tsv`, team adapters ([templates](templates/team/)) |
| **Personal** (private) | The Oracle home, operator homes, the machine's profile |

Overlays hold deltas only: a parameter, an added rule, or
`override K-nn: reason`. A few rules are fixed. See
[architecture](docs/architecture.md).

## Defaults worth knowing

- **Claim only what is proven** ([K-10](kit/KIT.md)): requested, received,
  working, returned, merged, deployed, accepted.
- **Approvals go through the Oracle** ([K-08](kit/KIT.md)); money, trades,
  sending as you, deletes and force-pushes are never relayed
  ([K-03](kit/KIT.md)).
- **Cross-model accountability, on by default** ([K-22](kit/KIT.md)):
  every week the other model family reviews each operator's last seven
  days (commits, notes, mandate, leftovers), and an operator that moves to
  the other family gets a switch-in audit by the incoming family, which its
  session triages and records before new work. Findings go to the
  operator; a digest goes to the Oracle.
- **Mail is a notification, never authority.** The relay tells a session
  where its new notes are; it never puts note text in front of a model.
- **No AI attribution** in commits or messages unless you turn it on.

## Quick start

Prerequisites: macOS (Linux is untested), git, `jq`, and Claude Code
and/or Codex signed in.

```sh
git clone <kit-url> ~/src/agent-operations
cd ~/src/agent-operations && git checkout <reviewed-release-tag>
scripts/install.sh --dry-run oracle ~/ops/oracle    # lists every file
scripts/install.sh oracle ~/ops/oracle              # creates and commits
$EDITOR ~/.config/agent-operations/profile          # replace every CHANGE-ME
scripts/install.sh operator web --owns git@git.example.com:me/app.git
scripts/check.sh home ~/ops/oracle ~/ops/web && scripts/status.sh
scripts/install.sh timers                           # prints the load command
```

Then start and name a session in each home, and apply each home's
`settings/` pattern in your client yourself. The full walkthrough is
[install and bootstrap](docs/operators-and-repos.md#install-and-bootstrap);
a worked example is [two operators](examples/two-operators/README.md).

Start-to-finish setup: [MANUAL.md](MANUAL.md).

## Reading order

1. [kit/KIT.md](kit/KIT.md): the rules, about ten minutes.
2. [docs/architecture.md](docs/architecture.md): roles, layers, moving
   parts, teams, upgrading from 0.1.x.
3. [docs/operators-and-repos.md](docs/operators-and-repos.md): homes,
   shared repositories, install, backup.
4. As needed: [profiles and integrations](docs/profiles-and-integrations.md),
   [review and release](docs/review-and-release.md),
   [hosts and CI](docs/hosts-and-ci.md),
   [continuity](docs/continuity.md), and the
   [scripts reference](scripts/README.md).

## What is proven

Highest stage reached for each piece, with the client, version and date.
"Fakes" means the test suite's stand-in CLIs: no network, no model.

| Piece | Status | Evidence |
| --- | --- | --- |
| Test suite | Passes under bash's `sh` and dash, macOS | `tests/run.sh`, 2026-11-17 |
| `tick.sh --dry-run`, `status.sh` against a real registry | Proven, macOS | 2026-11-17 |
| Relay to a named Claude Code desktop session | Proven, macOS, Claude Code 2.1.322 | Pointer delivered and confirmed from the event stream, 2026-11-17; recorded stream in `tests/fixtures/` |
| `worker-run.sh` on Codex (`NOTHING`, a note, a failure note) | Proven, codex-cli 0.169 | 2026-11-17 |
| `review-run.sh` on Codex | Proven, codex-cli 0.169 | Toy diff, 2026-11-17 |
| Claude `--restricted` delivery run with only `ListAgents`, `SendMessage` | Proven, Claude Code 2.1.322 | 2026-11-17 |
| `worker-run.sh` and `review-run.sh` on Claude | Fakes only | |
| `cross-review.sh` | Switch-in report by a real Codex reviewer, sandboxed; weekly review: fakes only | codex-cli 0.169.0-alpha.11, 2026-11-17 |
| `install.sh` | Sandbox: fresh empty home, oracle + operator + check + status + timers render | 2026-11-17; not yet a separate clean machine |
| `install.sh sync`, `status.sh --drift` | Fakes only (test suite); not yet run against a real two-client setup | |
| launchd unit | Rendered by `install.sh`; loading it is your step | |
| systemd units, Linux hosts | **Untested** | |
| Codex relay delivery | Native CLI queue transport; acceptance is not receiver execution | New routing tests and live deployment acceptance tracked in [TESTING.md](TESTING.md) |
| **Experimental:** lease, standby redirect, forward, cold takeover, asks ledger ([handoff](docs/handoff.md)) | Test suite; sandboxed end-to-end with both real CLIs, headless, `file-only` registry (validation table in [handoff](docs/handoff.md#per-client-validation)) | Claude Code 2.1.322, codex-cli 0.169.0-alpha.11, 2026-11-17. **Not yet** the live test on a real operator ([TESTING.md](TESTING.md)) |
| **Experimental:** switch-in audit gate (`audit=pending` until `lease.sh audit-done` records the committed report) | Lease path end-to-end in the sandbox above, report by a real reviewer; registry path: fakes only | 2026-11-17 |
| **Experimental:** human takeover, `settle`, `unlock` on a terminal | Driven through a pseudo-terminal (`script(1)`) only; a human at a real terminal and the clients' interactive permission prompts are **unverified** | |
| **Experimental:** doorbells | See opt-in transport settings and limitations in [handoff](docs/handoff.md); live acceptance remains separately required | |
| `examples/tracker-linear` | **Untested** sketch | |

## Repository layout

```
kit/KIT.md      the rules, stable IDs
docs/           six guides
templates/      home/, oracle/, team/, packets/
profiles/       claude-only, codex-only, both, custom
scripts/        install, tick, relay, worker-run, review-run, cross-review,
                status, inbox-put, check, drift-check, lib/, units/
adapters/       CONTRACT.md, none.sh, git-gh.sh
skills/         operator-setup, review-handoff, release-closeout,
                return-to-desk, model-bakeoff
examples/       two-operators/, tracker-linear/, security-auto-ship.md, hooks/
tests/          sh test suite with fake agent CLIs
```

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). [MIT](LICENSE). Client products and
linked sources keep their own terms.
