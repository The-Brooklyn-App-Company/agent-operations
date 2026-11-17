# Scripts

The kit's moving parts: a scheduled **tick**, an inbox **relay**, two safe
model **runners**, a **status** view and deterministic **checks**. Plain POSIX
sh run by the OS scheduler: no daemon, no database, no listener. Every script
prints its own help with `--help`; that header is the reference for its
usage, environment and exit codes.

| Script | Job |
| --- | --- |
| `tick.sh` | Scheduled heartbeat: stall watchdog, period hooks, then the relay |
| `relay.sh` | Inbox folder to session message, through the row's client transport |
| `worker-run.sh` | One cheap read-only worker job; result to an inbox unless `NOTHING` |
| `review-run.sh` | One independent review pass by the reviewer role |
| `status.sh` | One line per operator: activity, quiet list, inbox depth |
| `inbox-put.sh` | Atomic note into an inbox, for hooks and adapters |
| `check.sh` | Duplicate rule text, skill shape, privacy scan |
| `drift-check.sh` | Weekly audit: `check.sh dupes` plus a worker pass with `drift-prompt.md` |
| `lease.sh` | **Experimental.** Advisory lease per operator: holder, standby, takeover ([continuity](../docs/continuity.md)) |
| `mail.sh` | **Experimental.** File mailboxes in each home; `ring-all` for a tick hook |
| `doorbell-claude.sh`, `doorbell-codex.sh` | **Experimental.** "You have mail", never the mail |
| `ask.sh` | **Experimental.** Asks and the approvals ledger, bound to the lease |
| `units/` | launchd (macOS) and systemd (Linux, untested) templates for the tick |
| `lib/` | Shared code: `core.sh`, `registry.sh`, `vendor.sh`, one `vendor-<client>.sh` per harness |

## Quickstart

1. Copy one of `../profiles/*.profile` to `~/.config/agent-operations/profile`
   (or anywhere, and set `AO_PROFILE`). Keep it out of git. Set
   `oracle_home` and replace every `CHANGE-ME`.
2. In the Oracle home, create `operators/REGISTRY.tsv` (below) with a row
   for the Oracle and each operator.
3. Check it: `scripts/status.sh`, then `scripts/tick.sh --dry-run`.
4. Drop a test note: `echo hello | scripts/inbox-put.sh <key> test`, then
   `scripts/relay.sh` and confirm it reached the session.
