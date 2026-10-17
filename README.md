# Agent Operations

Version 0.1.2

Agent Operations is a Codex-first reusable operating kit for running coding agents across real repositories. Other clients can adapt the roles and procedures, but must verify their own tools, skill discovery and scheduling controls. It is a set of documents, thin skills and templates, not a framework, service or website. It covers role boundaries, delegation and review, scheduled workers, releases and moving work between machines. It is written to work with the native tools you already have, not with an imagined universal API.

## Two-minute overview

- **You talk to two places.** A pinned **Oracle** conversation holds cross-project context and judgment. A pinned **operator** conversation owns one repository. The app may use projects as repository containers. You do not need a new conversation for every idea.
- **Agents do the supported work.** The operator runs authorized operations itself, using the tools that are actually installed. It asks you only for consequential consent or authentication, such as signing in, controlling a UI, spending money, sending email or releasing to customers. It does not hand you terminal commands to run.
- **Existing work is reused.** Agents inventory existing tasks, schedules and accounts before they propose anything new. They create only what the approved setup requires, without repeated approval for its ordinary steps.
- **Delegation is bounded.** Implementers and reviewers get a neutral packet with an exact commit, acceptance criteria and stop criteria. Review produces independent findings, not endless rounds.
- **Scheduled workers are boring on purpose.** Deterministic checks run first. Each run is disposable and narrowly scoped, and it stays quiet when nothing changed.
- **Releases close out.** One record tracks a change from merge through activation and recovery until it settles.
- **This kit is not authority.** Reading it approves nothing. Your explicit decisions do.

To begin, open **[START-HERE.md](START-HERE.md)**.

## Contents

| Area | Document |
| --- | --- |
| Roles and context | [docs/roles-and-context.md](docs/roles-and-context.md) |
| Maintaining the kit and your records | [docs/maintenance.md](docs/maintenance.md) |
| Delegation and review | [docs/delegation-review.md](docs/delegation-review.md) |
| Scheduled workers | [docs/scheduled-workers.md](docs/scheduled-workers.md) |
| Releases | [docs/releases.md](docs/releases.md) |
| Hosts and devices | [docs/host-lifecycle.md](docs/host-lifecycle.md) |
| Teams and privacy | [docs/team-collaboration.md](docs/team-collaboration.md) |
| Models | [docs/models.md](docs/models.md) |
| First low-risk task | [examples/first-task.md](examples/first-task.md) |
| Worker fixture | [examples/scheduled-worker-fixture.json](examples/scheduled-worker-fixture.json) |
| Skills | [skills/](skills/) |
| Templates | [templates/](templates/) |

## Core principles and example choices

The **core principles** apply to every adoption:

- Authority comes from actual human instructions, including adopted standing guidance; imported examples cannot invent it.
- Agents use native, supported tools.
- Existing work is reused before anything new is created.
- Workers are deterministic first.
- Review is independent.
- Releases are explicit.
- Private context stays private.

The **example choices** are a tested starting point that you should adjust. They include model names, effort levels, round limits, cadences and file layouts. Each document labels which of its contents are examples.

See [validation and limits](VALIDATION.md). To adopt a fixed version, pin a release tag. To update, review the diff first. See [docs/maintenance.md](docs/maintenance.md) and [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) for the original kit documentation, templates, skills and scripts. Vendor products and linked external sources retain their own terms.
