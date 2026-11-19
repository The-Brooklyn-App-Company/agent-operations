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

### Always-on host

`scripts/install.sh host` sets the host up, check then set, and is safe to
run again: it prints one row per item with its state and what is left for
you. `scripts/check.sh host` repeats the checks read-only; run it after any
change to the host or its jobs.

| Item | Check | Set |
| --- | --- | --- |
| App Nap, per desktop app in `host_apps` (default `com.anthropic.claudefordesktop` and `com.openai.codex`, the Claude and ChatGPT desktop apps) | `defaults read <id> NSAppSleepDisabled` is 1 | `defaults write <id> NSAppSleepDisabled -bool YES`, read back. Takes effect after the app restarts. Without it a hidden, idle app is napped and its bridge stops delivering |
| Power | `pmset -g` system sleep is 0 | Check only: change it in System Settings |
| Mailroom folders | Present | Created |
| Units | Tick and relay unit present; the relay unit watches every registry inbox | `install.sh timers` (rendered from the registry); you load them |
| launchd priority | No job matching `host_latency_jobs` sets `ProcessType` Background or Adaptive, or `LowPriorityIO` | Check only: edit the job |
| Bridges | Rows `mailroom-claude` and `mailroom-codex` have session ids | `install.sh bridge <client>` |

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
