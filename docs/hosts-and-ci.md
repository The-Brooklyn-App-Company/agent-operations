# Hosts and CI

## Scheduling

One OS timer runs `scripts/tick.sh` every 10 minutes: launchd on macOS,
a systemd user timer on Linux (shipped, untested). Each tick, under a lock:

1. **Stall watchdog.** Inside the work window (`watchdog_days`,
   `watchdog_hours`), every operator with a session whose transcript has been
   idle longer than `watchdog_idle_min`, or that has none, gets one note in
   the Oracle's inbox, at most once per `watchdog_realert_min`. A dated quiet
   list (`operators/WATCHDOG-QUIET.tsv`) exempts parked operators until a
   date.
2. **Hooks.** Executables in `hooks/every/`, and once per period in
   `hooks/hourly/`, `daily/` and `weekly/`. A one-shot watch is a hook that
   carries its own end date and exits quietly after it. A failing hook
   leaves one note for the Oracle.
3. **Relay and supervisor.** Inbox notes go to their sessions, then the
   [mailroom](mailroom.md) supervisor checks waiting rings and the bridges.
   With every inbox empty and both bridges armed this costs nothing.

A second unit, the **relay unit**, runs `mailroom.sh cycle` (relay, then
supervisor) whenever a note lands in a registry inbox folder and every 60
seconds, so cross-app messages wait seconds, not a tick. Both units run at
load (login or reboot) as `ProcessType` Standard.

`scripts/install.sh timers` renders both units for this machine into your
user's launchd or systemd folder and prints the commands that load them;
loading them is your step, so no agent installs a persistent job on its own.
Both belong in `SCHEDULES.md` like every other timed job
([K-24](../kit/KIT.md)). After adding an operator, render the relay unit
again so it watches the new inbox (`install.sh host` reports a stale one).

## Scheduled work

Order every recurring job by cost ([K-23](../kit/KIT.md)): a free script
checks first; a cheap worker classifies only what the script found; a
session runs only to act.

**Deterministic first.** Before any model runs, check eligibility, the time
window or triggering event, input validity and the lock. If nothing is
eligible and every read was fresh and healthy, end quietly.

**Cheap workers.** `scripts/worker-run.sh <job> <recipient> <prompt>` runs
the worker role once, boxed ([K-25](../kit/KIT.md)). The prompt tells the
model to answer exactly `NOTHING` when there is nothing worth reporting:
then nothing is written. Any other answer becomes a note in the recipient's
inbox. A failure, a timeout, an empty answer or a missing role becomes a
note in the Oracle's inbox. A watcher only reports: it never reviews diffs,
fixes code, comments or merges.

**Outcomes.** Healthy-and-unchanged stays quiet. Failed and unknown are
distinct outcomes, and neither may look like "unchanged". Group repeated
identical failures into one episode by source and failure fingerprint, so
a different failure is still noticed. Mark an event delivered only after
the transport confirms it; after an uncertain delivery, reconcile the
destination before resending. Delivery is at-least-once, never
exactly-once.

**Escalation belongs to the recipient.** A new event is an observation, not
an automatic interruption. Forward it when the recipient needs to act on or
know it now and its owner has not already handled it; keep routine progress
for the next digest. A digest the human asked for is still due on quiet
days.

**Stewardship.** Keep one inventory of every timed job wherever it runs:
OS timers, client scheduled tasks, cheap-model runs, CI schedules, with
owner, cadence, model and cost tier. Review it weekly for stale or
duplicate jobs and jobs that could move to a cheaper tier. Run one watcher
per repository, principal and purpose. When you replace a worker or move it
to another host, stop the old one and confirm it stopped before enabling the
new one. Some clients set a scheduled task's model only in their UI:
record what the client actually shows, not what you intended.

## Unattended hosts

An always-on host still sleeps, reboots and loses network: report those
periods as unknown, never as healthy. Remote access must keep working when
sessions sit idle, and urgent alerts need a push route to the human.

### First run

