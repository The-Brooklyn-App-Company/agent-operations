# Example: one person, two operators

Juniper runs a small product: a web app and its infrastructure. Every name
here is fictional.

| Session | Client | Home | Owns | Contributes to |
| --- | --- | --- | --- | --- |
| Oracle | Claude Code | `~/ops/oracle` | nothing (delegates) | |
| `[OPS] Web` (`web`) | Claude Code | `~/ops/web` | `app-web` | `infra` |
| `[OPS] Infra` (`infra`) | Codex | `~/ops/oracle/operators/infra` (embedded) | `infra` | |

## Setup

```sh
git clone <kit-url> ~/src/agent-operations && cd ~/src/agent-operations
git checkout v0.2.0
scripts/install.sh --dry-run oracle ~/ops/oracle
scripts/install.sh oracle ~/ops/oracle
$EDITOR ~/.config/agent-operations/profile      # from profiles/both.profile
scripts/install.sh operator web --name "[OPS] Web" --client claude \
  --owns git@git.example.com:juniper/app-web.git \
  --contributes git@git.example.com:juniper/infra.git
scripts/install.sh operator infra --embedded --name "[OPS] Infra" --client codex \
  --owns git@git.example.com:juniper/infra.git
scripts/check.sh home ~/ops/oracle ~/ops/web ~/ops/oracle/operators/infra
scripts/install.sh timers
```

## What exists afterwards

`~/ops/oracle/operators/REGISTRY.tsv`:

```
# key	name	home	session	client
oracle	Oracle	~/ops/oracle	pending	claude
web	[OPS] Web	~/ops/web	pending	claude
infra	[OPS] Infra	~/ops/oracle/operators/infra	pending	codex
```

Juniper replaces `pending` with each session's id once the sessions are
started and named; until then the watchdog skips them.

`~/ops/web/operator.conf`:

```
key=web
session.claude=[OPS] Web
work.app-web=git@git.example.com:juniper/app-web.git|owner
work.infra=git@git.example.com:juniper/infra.git|contributor
```

Checkouts: `~/src/app-web` (web is its merge owner), `~/src/infra` (infra
is its merge owner), and web's contributor worktree
`~/src/.worktrees/web/infra` on the branch `web/main`.

## A week in this setup

- Web needs a new environment variable in `infra`. It commits it on
  `web/env-var` in its worktree and opens a pull request with the handoff
  section filled in. Infra, the merge owner, reviews and merges it (K-16).
- Web wants to run a production migration. It sends the Oracle one ask
  with the target, revision, risk and rollback; Juniper says yes in the
  Oracle's thread; the Oracle relays Juniper's exact words (K-08).
- The tick notices Infra has been idle for four hours in work hours and
  leaves the Oracle a note; the Oracle checks and finds it waiting on a CI
  run, and adds it to the quiet list until tomorrow.
- On Friday the cross-review runs: Codex reviews Web's week and Claude
  reviews Infra's (K-22). Web gets two findings, a dead feature flag and an
  abandoned branch, and triages both the same day. The Oracle gets one
  digest.
- Juniper moves Infra from Codex to Claude for a week. Within the hour the
  cross-review runs a switch-in audit: Claude audits what Codex left, the
  report lands in Infra's `audits/`, and Infra triages it and records it
  (`lease.sh audit-done`) before it takes new work.