5. Install the tick unit (see [Scheduling](#scheduling)).

## The Oracle home

Paths are relative to `oracle_home` unless absolute; every one is a profile
key.

| Path (default) | Key | What |
| --- | --- | --- |
| `operators/REGISTRY.tsv` | `registry` | One row per session |
| `operators/WATCHDOG-QUIET.tsv` | `quiet_list` | Dated watchdog exemptions |
| `inbox/<key>/*.md` | `inbox_dir` | Notes waiting for a session; `.claimed/` holds a batch while it is being delivered |
| `inbox/sent/` | `sent_dir` | Delivered notes, `<stamp>-<key>-<name>`; must be on a filesystem with hard links |
| `hooks/{every,hourly,daily,weekly}/` | `hooks_dir` | Tick hooks; optional `hooks/gate` |
| `~/.local/state/agent-operations/` | `state_dir` | Logs, stamps, locks (machine-local; keep out of git and backups) |

**Registry** (tab-separated; `#` comments; no empty fields, use `-`):

```
# key	name	project-dir	session	[client]
oracle	Oracle	~/oracle-home	<session-id>
web	Web	~/src/web	<session-id>	claude
infra	Infra	~/src/infra	pending	file-only
```

`key` names the inbox folder (`[A-Za-z0-9._-]`). `name` is the session's
display name, which the Claude transport addresses. `session` is the session
id, or `pending`; pending rows are skipped by the watchdog. `client` picks
the transport and activity source (`claude`, `codex`, `custom`, `file-only`);
empty means `relay_default`.

**Quiet list** (tab-separated): `key-or-name<TAB>YYYY-MM-DD<TAB>reason`.
The watchdog skips the operator through that date, inclusive; expired rows
are ignored.

**Inbox notes** must appear atomically: write elsewhere and `mv`, or use
`inbox-put.sh`. The relay only reads `*.md` and ignores dotfiles.

## Profile

One flat `key=value` file per machine: roles, models, paths, hours and
integration slots. Lines starting with `#` are comments; blank lines are
ignored; later lines win. Values are literal (no variables, no command
substitution, one pair of surrounding quotes stripped); a leading `~/`
expands in path keys and commands. The file is parsed, never sourced. Unknown
keys warn; keys starting with `x_` are free for local hooks.

| Key | Default | Meaning |
| --- | --- | --- |
| `oracle_home` | required | The Oracle's private home repo |
| `oracle_key` | `oracle` | Registry key of the Oracle; alerts and failures go to its inbox |
| `registry`, `quiet_list`, `inbox_dir`, `sent_dir`, `state_dir`, `hooks_dir` | see above | Paths |
| `path` | inherited | `PATH` for scheduled runs, which start with a minimal one |
| `watchdog_days` | `1-5` | Work days: `all`, or a comma list of `N` / `N-M` (1 = Monday) |
| `watchdog_hours` | `09-19` | Work hours: `all`, or `HH-HH` (end exclusive) |
| `watchdog_idle_min` | `180` | Idle minutes before an alert; `0` disables the watchdog |
| `watchdog_realert_min` | `180` | Minimum minutes between alerts for one operator |
| `daily_hour` | `6` | Daily hooks run from this hour |
| `weekly_day`, `weekly_hour` | `5`, `6` | Weekly hooks run from this day and hour, catching up later that ISO week |
| `hook_timeout` | `900` | Seconds per hook |
| `relay_default` | `claude` | Client for registry rows without one |
| `relay_label` | `Relay (automated inbox, not from the human):` | First line of every relayed message |
| `relay_max_bytes` | `4000` | Per-note cut in a message (the full note stays in `sent_dir`) |
| `relay_max_message_bytes` | `100000` | Size of one delivery; a larger backlog goes in several batches (max 120000: one argument) |
| `relay_workdir` | `oracle_home` | Working directory for delivery runs |
| `review_family` | `cross` | `cross`, `same-family` or `single-model`; printed by `review-run.sh` for the release record |
| `drift_rules`, `drift_files`, `drift_repo_files`, `drift_min_words`, `drift_prompt`, `drift_prompt_extra`, `drift_workdir`, `drift_to` | see `drift-check.sh --help` | Drift audit inputs |
| `secrets` | `os` | Secrets slot: `os` (macOS keychain; libsecret on Linux), `none`, or an adapter path called as `<adapter> get <name>` |
| `tracker`, `chat`, `githost`, `ci` | `none` | Integration slots, recorded for agents and adapters; the scripts do not read them yet |
| `attribution` | `none` | AI attribution in commits: `none` or `disclose`; read by agents, not scripts |
| `lease_stale`, `work_root`, `doorbell_codex`, `doorbell_rering_min` | `4h`, `~/src`, `off`, `60` | Experimental lease layer (see [continuity](../docs/continuity.md)) |

**Roles.** Each role is a prefix: `worker`, `reviewer`, and one relay
transport per client, `relay_claude`, `relay_codex`, `relay_custom`. Every
role takes the same fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `<role>_client` | `none` | `claude`, `codex`, `custom` or `none` (relay roles are fixed by their name) |
| `<role>_cmd` | the client name | Executable on `PATH`, or a path; required for `custom` |
| `<role>_model` | client default | Model id. Set it: an empty model silently uses the client's default |
| `<role>_effort` | client default | Reasoning effort (codex) |
| `<role>_timeout` | `600` | Hard limit in seconds; `0` = none |
| `<role>_mcp_disable` | none | Comma list of tool servers to switch off (codex). Claude runs load no tool servers at all |
| `<role>_tools` | runs: `Read,Grep,Glob`; delivery: `ToolSearch,ListAgents,SendMessage` | Claude built-in tool allow-list; `default` = the client's full set |
| `<role>_max_turns` | client default | Claude turn cap |
| `<role>_disallowed_tools` | none | Claude deny-list, added on top (useful with `<role>_tools=default`) |
| `<role>_token_secret` | none | Secret name, fetched through `secrets` for this role only |
| `<role>_token_env` | `CLAUDE_CODE_OAUTH_TOKEN` for claude | Variable that receives it |

A missing role is never substituted: `worker-run.sh` leaves one note in the
Oracle's inbox and exits 4; `drift-check.sh` falls back to its deterministic
part. Fallbacks such as same-family review are explicit profile choices.

## Clients

Each harness is one file, `lib/vendor-<client>.sh`, implementing `run`,
`deliver` and `activity` (contract in `lib/vendor.sh`). Scripts only call the
role interface, so adding a harness touches nothing else.

| Client | run | deliver | activity |
| --- | --- | --- | --- |
| `claude` | `claude -p`, no session persistence, read-only tools | Headless run with only the messaging tools calls the built-in `SendMessage` once (Claude Code 2.1.224+); confirmed from the event stream with `jq` (below) | `<session>.jsonl` under `$CLAUDE_CONFIG_DIR/projects/<dir-slug>/`, else the newest transcript there |
| `codex` | `codex exec --ephemeral -s read-only`, listed servers off | **Experimental:** one read-only `codex exec resume <session>` turn | Newest `$CODEX_HOME/sessions/**/*<session>*.jsonl` |
| `custom` | `<cmd> run <workdir> <prompt> <out>` | `<cmd> deliver <name> <session> <message> <relay-id>` | `<cmd> activity <dir> <session>` (optional) |
| `file-only` | n/a | Nothing: the session reads its inbox at turn start | n/a |

All runs close stdin, run under a hard timeout, and pass the prompt as one
argument (120000-byte cap, under Linux's 128 KiB per-argument limit). Every
Claude invocation loads no tool servers and runs no hooks. Delivered is not
read: report a relayed message as delivered, not as acted on.

**Relay trust boundary.** Whatever can write to an inbox can put text in
front of a model twice: the delivery run, and the receiving session, which
sees the note labelled as automated. Only local automation you control
should write inboxes. The Claude delivery run is confined: no tool servers,
no hooks, and only the built-in `ToolSearch`, `ListAgents` and `SendMessage`
tools. Success is never taken from the model's words: the JSON event stream
must show exactly one `SendMessage` call, addressed to the registered name,
whose text is exactly the batch (including its `relay-id` line; only
leading and trailing blank space may differ), and a successful, non-error
result for that call. Verifying needs `jq`; without it the relay refuses to
deliver. On any mismatch the notes return to the inbox and the batch is
retried. The check runs after the call, so it detects a wrong or extra send
rather than preventing it; the tool allow-list is what limits the run.
A confirmed batch is recorded (`.claimed/.acked`) before archiving, so an
archive failure is retried without re-sending; only a crash between
confirmation and that record can re-send a batch. Notes are claimed (renamed into `.claimed/`) before they are read,
so a note rewritten during delivery stays pending instead of being archived
unsent.

## Hooks and the gate

`tick.sh` runs executables in `hooks/every/` on each tick and those in
`hourly/`, `daily/` and `weekly/` once per period, in name order; files
ending in `.example`, `.disabled` or `~` are skipped. Each hook is stamped
as it starts, so an interrupted hook waits for the next period while hooks
that never started run on the next tick. A hook gets
`AO_PROFILE`, `AO_HOME`, `AO_INBOX`, `AO_STATE`, `AO_SCRIPTS`,
`AO_ORACLE_KEY` and `AO_PERIOD`, closed stdin and `oracle_home` as its
working directory; its output goes to `<state_dir>/hooks.log`. To tell a
session something, a hook writes a note with `inbox-put.sh`. One-shot
watches carry their own end date and exit quietly after it. Example:
`../examples/hooks/weekly/50-drift-check`.

An optional executable `hooks/gate` is asked before acting on an operator:
`gate <action> <key> <client> <session>`, where action is `relay`,
`watchdog` or `doorbell`; non-zero holds that operator for this tick. An
operator whose home has a lease (experimental) is routed to the holder, and
held without asking the gate while its lease names no holder. Which client and session own an
operator is decided in one function, `ao_operator_resolve` in
`lib/registry.sh`.

## Scheduling

Render a template by replacing its `@NAME@` placeholders, for example:

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
configured; `124` timed out. Runners otherwise pass through the client's own
status. The experimental lease scripts add `5`: refused by
the lease (not the holder, wrong epoch, a marker or a missing confirmation).

## Environment

| Variable | Meaning |
| --- | --- |
| `AO_PROFILE` | Profile path (default `${XDG_CONFIG_HOME:-~/.config}/agent-operations/profile`) |
| `AO_NOW` | Pin the clock (epoch seconds); for tests |
| `AO_TIMEOUT_BIN` | `none` forces the portable timeout instead of coreutils `timeout` |
| `AO_PRIVACY_DENYLIST` | Default denylist for `check.sh privacy` |
| `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `TMPDIR`, `XDG_*` | Honoured where the clients and OS define them |

## Portability and tests

POSIX sh (checked under bash's POSIX mode and dash), BSD and GNU userlands.
The portable timeout reaches a command's descendants only where the shell
allows job control without a terminal (bash's `sh`, as on macOS); dash
signals the direct child, so Linux hosts should keep coreutils `timeout`.
Used tools beyond POSIX: `head -c`, `mktemp`, and `timeout`/`gtimeout` when
present. `shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh` is clean.
`tests/run.sh` runs the suite under every installed shell with fake agent
CLIs: no network, no model calls.