`scripts/bootstrap.sh` is the one command a new adopter runs, from a
terminal, ideally inside the client they want the Oracle on. It explains
each step before doing it and asks only for the choices that are yours: the
client you start on (detected when it can be), the Oracle home, which
clients you use, your timezone (`owner_tz`; times are reported in it, logs
stay UTC), the profile's model choices, and making this client the one
active Oracle. The rest it does with the kit's own scripts
([K-36](../kit/KIT.md)): `install.sh oracle`; the profile, including the
Codex app's bundled node and tool server found inside the app bundle;
`install.sh host --apply` (below); `install.sh sync` for a toehold in the
other client; the Oracle's session id (`operator.sh session`) and the lock.

It ends with a checklist that waits for you and re-checks after each step:
start the Oracle session, sign in to each app yourself, quit and reopen
both apps once, start the two Mailrooms (cheapest model set at creation,
titled "Mailroom") and record their ids, re-arm the Codex watcher, pin per
the [conventions](conventions.md#sidebar-and-titles), register the recovery
hook on each client. Each step passes on its own evidence (a registry id,
the watcher's heartbeat) or on `bootstrap.sh mark STEP` where no script can
see it; the last step is a test note that must reach the Oracle through the
mailroom. `bootstrap.sh status` prints the checklist again; `--yes` runs
without questions (options and defaults only).

### Always-on host

`scripts/install.sh host --apply` sets the host up in one command, check
then set, and is safe to run again ([K-36](../kit/KIT.md)): it prints one row
per item with its state and what is left, then the few steps only a person
can do in the apps, each marked done or to do. Without `--apply` it changes
only App Nap and folders and says what `--apply` would do.
`scripts/check.sh host` repeats the launchd checks read-only; run it after
any change to the host or its jobs.

| Item | Check | Set (with `--apply`) |
| --- | --- | --- |
| App Nap, per desktop app in `host_apps` (default `com.anthropic.claudefordesktop` and `com.openai.codex`, the Claude and ChatGPT desktop apps) | `defaults read <id> NSAppSleepDisabled` is 1 | Always: `defaults write <id> NSAppSleepDisabled -bool YES`, read back. Takes effect after the app restarts. Without it a hidden, idle app is napped and its bridge stops delivering |
| Power | `pmset -g` system sleep is 0 | Check only: change it in System Settings |
| Mailroom folders | Present | Always created |
| Units | The tick and relay units match their templates; the relay unit watches every registry inbox (WatchPaths generated from the registry); both are loaded | Rendered, replaced when stale (old copy in `<state_dir>/backup`), loaded with `launchctl bootstrap gui/<uid>` |
| Bridge homes | Each has its lean duty file (`AGENTS.md`, rendered from `templates/mailroom/`) | Created with `install.sh bridge <client>`, or the duty file brought up to date |
| Bridge ids | Rows `mailroom-claude` and `mailroom-codex` have session ids: the one file every script reads | In-app step |
| Switches and holds | Claude tier 1 (`bridge_claude_t1`) and its kill switch; the supervisor pause and lane holds name an owner, an expiry and a reason ([K-07](../kit/KIT.md)) | Check only |
| Retired probes | No hourly probe state left | Removed |
| Oracle lock | `operators/ORACLE-LOCK` names the one active Oracle | `lane.sh oracle-lock take`, on the human's word |
| launchd priority | No job matching `host_latency_jobs` sets `ProcessType` Background or Adaptive, or `LowPriorityIO` | Check only: edit the job |

The in-app steps it ends with: quit and reopen both apps once (App Nap);
start the Claude Mailroom and create the Codex Mailroom (both titled
"Mailroom", cheapest model, ids into the registry); pin per the
[conventions](conventions.md#sidebar-and-titles).

**Latency-sensitive jobs run Standard.** launchd throttles Background jobs
(CPU, I/O and timer coalescing), and child processes inherit it: a
throttled job can start minutes late, and a network forwarder or database
client under it can time out. Give every job that someone waits on
(the mailroom, watchers, schedulers, alert routes, CI forwarders)
`ProcessType` Standard, or leave the key unset, which is the same. Keep
Background and `LowPriorityIO` for genuinely deferrable work such as
backups and indexing. List your own such jobs in `host_latency_jobs`
(launchd label globs, default `*agent-operations*`) so `check.sh host`
flags them, and add both desktop apps to your login items so a reboot
brings the bridges back.

**No routine permission prompts** ([K-27](../kit/KIT.md)). A dialog on an
unattended host blocks work for hours. Treat each unexpected prompt as a
defect.

- **Pin interpreters.** Never run scheduled work under a package manager's
  interpreter: its path and signing identity change on upgrade, and the OS
  may ask for access again. Use the system interpreter (for Python,
  `/usr/bin/python3 -I`) or one pinned at a stable path. The kit's scripts
  need only `/bin/sh`.
- **Quiet test servers.** Bind loopback only and do no hostname lookups at
  start-up; either can raise a firewall or local-network prompt.
- **Close stdin.** Run CLI agents with `</dev/null`, so they never wait for
  input.
- **Reap everything.** Tests and timeouts kill child process groups and
  remove temp directories, even on failure.
- **Detect, then tune.** A detector that reads the system log for
  permission-dialog activity catches regressions; attribute each hit before
  acting on it. In zsh, `log` is a builtin: call `/usr/bin/log`.
- **Secrets.** Read from the OS store by the process that needs them
  ([K-05](../kit/KIT.md)). Reading a store item from a new binary can itself
  raise a prompt: grant it once, deliberately.

**Keep churn out** ([K-29](../kit/KIT.md)): the kit's state directory
(default `~/.local/state/agent-operations`), inboxes, caches, build output
and virtual machines go in `.gitignore` and are excluded from backups and
indexing when they are created.

## Switching hosts

1. **Inventory the old host:** checkouts and worktrees, tool versions, the
   kit tag, account bindings by name only, locale and time zone, timers and
   pending deliveries.
2. **Sign in fresh.** The owner signs in on the new host directly;
   credentials are never copied.
3. **Hand off durably:** push branches and commit each home's notes.
4. **Move schedules, not the whole machine.** Stop the old host's timers and
   sessions and confirm they stopped before enabling the new host's.
5. **Restore** as in [backup and moving machines](operators-and-repos.md#backup-and-moving-machines),
   then accept basic operation. Test remote wake and restart only if you
   rely on them.

## Self-hosted CI

Running CI on your own host (for example ephemeral VM runners on the
always-on machine) saves hosted minutes but creates a trust boundary and a
queue to manage. Adapt the numbers to your own measurements.

**Trust boundary.**

- Restrict runner groups to selected repositories and workflows; pin allowed
  workflows to exact commits where the platform supports it, so a changed
  workflow needs re-admission. Never run fork pull requests on self-hosted
  runners.
- Admitting a new repository widens the trust boundary: that is the human's
  decision ([K-03](../kit/KIT.md)). New pins for already-admitted
  repositories can be routine under a standing grant.
- Change a shared workflow in its own pull request and get its new commit
  admitted before callers move to it.
- Run pull-request code in a clean, unprivileged, ephemeral environment with
  no secrets; run privileged work after merge in a separate clean one.
  Withholding secrets from one step is not isolation.

**Stuck queues.** A job calling a workflow at an unadmitted commit never
gets a runner; it can sit queued and hold the pull request's concurrency
group while runners idle. A read-only watchdog should flag runs that
reference a workflow outside the allowlist, and self-hosted jobs queued well
past your normal p90 while a runner is idle. Cancelling is the owner's call;
a plain cancel may not clear a job no runner picked up, and the platform's
force-cancel may be needed.

**Throughput.** Small jobs are dominated by VM boot, checkout and cold
installs. Pre-bake images with pinned toolchains and a read-only dependency
store seeded from default-branch lockfiles (keep integrity checks on); fold
sub-30-second orchestration jobs into real jobs or hosted runners; merge
tiny jobs; and measure queue p50 and p90 weekly against a recorded
baseline.

**Host maintenance.** Drain before updating runners and install updates
from a reviewed, merged commit. Prove a supervised, drained reboot before
leaving reboots to unattended maintenance. Add capacity one slot at a time
and watch load, job-time inflation and other services for a day.
