# Scripts

The kit's moving parts: a scheduled **tick**, an inbox **relay**, safe
model **runners**, a weekly **cross-review**, a **status** view,
deterministic **checks** and an **installer**. Plain POSIX sh run by the OS
scheduler: no daemon, no database, no listener. Every script prints its own
help with `--help`; that header is the reference for its usage, environment
and exit codes.

| Script | Job |
| --- | --- |
| `bootstrap.sh` | The guided first run: the Oracle on the client you start with, the always-on host, a toehold in the other client, then a checklist of the few in-app steps, each with its check ([first run](../docs/hosts-and-ci.md#first-run)) |
| `operator.sh` | The operator routines as guided scripts with verifiers: `create` (models for both clients decided at creation), `archive` (worktrees to verified local bundles), `model` (the owner-only model change), `session`, `recover` (an unresponsive Codex thread), `verify`, `mark` ([conventions](../docs/conventions.md#operator-routines)) |
| `install.sh` | Create the Oracle home, operator homes, mailroom bridge homes, skill links and the tick and relay units; `host [--apply]` sets up an always-on host, turnkey (check then set, units loaded, bridge homes, then the in-app steps); `sync <client>` brings every home up to date for a second client; `--dry-run` lists everything first |
| `lane.sh` | Switch an operator between clients as a scripted checklist with a verifier (`switch`, `verify`, `mark`, `ack`); `side` for the parked-side guard; `check`; holds with an owner, expiry and reason; the Oracle lock ([conventions](../docs/conventions.md)) |
| `hygiene.sh` | The nightly, model-free hygiene check: expired holds, open switches and routines, unresponsive threads, uncommitted work, budgets, standing grants against permission rules |
| `tick.sh` | Scheduled heartbeat: stall watchdog, period hooks, then the relay and the mailroom supervisor |
| `relay.sh` | Move new inbox notes to the archive and route a pointer, never the note text: a ring for the app's bridge, or a direct delivery |
| `mailroom.sh` | **Experimental.** The [mailroom](../docs/mailroom.md): `cycle` (relay unit), `supervise` (timed tiers, unknown-send reconciliation, thread recovery, re-arms, fingerprint and canaries, degradation alarms, tier 4), `wait` and `file` (Claude bridge), `arm-codex` (Codex bridge), `status`, `metrics` (tier shares, p50/p90) |
| `mailroom-wait.py`, `mailroom-codex-watcher.cjs` | **Experimental.** The tier-1 watchers: kqueue for Claude (opt-in model-free socket send to warm sessions); the Codex app's own tool server for Codex (native send; queue on the target's turn-complete event) |
| `recover-context.sh` | SessionStart hook on either client: a recovery digest capped at 8 KB, with the operator's bounded current-state block ([client capabilities](../docs/client-capabilities.md#recovery-on-both-clients)) |
| `worker-run.sh` | One cheap read-only worker job; result to an inbox unless `NOTHING` |
| `review-run.sh` | One independent review pass by a reviewer role |
| `cross-review.sh` | Weekly review of every operator by the other model family (from `OP_PROVIDER`), and the switch-in audit report after a move to the other family ([K-22](../kit/KIT.md), [handoff](../docs/handoff.md#switch-in-audit)) |
| `status.sh` | One line per operator: activity, quiet list, inbox depth, switch-in audit; profile warnings; `--drift` reports mismatches between the clients with their fixes |
| `inbox-put.sh` | Atomic note into an inbox, for hooks and adapters |
| `jobs.sh` | Validate explicit schedule snapshots and plan safe owning-side job cutovers; no scheduler apply |
| `worktree.sh` | Create a scoped repo-local worktree after verified macOS churn exclusions; see `--help` |
| `pr-watch.sh` | Deterministic change-only PR snapshots into the owning inbox; see `--help` |
| `check.sh` | Links, duplicate rule text, skill shape, home layout, privacy scan, host settings (App Nap, launchd priority) |
| `drift-check.sh` | Weekly audit: `check.sh dupes` plus a worker pass with `drift-prompt.md` |
| `lease.sh` | **Experimental.** Advisory lease per operator: holder, standby, takeover ([handoff](../docs/handoff.md)) |
| `mail.sh` | **Experimental.** File mailboxes in each home; `ring-all` for a tick hook |
| `doorbell-claude.sh`, `doorbell-codex.sh` | **Experimental.** "You have mail", never the mail; a mailroom ring when the mailroom is on |
| `ask.sh` | **Experimental.** Asks and the approvals ledger, bound to the lease |
| `units/` | launchd (macOS) and systemd (Linux, untested) templates for the tick and the relay unit |
| `lib/` | Shared code: `core.sh`, `registry.sh`, `vendor.sh`, `mailroom.sh`, `guide.sh` (the guided scripts), one `vendor-<client>.sh` per harness |

## Quickstart

Normally `install.sh` does steps 1 and 2; see
[install and bootstrap](../docs/operators-and-repos.md#install-and-bootstrap).

1. Copy one of `../profiles/*.profile` to `~/.config/agent-operations/profile`
   (or anywhere, and set `AO_PROFILE`). Keep it out of git. Set
   `oracle_home` and replace every `CHANGE-ME`.
2. In the Oracle home, create `operators/REGISTRY.tsv` (below) with a row
   for the Oracle and each operator.
3. Check it: `scripts/status.sh`, then `scripts/tick.sh --dry-run`.
4. Drop a test note: `echo hello | scripts/inbox-put.sh <key> test`, then
   `scripts/relay.sh` and confirm the session got the pointer.
5. Install the tick unit: `scripts/install.sh timers`.

## The Oracle home

Paths are relative to `oracle_home` unless absolute; every one is a profile
key.

| Path (default) | Key | What |
| --- | --- | --- |
| `operators/REGISTRY.tsv` | `registry` | One row per session |
| `operators/WATCHDOG-QUIET.tsv` | `quiet_list` | Dated watchdog exemptions |
| `inbox/<key>/*.md` | `inbox_dir` | New notes waiting for a session; `.claimed/` holds notes being archived (an atomic rename, so a later note under the same name is untouched); `.relay-pending` lists archived notes whose pointer is not yet confirmed |
| `inbox/sent/` | `sent_dir` | Archived notes, `<stamp>-<key>-<name>.md`; must be on a filesystem with hard links |
| `inbox/.mailroom/{claude,codex}/` | `bridge_dir` | Experimental [mailroom](../docs/mailroom.md) rings, their `delivered/` folder and log, and the watchers' `.watcher/` state |
| `hooks/{every,hourly,daily,weekly}/` | `hooks_dir` | Tick hooks; optional `hooks/gate` |
| `~/.local/state/agent-operations/` | `state_dir` | Logs, stamps, locks, backoff, cross-review state and registry switch-in audit records (`audit/`) (machine-local; keep out of git and backups) |

**Registry** (tab-separated; `#` comments; no empty fields, use `-`):

```
# key	name	home	session	[client]
oracle	Oracle	~/ops/oracle	<session-id>
web	Web	~/ops/web	<session-id>	claude
infra	Infra	~/ops/infra	pending	codex
```

`key` names the inbox folder (`[A-Za-z0-9._-]`; not the name of the sent
folder). `name` is the session's display name, which the Claude transport
addresses. `home` is the operator's home, where its session runs, so its
transcript can be found. `session` is the session id (a desktop app's own
id works too: activity then falls back to the newest transcript for that
directory), or `pending`; pending rows are skipped by the watchdog.
`client` picks the transport, the activity source and the cross-review
family (`claude`, `codex`, `custom`, `file-only`); empty means
`relay_default`.

The keys `mailroom-claude` and `mailroom-codex` are reserved for the
[mailroom](../docs/mailroom.md) bridges (`install.sh bridge`): the relay,
the watchdog and cross-review skip them, and the mailroom reads their ids
from here.

**Quiet list** (tab-separated): `key-or-name<TAB>YYYY-MM-DD<TAB>reason`.
The watchdog skips the operator through that date, inclusive; expired rows
are ignored.

**Inbox notes** must appear atomically: write elsewhere and `mv`, or use
`inbox-put.sh`. The relay only reads regular `*.md` files and ignores
dotfiles, directories and dangling links.

## Profile

One flat `key=value` file per machine: roles, models, paths, hours and
integration slots. Lines starting with `#` are comments; blank lines are
ignored; later lines win. Values are literal (no variables, no command
substitution, one pair of surrounding quotes stripped); a leading `~/`
expands in path keys and commands. The file is parsed, never sourced, and
it is the only source of profile values: the environment cannot set them.
Unknown keys warn; keys starting with `x_` are free for local hooks.

| Key | Default | Meaning |
| --- | --- | --- |
| `oracle_home` | required | The Oracle's private home repo |
| `oracle_key` | `oracle` | Registry key of the Oracle; alerts and failures go to its inbox |
| `registry`, `quiet_list`, `inbox_dir`, `sent_dir`, `state_dir`, `hooks_dir` | see above | Paths |
| `work_root` | `~/src` | Where work repositories are checked out (`install.sh`, `cross-review.sh`) |
| `path` | inherited | `PATH` for scheduled runs, which start with a minimal one |
| `watchdog_days` | `1-5` | Work days: `all`, or a comma list of `N` / `N-M` (1 = Monday) |
| `watchdog_hours` | `09-19` | Work hours: `all`, or `HH-HH` (end exclusive; may wrap midnight, e.g. `22-06`) |
| `watchdog_idle_min` | `180` | Idle minutes before an alert; `0` disables the watchdog |
| `watchdog_realert_min` | `180` | Minimum minutes between alerts for one operator, and between failure notes for one hook |
| `daily_hour` | `6` | Daily hooks run from this hour |
| `weekly_day`, `weekly_hour` | `5`, `6` | Weekly hooks and cross-reviews run from this day and hour, catching up later that ISO week |
| `hook_timeout` | `900` | Seconds per hook |
| `relay_default` | `claude` | Client for registry rows without one (`codex` in the Codex-only profile) |
| `relay_codex` | `queue` | Codex rows queue pointers to actual owner thread IDs (one isolated live round trip observed; evidence below); `off` leaves inbox, claimed and pending state untouched. Independent of `doorbell_codex` |
| `relay_label` | `Relay (automated inbox, not from the human):` | First line of every relayed message |
| `relay_max_attempts` | `3` | Failed deliveries in a row before the row backs off and the Oracle is told |
| `relay_workdir` | `oracle_home` | Working directory for delivery runs |
| `review_family` | `cross` | `cross`, `same-family` or `single-model`; printed by `review-run.sh` for the release record |
| `cross_review` | `on` | `on` or `off`: the weekly cross-family review ([K-22](../kit/KIT.md)) |
| `cross_review_per_run`, `cross_review_timeout`, `cross_review_days` | `1`, `600`, `7` | Operators reviewed per run, seconds per review, days of history |
| `drift_rules`, `drift_files`, `drift_repo_files`, `drift_min_words`, `drift_prompt`, `drift_prompt_extra`, `drift_workdir`, `drift_to` | see `drift-check.sh --help` | Drift audit inputs |
| `secrets` | `os` | Secrets slot: `os` (macOS keychain; libsecret on Linux), `none`, or an adapter path called as `<adapter> get <name>` |
| `tracker`, `chat`, `githost`, `ci` | `none` | Integration slots, recorded for agents and adapters; the scripts do not read them yet |
| `attribution` | `none` | AI attribution in commits: `none` or `disclose`; read by agents, not scripts |
| `lease_stale`, `doorbell_codex`, `doorbell_rering_min` | `4h`, `off`, `60` | Experimental lease layer (see [handoff](../docs/handoff.md)) |
| `relay_bridge` | `on` | Experimental [mailroom](../docs/mailroom.md): `on` rings the in-app bridges for claude and codex rows with a session id, with the transports as timed fallbacks; `off` delivers through the transports directly |
| `bridge_dir` | `<inbox_dir>/.mailroom` | Ring folders |
| `bridge_codex_node`, `bridge_codex_server` | none | The node binary and the `codex-app-tools/server.mjs` bundled in the Codex desktop app, for `mailroom.sh arm-codex` |
| `bridge_claude_t1` | `off` | `socket`: the Claude watcher delivers to warm sessions model-free (tier 1; undocumented client interface, see the mailroom doc); `off`: the bridge model sends every ring |
| `owner_tz` | none | The owner's timezone (for example `Europe/Paris`), set by `bootstrap.sh`: times for people are reported in it; logs stay UTC ([K-12](../kit/KIT.md)) |
| `archive_dir` | `<oracle_home>/../archive` | Where `operator.sh archive` keeps an archived operator's verified local git bundles |
| `wake_link` | none | The desktop app's link to a session, with `{session}` where the id goes, for the supervisor's deep-link warm-up; the kit ships no default |
| `host_apps` | `com.anthropic.claudefordesktop com.openai.codex` | Desktop apps whose App Nap `install.sh host` turns off and `check.sh host` checks; `none` skips |
| `host_latency_jobs` | `*agent-operations*` | launchd label globs that must not run as Background (`check.sh host`); add your schedulers, watchers, alert routes and CI forwarders |
| `host_launchd_dirs` | `~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons` | Folders `check.sh host` scans |

**Roles.** Each role is a prefix:

| Prefix | Used by |
| --- | --- |
| `worker` | `worker-run.sh`, `drift-check.sh` |
| `reviewer` | `review-run.sh`, and cross-review for rows on other clients |
| `reviewer_claude`, `reviewer_codex` | Per-family reviewers (client fixed by the name): `cross-review.sh` reviews Claude operators with `reviewer_codex` and Codex operators with `reviewer_claude`; a family counts as configured when its `_model` is set |
| `implementer_claude`, `implementer_codex` | Per-seat implementer preferences, read by agents when they delegate; the scripts do not run them |
| `relay_claude`, `relay_codex`, `relay_custom` | Relay transports (client fixed by the name): direct delivery with `relay_bridge=off`, and the mailroom's fallbacks and re-arms otherwise; Codex relay defaults to `relay_codex=queue`; `off` makes it passive. The Codex doorbell uses these settings with its separate opt-in; its live path remains unrun |

Every role takes the same fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `<role>_client` | `none` | `claude`, `codex`, `custom` or `none` (fixed for the per-client prefixes) |
| `<role>_cmd` | the client name | Executable on `PATH`, or a path; required for `custom` |
| `<role>_model` | client default | Model id. Set it: an empty model silently uses the client's default |
| `<role>_effort` | client default | Reasoning effort (codex) |
| `<role>_timeout` | `600` | Hard limit in seconds; `0` = none |
| `<role>_mcp_disable` | none | Extra tool servers to switch off (codex); every server the Codex configuration lists is switched off anyway |
| `<role>_tools` | runs: `Read,Grep,Glob`; delivery: `ListAgents,SendMessage` | Claude built-in tool allow-list. Runs accept only a subset of `Read,Grep,Glob`; for delivery, `default` = the client's full set |
| `<role>_max_turns` | client default | Claude turn cap |
| `<role>_disallowed_tools` | none | Claude deny-list, added on top |
| `<role>_token_secret` | none | Secret name, fetched through `secrets` for this role only |
| `<role>_token_env` | `CLAUDE_CODE_OAUTH_TOKEN` for claude | Variable that receives it, in the client process only |

A missing role is never substituted: `worker-run.sh` leaves one note in the
Oracle's inbox and exits 4; `drift-check.sh` falls back to its deterministic
part; `cross-review.sh` falls back to the same family, marks the result
`same-family`, and `status.sh` warns. Other fallbacks, such as same-family
review for releases, are explicit profile choices.

## Clients

Each harness is one file, `lib/vendor-<client>.sh`, implementing `run`,
`deliver` (optional) and `activity` (contract in `lib/vendor.sh`). Scripts
only call the role interface, so adding a harness touches nothing else.

| Client | run | deliver | activity |
| --- | --- | --- | --- |
| `claude` | `claude -p --restricted`, no session persistence, read-only tools, no tool servers or hooks | Headless run with only `ListAgents` and `SendMessage` calls `SendMessage` once; confirmed from the event stream with `jq` (below) | `<session>.jsonl` under `$CLAUDE_CONFIG_DIR/projects/<dir-slug>/`, else the newest transcript there |
| `codex` | `codex exec --ephemeral -s read-only`, every configured tool server off | Default `relay_codex=queue` (set `off` for passive pickup): `codex queue --thread <actual-session-id> --message <pointer> --resume`. One isolated live round trip observed; no guaranteed resume (evidence below) | Newest `$CODEX_HOME/sessions/**/*<session>*.jsonl` |
| `custom` | `<cmd> run <workdir> <prompt> <out>` | `<cmd> deliver <name> <session> <message> <relay-id>` | `<cmd> activity <dir> <session>` (optional) |
| `file-only` | n/a | Nothing: the session reads its inbox at turn start | n/a |

Verified on macOS on 2026-11-17: Claude Code 2.1.322 relay delivery to a
named desktop session; codex-cli 0.169 worker and review runs. One live isolated
ordinary Codex relay round trip was observed on macOS on 2026-11-18 with
codex-cli 0.169.0-alpha.11.1: the recipient read the archived fixture and
acknowledged its exact relay ID in a later app turn. This used an existing
account/machine, not a clean account or machine. The queue implementation treats
exit 0 as submission only; that run also reported a failed resume. Resume is
not guaranteed. Both experimental lease-mail doorbells remain **fakes only;
live unrun**. Verify the installed CLI and recipient readback independently.
A display name is never a Codex thread address: absent an actual owner session ID, relay holds
all notes in place and the Codex doorbell is unavailable.
All runs close stdin, run under a hard timeout, and pass the prompt as one
argument (120000-byte cap, under Linux's 128 KiB per-argument limit).
Submission, recipient readback and action are separate stages (K-10).

**Relay trust boundary.** Whatever can write an inbox can put a file in
front of a session, so the relay never puts note text in front of a model:
the delivery run, and a mailroom bridge, sees only a fixed-shape pointer (count, archive folder,
sanitized file names, relay id), and the receiving session reads the files
itself, labelled as data from automation ([K-01](../kit/KIT.md)). The Claude
delivery run is confined: `--restricted`, no tool servers, no hooks, and
only the built-in `ListAgents` and `SendMessage` tools. Success is never
taken from the model's words: the JSON event stream must show exactly one
`SendMessage` call, addressed to the registered name, with a successful,
non-error result. The stream is read even when the client exits non-zero or
times out, so a send that landed is not repeated; a send whose text the
model changed still counts, with a warning to the Oracle. Verifying needs
`jq`; without it the relay refuses to deliver. An unconfirmed delivery is
retried, at most `relay_max_attempts` times in a row, then backs off (1 h,
doubling to 24 h) with one note to the Oracle.

## Hooks and the gate

`tick.sh` runs executables in `hooks/every/` on each tick and those in
`hourly/`, `daily/` and `weekly/` once per period, in byte order; files
ending in `.example`, `.disabled` or `~` are skipped, and so are group- or
world-writable ones. Each hook is stamped as it starts, so an interrupted
hook waits for the next period while hooks that never started run on the
next tick. A hook gets `AO_PROFILE`, `AO_HOME`, `AO_INBOX`, `AO_STATE`,
`AO_SCRIPTS`, `AO_ORACLE_KEY` and `AO_PERIOD`, closed stdin and
`oracle_home` as its working directory; its output goes to
`<state_dir>/hooks.log`. A TERM to the tick stops the running hook (TERM,
then KILL after the grace period) before the tick exits. To tell a session
something, a hook writes a note with `inbox-put.sh`. One-shot watches carry
their own end date and exit quietly after it. Examples:
`../examples/hooks/`.

Hooks run outside any client's permission system, as you: anything that
can write the hooks folder gets scheduled execution. Keep `hooks_dir` where
agents do not write unattended, or review every change to it.

An optional executable `hooks/gate` is asked before acting on an operator:
`gate <action> <key> <client> <session>`, where action is `relay`,
`watchdog` or `doorbell`; non-zero holds that operator for this tick. A
hold with an owner and an expiry (`lane.sh hold`, `<state_dir>/holds/<key>`)
holds the operator before the gate is asked. Optional `hooks/wake <client>
<session>` warms a cold session and `hooks/push <text>` reaches the owner at
the mailroom's tier 4 ([mailroom](../docs/mailroom.md)). An
operator whose home has a lease (experimental, [handoff](../docs/handoff.md))
is routed to the holder, and held without asking the gate while its lease
names no holder. Which client and session own an operator is decided in one
function, `ao_operator_resolve` in `lib/registry.sh`.

## Scheduling

`install.sh timers` renders the unit for this machine and prints the
command that loads it. By hand, replace a template's `@NAME@` placeholders:

```sh
sed -e "s|@LABEL@|org.example.agent-operations.tick|g" \
    -e "s|@KIT_DIR@|$KIT|g" -e "s|@PROFILE@|$PROFILE|g" -e "s|@LOG_DIR@|$LOGS|g" \
    scripts/units/tick.plist.in > ~/Library/LaunchAgents/org.example.agent-operations.tick.plist
```

`tick.plist.in` runs the tick every 10 minutes under `/bin/sh` (macOS).
`tick.service.in` and `tick.timer.in` do the same as a systemd user timer;
they are shipped for Linux hosts but **untested**. Every timed job, the tick
included, belongs in the Oracle home's `SCHEDULES.md` with owner and cost.

## Exit codes

Shared by all scripts (`lib/core.sh`): `0` success or nothing to do; `1`
runtime failure, or findings from a check; `2` usage or configuration error;
`3` busy (another run holds the lock; benign); `4` required role not
configured; `124` timed out; `129`, `130`, `143` stopped by HUP, INT or
TERM. Runners otherwise pass through the client's own status. The
experimental lease scripts add `5`: refused by the lease (not the holder,
wrong epoch, a marker or a missing confirmation).

## Environment

| Variable | Meaning |
| --- | --- |
| `AO_PROFILE` | Profile path (default `${XDG_CONFIG_HOME:-~/.config}/agent-operations/profile`) |
| `AO_NOW` | Pin the clock (epoch seconds); for tests |
| `AO_GRACE` | Seconds between TERM and KILL for stopped children (default 10) |
| `AO_TIMEOUT_BIN` | `none` forces the portable timeout instead of coreutils `timeout` |
| `AO_LOCK_TOOL` | `flock`, `lockf` or `mkdir`: force a lock mechanism (default: the first available) |
| `AO_KEEP_STREAM` | File to keep a copy of a Claude delivery's event stream, for diagnosis |
| `AO_PRIVACY_DENYLIST` | Default denylist for `check.sh privacy` |
| `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `TMPDIR`, `XDG_*` | Honoured where the clients and OS define them |

## Portability and tests

POSIX sh (checked under bash's POSIX mode and dash), BSD and GNU userlands,
byte-wise collation (`LC_COLLATE=C`). Locks are kernel locks taken with
`flock` (Linux) or `lockf` (macOS) on a descriptor that children never
inherit, so a crash, reboot or recycled pid cannot leave one stuck; without
either tool a directory lock is the fallback. The portable timeout reaches
a command's descendants only where the shell allows job control without a
terminal (bash's `sh`, as on macOS); dash signals the direct child, so
Linux hosts should keep coreutils `timeout`. Used tools beyond POSIX:
`head -c`, `mktemp`, `flock`/`lockf`, and `timeout`/`gtimeout` when
present. `shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh
adapters/*.sh` is clean. `tests/run.sh` runs the suite under every
installed shell with fake agent CLIs: no network, no model calls.

## PR watcher

`pr-watch.sh --help` is the interface contract. Configure one invocation per
owned repository in a deterministic tick hook, with a stable key and persistent
state. Polls are reads; the watcher creates local inbox data only. The registry
and relay choose the active client, so no watcher calls a dormant session.
First successful polling establishes a baseline; subsequent unchanged polling
is quiet. Failed reads retain the last successful snapshot. Record the precise
head/review/check/comment coverage actually implemented and tested; adapter
summary fields alone do not cover every comment event. End-to-end installed
acceptance needs an observed event and receiver acknowledgement, not just fakes.

## Worktree creation

`worktree.sh --help` describes its arguments. New seats use a real canonical
repo's `worktrees.noindex` container. The helper verifies a sticky macOS Time
Machine exclusion with no sudo, plus child readback before checkout churn.
Native app-managed and historical seats are not relocated. Unique work and
irreplaceable state need independent backed-up custody; excluding a container
is not proof of restore safety. See [the manual](../MANUAL.md).

## Codex queue settings

A registry row's `client=codex` selects native queue delivery by default to its
actual session ID (the lease holder overrides the row when enabled). Set
`relay_codex=off` to preserve inbox, interrupted claims and pending state for
passive pickup; individual file-only rows also remain passive. A missing actual
owner session ID holds notes, including under a lease. Display names never
substitute for IDs. No second provider is called for the row. One live isolated
ordinary relay round trip was observed; see [Clients](#clients) for its date,
version and existing-account/machine limits. This does not verify either
experimental lease-mail doorbell; both remain fakes only, live unrun.
`relay_codex_cmd` selects the installed CLI and `relay_codex_timeout` is a positive
hard limit (default 30 seconds). No model role is needed to enqueue a pointer.
`doorbell_codex=queue` separately opts in to the experimental lease-mail doorbell;
its default is `off`, independently of relay mode. The queue implementation
treats exit 0 as queue submission only, not resumed/read/executed; the observed
live run returned 0 with a resume-failed warning. Resume is not guaranteed.
Verify the installed CLI and recipient acknowledgement separately. An absent
CLI/off doorbell can use the existing unavailable-transport chat fallback;
a failed queue call is a delivery failure, not an automatic second route.
Retries preserve the relay ID, but an ambiguous timeout can duplicate a pointer;
receivers deduplicate IDs and reconcile action state before any effect.

### Watcher coverage

Configure `githost=gh` (or a compatible executable adapter), then invoke
`pr-watch.sh --key web --repo sample/app-web` from an authorized tick hook.
The bundled adapter makes one bounded read-only metadata query: up to 100
recently updated open PRs, first 100 check contexts, last 20 submitted reviews
and last 20 top-level comments per PR. It requests IDs/timestamps/states, not
comment/review bodies or authors. Inline review threads, departures from the
open list, changes entirely between polls and older items outside these windows
are not covered. GitHub Enterprise schema compatibility is unverified. The
current [GraphQL PullRequest schema](https://docs.github.com/en/graphql/reference/pulls#pullrequest)
includes the PR head's status-check rollup; fixture tests do not prove live API
availability or authorization on a deployment.

## Job inventory planner

Copy [the synthetic sample](../templates/oracle/JOBS.tsv) into a private home
and replace it with actual scheduler IDs/state. `jobs.sh check REGISTRY` validates
its nine-field TSV schema. `jobs.sh plan REGISTRY OWNER claude|codex` returns
advisory actions ordered disable, enable, nochange. No native API calls or
scheduler changes occur. Neutral timers stay unchanged; paused intent is
preserved; unknown/mismatched state and active unmirrored old-side jobs block
before any plan output. A supplied enabled snapshot is not live readback.
See [the manual](../MANUAL.md#job-registry-and-provider-cutover) for cutover and
unshipped automation boundaries.
