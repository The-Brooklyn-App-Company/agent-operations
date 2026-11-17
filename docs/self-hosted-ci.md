# Self-hosted CI

Running CI on your own host, for example ephemeral VM runners on an always-on machine, saves hosted minutes and gives you control. It also creates a trust boundary and a queue you must manage. These practices are examples that worked; adapt the numbers to your own measurements.

## Trust boundary

- **Pin what may run.** Restrict each runner group to selected repositories and workflows. Pin allowed workflows to exact commit SHAs wherever your CI platform supports it (on GitHub, check which workflow types accept SHA pins, such as reusable workflows), so a changed workflow needs re-admission. Never run fork PRs on self-hosted runners.
- **Admitting a new repository is the human's decision.** Expanding which repositories can use the runners widens the trust boundary; an operator does not grant it on another operator's behalf. New pins for repositories already admitted can be routine under a standing grant.
- **Shared workflows land first.** Change a shared or reusable workflow in its own PR, and get its new SHA admitted before any caller moves to it. Callers reference only admitted SHAs. Batch shared-workflow edits so each merge needs one new pin, not one per push.
- **Isolate PR code from secrets.** PR-controlled code runs in a clean, unprivileged, ephemeral environment with no secrets. Privileged work runs post-merge in a separate clean environment. Withholding secrets from one step is not isolation: earlier PR code on the same runner can tamper with the workspace or later steps.

## Stuck queues

A job that calls a workflow at an unadmitted SHA never gets a runner. It stays queued and can silently hold the PR's concurrency group, so newer runs wait behind it while runners sit idle. Depending on how concurrency is configured, `cancel-in-progress` may not clear it; do not rely on it alone.

Add a read-only stuck-queue watchdog that flags, with the blocked concurrency group named:

- a run that references a workflow SHA outside the allowlist, after a few minutes;
- any self-hosted job queued well past your normal p90 while a runner is idle.

Cancelling the stale run stays an approved action for the owner; the watchdog only reports. A plain cancel may not take on a job no runner ever picked up; the platform's force-cancel (on GitHub, `POST /repos/{owner}/{repo}/actions/runs/{run_id}/force-cancel`) clears it.

## Throughput

Most small jobs are dominated by VM clone and boot, checkout and cold dependency install, not by the work itself. Measure before optimizing:

- **Pre-bake images** with pinned toolchains, browsers, service images and a read-only dependency store seeded only from default-branch lockfiles. Keep install integrity checks on, so the cache changes speed, not what CI accepts. Rebuild on a schedule and record what seeded each image.
- **Cache dependencies** and keep per-job writes job-local.
- **Move orchestration jobs off VM slots.** Jobs that run under about 30 seconds (scope resolution, status aggregation, verdicts) should fold into the first real job or run on hosted runners, where they do not hold a slot.
- **Merge tiny jobs** that each pay a boot for under a minute of work, without dropping checks.
- **Measure queue p50 and p90 weekly**, plus slot acquisitions and job-minutes per PR, and set targets against a recorded baseline. Queue time is usually the real cost.

## Host maintenance

- **Drain first.** Stop new jobs and let running ones finish before installing a runner or pool update. Install from a reviewed, merged commit, with a dry run where available.
- **Prove reboots before relying on them.** Do not leave reboots or OS updates to unattended maintenance until a supervised, drained reboot with a recovery path has shown that the installed runner setup comes back.
- **Watch capacity, not just health.** Adding slots is a measured step: add one, watch host load, job-time inflation and other services on the host for a day, then continue.
