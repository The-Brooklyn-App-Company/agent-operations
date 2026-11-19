# Setup and operating manual

This walkthrough configures one personal instance with either client or both.
It applies the rules in [KIT.md](kit/KIT.md); it does not grant access, turn on
paused jobs, or publish software. Start with one low-risk operator, prove its
real delivery path, then repeat the same setup. Product versions and transport
availability must be verified on the machine being installed.

## 1. Choose the homes, owners and delivery paths

Keep three layers: public kit, optional private team overlay, private personal
state. Never copy a real instance inventory into the public kit (K-31).

| Item | Suggested location | Custody |
| --- | --- | --- |
| Pinned kit checkout | `~/src/agent-operations` | Released rules and scripts |
| Oracle home | `~/ops/oracle` | Backlog, journal, grants and registry |
| Embedded operator home | `~/ops/oracle/operators/web` | One outcome, mandate and notes |
| Canonical work repository | `~/src/app-web` | Integration checkout and retained Git history |
| New scoped worktree | `~/src/app-web/worktrees.noindex/20260101-layout` | One task; disposable only after preservation |
| Profile | `~/.config/agent-operations/profile` | Local paths, roles, models and adapters |
| Runtime installation | Explicitly recorded per application | Stable served artifact and state, separate from source |

Record the integration branch, publication branch and exact runtime source
separately. They may differ. Preserve documented live custody exceptions rather
than switching a running checkout for cosmetic parity (K-16, K-28).

An operator has one stable routing key and one home across clients (K-13).
Display names can change without moving the home, renaming the key or resetting
its delivery state. A key migration is a separate coordinated transaction.
The work-repo mapping declares one merge owner and any contributors.

## 2. Install the first client

Prerequisites: macOS, Git, a supported signed-in client and `jq` for transports
that require JSON validation. Linux units exist but remain untested. Existing
account setup is an owner action; installation never initiates sign-in.

```sh
git clone <kit-url> ~/src/agent-operations
cd ~/src/agent-operations
git checkout <reviewed-release-tag>
scripts/bootstrap.sh     # guided: this section and section 5 in one run
```

[`bootstrap.sh`](docs/hosts-and-ci.md#first-run) runs the steps below for
you and ends with a checklist; the manual steps stay valid:

```sh
scripts/install.sh --dry-run oracle ~/ops/oracle
scripts/install.sh oracle ~/ops/oracle
```

Edit the profile the installer prints. Choose explicit role models; unresolved
`CHANGE-ME` values must not become an accidental model or billing fallback.
Use the relevant [profile](profiles/) and [integration guide](docs/profiles-and-integrations.md).
Do not copy credentials into the profile: use secret-store names if needed.

Create an embedded operator, or omit `--embedded` for its own private home.
`operator.sh create` is the guided routine: it asks for the model and effort
on both clients (decided now, with you), runs the installer and walks the
checklist ([routines](docs/conventions.md#operator-routines)):

```sh
scripts/operator.sh create web --embedded --owns git@git.example.com:sample/app-web.git
# or, without the routine:
scripts/install.sh operator web --embedded --owns git@git.example.com:sample/app-web.git
scripts/check.sh home ~/ops/oracle ~/ops/oracle/operators/web
scripts/status.sh
```

The installer is resumable: preview existing files rather than overwriting
unknown state. Read its printed plan before creating repos or worktrees.
Register existing work and domain grants instead of creating another operator.

Start a named client session in the generated home. Its canonical instructions
are `AGENTS.md`; `CLAUDE.md` imports that file. `MANDATE.md` owns outcome, action
authority and dated standing grants; `NOTES.md` owns current recovery evidence.
Keep implementation in work repos. The home must point to the backlog, current
handoff, work repositories and any running-result owner.

## 3. Apply client settings and prove the real path

The kit prints settings patterns; it does not silently edit client permissions.
Review settings through the client's supported controls. Browser/computer use
and authentication consent remain separate from setup authorization (K-01).

For Codex, writable roots must be existing real directories: the operator home,
its inbound/outbound mail paths and its work repos. Reject symlink roots rather
than granting a parent containing other lanes. Use absolute paths for Git and
build commands when the active home differs from the repository. Test a small
create/read/delete in the actual approved workspace and verify a Git checkpoint:
file writes succeeding does not prove the sandbox can modify `.git`.

For Claude Code, apply the home's settings and declared work directories.
Do not copy relative path rules without checking their new base. Keep grants
for stable runtime binaries and credential helpers; replacing a binary can
require a fresh OS grant even when its path looks familiar (K-27).

Use native project/thread/session controls where available. Preserve existing
IDs and histories. A CLI run against a live app thread can contend with its
writer lock; do not substitute a second headless execution session for a
supported app-thread queue. No raw client database edits.

Before claiming setup complete, record: client/version, real home/work roots,
write and Git checks, the named live session, and the first received pointer.
A successful command is not proof the operator read or acted on its message.

## 4. Add the second client without a second operator

```sh
scripts/status.sh --drift
scripts/install.sh --dry-run sync codex
scripts/install.sh sync codex
```

Replace `codex` with `claude` for the other direction. Apply the printed settings
and register the existing/new session through supported controls. Resolve drift
without overwriting grants, paused jobs or working trees. Both clients use the
same operator home and task worktree; neither gets a competing backlog.

One client owns each operator at a time. The registry's client/session selects
that operator's route; the Oracle itself can remain on the other client. An
instance-specific ownership list must agree with the registry, not become a
second conflicting source. Retain dormant session identities for recovery, but
exclude them from dispatch. A pointer never transfers ownership (K-34).

Switch an operator between clients with `scripts/lane.sh switch KEY --to
CLIENT --session ID`, then `scripts/lane.sh verify KEY` until every step
passes: handoff, routing, watchdog, labels, pins on both sides, models,
switch-in audit and the incoming session's acknowledgement
([conventions](docs/conventions.md#switching-an-operator-between-clients)).
The script is the checklist; no step is done from memory (K-36).

Use [the lease procedure](docs/handoff.md) for warm handoff or owner-directed
cold takeover. Lease ownership is advisory, not a hard OS security boundary.
Only the holder acts; the standby redirects. Expiry alone does not justify
stealing a running session. Preserve dispatch markers and unknown results,
and complete the incoming-family audit before new work (K-22). Follow the live
test in [TESTING.md](TESTING.md); do not claim untested takeover paths accepted.

### Cold handoff checklist

Before a planned provider switch, place a current **COLD HANDOFF** section at the
top of each operator's notes. Include exact source heads and open PRs, served
artifact and runtime/custody exceptions, outstanding review/approval gates,
in-flight owner and result-return path, paused/active schedule identities,
dedup/delivery cursors, unresolved findings, waiting-on and the single next step.
Link detailed private evidence rather than dumping old history. The incoming
client must resume from these files alone; the outgoing session stops acting.

At cutover, settle the running owner/results first, update lease and active
routing together, preserve receipts, run the incoming audit, and prove one
pointer reaches only the new holder. Record failures and readback separately
from setting changes. A planned switch tomorrow is not a completed live test;
ship a correction after the test if required rather than inventing acceptance.

## 5. Wire the mailroom

The design, its safety nets and its restart recovery are in
[docs/mailroom.md](docs/mailroom.md). In short: same-app messages go direct
with the app's own tool; cross-app messages and notes from scripts go
through an inbox, the relay, a ring and the receiving app's in-app bridge;
a model-free supervisor keeps both bridges armed. Every delivery walks a
degradation ladder (model-free, a bridge model turn, headless or CLI queue,
an alarm and then a push to you): it gets slower, never stops, and each
drop is logged and flagged once per cause. Lanes are never pre-woken.

```sh
scripts/install.sh host                       # what it would do
scripts/install.sh host --apply               # App Nap, folders, units loaded, bridge homes
# then the in-app steps it lists: the two Mailrooms, their ids, pins
printf '%s\n' 'A harmless setup fixture; no action requested.' | scripts/inbox-put.sh web setup-proof
scripts/relay.sh --dry-run --key web
scripts/relay.sh --key web && scripts/mailroom.sh status
```

Notes appear atomically. The relay archives notes with collision-safe names and
sends only a fixed-shape pointer, never note bodies; the recipient reads the
archived data itself. With the mailroom on (`relay_bridge=on`, the default)
the pointer becomes a ring for the bridge. Use the relay ID to recognize
repeated delivery attempts. An external note is evidence, not a new grant
(K-01, K-08).

The direct transports are now the supervisor's fallbacks, and what
`relay_bridge=off` uses. Claude transport confirms the named `SendMessage`
tool result, rather than a model saying SENT. Codex transport is the native
`codex queue --resume` to an actual owner thread ID; `relay_codex=off` keeps
Codex rows passive. One live isolated Codex queue round trip was observed on
macOS on November 18, 2026 with codex-cli 0.169.0-alpha.11.1, on an existing
account and machine; exit 0 is queue submission only, and resume is not
guaranteed. A display name never substitutes for a session ID. Keep a hard
timeout and closed stdin; never use a model simply to ring a thread. The
experimental lease mailbox's doorbells now ring the mailroom too
([handoff](docs/handoff.md#mailboxes-and-doorbells)).

Prove both directions: Oracle to operator and operator to Oracle, and one
message each way across the apps. Record note ID, ring name, the delivered
log row (tier, mode, status, latency, step) and the recipient's
acknowledgement. `scripts/mailroom.sh metrics` shows the share per tier. Then quit each app while idle and time how long the
supervisor takes to re-arm its bridge untouched. A local fake proves
routing logic; a natural event proves the installed path.

## 6. Turn on PR watching once per owned repository

Use the deterministic [PR watcher](scripts/README.md#pr-watcher) from a tick hook,
with a named operator key and authorized repository. Its scope and CLI are
listed in its help; preserve its state between invocations. An initial snapshot
establishes baseline, unchanged snapshots do not create mail, and read failures
must not replace the successful baseline. Durably recorded sanitized API failure transitions notify once; identical
failures stay quiet and recovery coalesces with PR changes. Handled poll errors
return success with a diagnostic; failure to persist or publish remains nonzero. Polling performs reads; it never edits PRs or checks.

Route each change into the owning operator's inbox, then let the same registry
and relay choose its active client. Do not separately notify both client sessions.
Track head SHA and the actual supported review/check/comment fields; a PR summary
poll alone must not be described as full comment monitoring. Late review events
must still be detected at an unchanged commit. Keep no-checks distinct from green.

Validate with bounded local fixtures first, then an authorized natural PR event.
Record baseline, exact changed event/PR/head, one inbox note, relay ID, addressed
client and receiver readback. An unchanged next poll must be quiet. Do not create
external test comments, reviews or CI reruns merely to manufacture proof. If no
natural event occurs, mark that acceptance pending instead of claiming end to end.

Every timed job has one owner/cadence/model/cost row in `SCHEDULES.md` (K-24).
Keep explicitly paused schedules paused. A new polling job must replace/reuse
existing coverage rather than duplicate it. Human quiet hours affect alerts to
the human, not necessarily authorized around-the-clock change sensing.

### Job registry and provider cutover

Copy the synthetic sample into the private home explicitly; installation does
not yet create this optional registry:

```sh
cp templates/oracle/JOBS.tsv ~/ops/oracle/JOBS.tsv
scripts/jobs.sh check ~/ops/oracle/JOBS.tsv
scripts/jobs.sh plan ~/ops/oracle/JOBS.tsv workshop codex
```

The sample demonstrates the fictional `workshop` owner. Replace it with actual
scheduler metadata and the real stable owner key before an operational plan.
Each row has nine literal TSV fields: job ID, owner, executor side, cadence,
model, desired intent, observed enabled snapshot, opaque native binding and
mirror group. Use `scripts/jobs.sh --help` for validation bounds and token shape.
Desired `paused` is different from an enabled-intent inactive peer. Neutral
system jobs are independent of the operator's client and stay unchanged.

The tested planner validates all rows before emitting anything, orders disable
before enable, and blocks an enabled unmirrored old-side native job. Mirror peers
must have the same owner, cadence and intent. Single-subscription jobs work on
their registered side; lack of a second subscription is not a reason to invent
or activate a peer. Registry enabled state is a supplied snapshot, not a live
query. Before cutover obtain current native state, drain in-flight sends, and
check result ownership, receipt cursors, mirror bindings and paused intent.

**Planner only in this release.** No native scheduler apply adapter, atomic
lease-plus-scheduler transaction, live readback or failure recovery is shipped.
Use supported native scheduling controls under actual authority, one exact job
at a time, and independently verify old disabled/new enabled while paused jobs
stay paused. Do not change app databases. Unknown native state is a real evidence
gap; do not label a provider transfer seamless until measured. Prefer neutral
system timers to avoid needing mirrored provider-native tasks at all.

## 7. Create and settle scoped worktrees

Use `scripts/worktree.sh --help` for the creation helper:

```sh
scripts/worktree.sh "$HOME/src/app-web" 20260101-layout web/layout <integration-ref>
```

Its arguments are canonical repo, dated slug, optional unused branch and start
revision. Defaults are `work/<slug>` and `HEAD`; supply the verified integration
base rather than assuming the canonical branch is current. Default placement is
repo-local `worktrees.noindex/<task-slug>` so existing real repo roots cover new
seats in both clients. This does not migrate native app-managed or historical
worktrees. Attach a supported existing seat instead of duplicating implementation.

The creation transaction verifies a real canonical path and local Git exclusion
(search/build tooling must honor the excluded container),
a sticky Time Machine container exclusion and a child exclusion readback before
checkout churn. `.noindex` addresses Spotlight; it does not exclude backups.
On macOS, `tmutil addexclusion <container>` sets a sticky exclusion without sudo;
`-p` has different fixed-path/privilege behavior and is not the default here.
A helper failure leaves an inspectable state; it never deletes unknown content.
Platform behavior must be tested on the actual host, not inferred from unit fakes.

Keep sole-copy state out of disposable seats. Backed-up canonical Git retains
local-only branch objects; approved remotes retain pushed branches. An independent
clone may hold objects missing from canonical Git, so an ordinary branch name or
tag in canonical is not enough. Preserve dirty tracked files, untracked and
needed ignored/private artifacts before deleting a seat. Do not add remotes to
private local-only projects to solve backup custody. Logs/caches are replaceable;
application DBs and original assets may not be (K-29).

Cleanup is three separate choices: remove stale registration, remove a physical
worktree, delete a branch. Capture current status including ignored content,
head/ref ancestry or patch equivalence, stash custody, active processes/jobs,
saved-project and runtime consumers, and the restore location. Dates, “clean” or
“prunable” alone establish none of those. Use ordinary safe Git operations and
respect review/protection/release gates. Never force-remove, reset unknown state
or move a running custody seat to make the tree look uniform. Keep a current
integration-branch handoff for unfinished source lanes (K-15, K-16).

## 8. Token efficiency and bounded coordination

Design sensing as deterministic collect → compare → durable receipt → pointer.
An empty tick invokes no model. Use bounded worker inputs for actual exceptions,
standalone disposable low-cost workers where useful, and named result ownership.
Archive successful worker chats only after their durable result and delivery;
retain failures requiring follow-up. Do not use persistent operator heartbeats
as polling loops or reread an entire history on every turn (K-23, K-25).

Read the current backlog/handoff and relevant scoped evidence once, then update
only the owning record. Parallelize independent work with separate file ownership;
avoid a second coordinator duplicating lane inventories. Measure tool/API/model
use and latency honestly; configured cost tiers are not observed account savings.

For same-provider work, use native disposable subagents when available, with
explicit model/effort and a fresh neutral context per review round. Reserve CLI
wrappers for crossing providers or an unavailable native capability. Retain the
bounded-run and result-return contract regardless of transport; no mandatory
same-provider CLI hop. Native availability does not change grants or billing.

A holder can delegate a bounded partner: written outcome, files/action scope,
authorization evidence, result route, review boundary and retirement condition.
The partner does not inherit Oracle authority, journal ownership or account
grants. End it with a durable handoff, explicit stop, removal from active routing,
and archive/unpin through supported controls. Do not wake retired partners with
late duplicate mail. The holder remains the single approval endpoint (K-13).

Usage balancing is a proposed owner-approved handoff, not a silent model change:
compare actual subscription pace, choose named lanes, preserve pinned models,
run switch-in audits and migrate routes/receipts without duplicate wakes. Set a
review/return condition after the usage reset. No paid API fallback (K-26).

## 9. Review, release and acceptance

Use the independent-review contract (K-19–K-22), at most three rounds. Give a
reviewer goal, exact base/head, raw diff, acceptance and scope; settle every
finding. Same-family review is labelled, and cross-family review is sought where
available. Weekly other-family audits cover source, notes, mandates and leftover
work. Repeated findings improve one owning rule rather than multiply checklists.

Before publishing, run the full [contribution gates](CONTRIBUTING.md), the local
privacy denylist scan and a separate privacy-only review with no private source
context. Record exact tested tree, commands, results and unverified paths in
[TESTING.md](TESTING.md). A rendered timer is not loaded, a fake CLI is not live
transport, and a queue acknowledgement is not a readback (K-10).

The maintainer reviews, merges, tags and pushes under the actual release mandate.
A draft branch is not a release. Update the public capability table with evidence
and limitations; test a fresh isolated install for each profile claimed usable,
and leave unrun platforms/profiles explicitly untested.

## 10. Tested capabilities and dated roadmap

As of November 18, 2026, installation/sync, advisory leases, pointer relay,
worktree preflight, deterministic PR sensing and the job cutover planner have
the evidence described in [TESTING.md](TESTING.md). The following are design
requirements, not installed automation or claims of native client parity:

- **Ownership generation and drain (design, November 18, 2026; unshipped):**
  a future recoverable transfer should freeze new dispatch, settle outstanding
  effects/results, and publish one holder/thread with a monotonically increasing
  ownership generation. Kit-controlled dispatchers and effectful jobs should
  verify that generation immediately before acting. Drain native paths that
  cannot enforce it explicitly; changing a route cannot stop already queued
  turns. Existing advisory leases do not implement this transaction.
- **Job occurrence reconciliation (design, November 18, 2026; unshipped):**
  prefer one neutral timer per logical job. For unavoidable mirrored native
  schedules, persist transfer progress, verify both sides through native
  readback, and reconcile `(job ID, scheduled occurrence)` after interruption
  so an in-flight run cannot duplicate or lose a due run. Preserve paused
  intent. The shipped planner does not reconcile occurrences.
- **Deterministic wake recovery:** shipped as the experimental mailroom
  supervisor in 0.3.1 ([docs/mailroom.md](docs/mailroom.md)), proven only
  against fakes. Retire any model-backed polling fallback only after restart
  recovery has been proven on the installed path.
- **Thread/sidebar parity:** maintain a private registry of stable lane key,
  display title, session IDs, project/home and desired organization per client.
  Compare native state through supported tools; update titles/pins/sections
  only where each client supports them. A lack of sections in one client means
  a documented pin layout, not an invented API. Detect and report drift before
  changing routes. Pin follows ownership: pin the active side's thread and
  unpin the dormant side at cutover, driven by the stable lane registry. Retain
  dormant thread identities for recovery. Automated two-client sidebar and
  ownership-driven pin reconciliation are unshipped.
- **Lifecycle workflows:** add via installer and second-client sync; rename a
  display title while preserving stable IDs; archive only after job/results,
  source and receipt custody are settled; delete only the exact owner-approved
  data; move with the lease/audit/job plan. Native rename/archive/delete and
  transactional move adapters are unshipped. Existing installers/leases are
  not an automatic lifecycle manager.
- **Owning-side native jobs:** the registry/planner is tested; automatic
  disable/enable with native readback and recovery is unshipped. A neutral timer
  can keep sensing while routing changes, without enabling dormant jobs.
- **Usage/preferences design:** private preference records can declare stable
  owner key, preferred provider, allowed providers, model/effort per role and
  review/return time. Example design-only TSV columns are `owner preferred
  allowed implementer_model reviewer_model effort review_after`; these are not
  parsed by the current scripts. A one-provider allowed set is valid. Read
  usage only through supported authorized account surfaces, label unknown
  metrics, compare pace to the actual reset window, and propose a bounded move.
  No automatic billing fallback or invented per-task subscription conversion.
  Collection, thresholds and automated balancing remain unshipped.

Acceptance for future automation includes one round-trip transfer and return,
no lost results, no duplicated jobs, no dormant-client wake, paused jobs still
paused, private state retained, and a recipient resumed from files alone.

### Capability synchronization design

Keep one private declaration folder as the editing source, render reviewed
per-client configuration, then compare actual state before a provider switch.
This release documents the schema; capability renderers and a native-state
`doctor` are roadmap items, not shipped commands. Existing instruction-pointer
and profile drift checks cover only their documented inputs.

| Declaration | Minimum fields | Check / rendering target |
| --- | --- | --- |
| lanes.tsv | key, title, home, work repos, active side, desired pin/section | Native thread/project identity plus generated routing maps |
| capabilities.tsv | capability, access class, required lane keys, Claude binding, Codex binding, sync policy | Presence and exact authorized route on the target side |
| skills.tsv | name, canonical source, package manifest and supporting-file hashes, expected client hashes | Installed complete packages, including referenced scripts, templates and assets |
| routing.tsv | role, provider model/effort, override expiry | Worker preferences, separate from account grants |
| jobs.tsv | The validated job schema above | Neutral timers plus explicit native peer bindings/state |
| Memory/facts | Current repo facts, preferences, mandate, handoff and journal | Client-specific memory contains pointers to these records |

A capability row might declare `docs-read`, access `read`, lanes `web`, bindings
`local-docs` / `hosted-docs`, policy `manual-auth`. These are fictional labels,
not credentials or a new integration. **Capability evidence classes (design,
November 18, 2026; unshipped):** record declared configuration, installed package
contents (including supporting-file hashes), loaded session capability, exact
authenticated account/operation scope, and dated behavioral proof separately.
A descriptor or top-level skill hash proves neither usable account access nor
the complete package. Report unknowns and freshness explicitly; gate a switch
only on capabilities actually required by that lane.
Never call an effectful connector merely to test presence; use metadata or a
scoped authorized read. A financial connector requires its own grant regardless
of a required-capability flag.

The future doctor should compare declared hashes, required bindings and job
ownership against supported native read-only snapshots, report changes once,
and refuse a switch with the exact missing prerequisite. Hosted OAuth and
app-only state may need a human/native tool; report the gap without initiating
a login. Single-provider mode validates only the allowed provider, not an
imaginary second account. Configuration renderers show their diff; widening
roots/tools/grants needs explicit human authorization. Narrowing must account
for existing jobs/consumers rather than silently strand running work.

Provider-private memory is not the durable shared authority. Extract reviewed
facts and preferences into the owning repo record; keep a thin pointer in each
client and preserve useful historical evidence. Do not synchronize provider
credential stores, chat databases or secret values. Secret names can reference
one approved store; capabilities and skill files never contain its contents.

### Operator material migration

Both clients enter the same private operator home, with declared work-repo
pointers. Inventory role notes, mandates, personal grants, operator-only
instructions, local client rules, watcher scripts and recovery packets in source
repos. Preserve exact originals and history, then relocate role material to the
private home where safe. Leave only a contributor-facing pointer if useful;
build/test/release mechanics and shared code conventions remain in the product.

For shared repositories, propose a reviewed PR that explains any collaborator
agent dependency before removing instructions or scripts. Personal publishing
branches retain their release gates. A housekeeping move must not trigger a
publication or move a granted binary, live source path, DB, lock, receipt cursor
or custody checkout blindly. Keep consumer-bound exceptions in place with a
named reason and owner until an approved migration verifies the served path.
A fresh home-rooted session must recover from the home plus its work-repo map;
actual startup and permission inheritance still need testing per client.

### Managed app mode design

`managed_apps=on|off` is a proposed configuration option, not consumed by the
current profile parser or an installed automation in this release. In the on
mode, generated app state would keep only each active side's operator threads
pinned and keep its standby counterpart unpinned; preserve the stable thread IDs
and lane registry. Finished disposable task/subagent/automation-run chats would
be archived after durable result delivery and handling checks. Running chats,
failed jobs with unresolved work, and persistent operators must remain available.
Archive preserves history; deletion is a separate authorized action.

In off mode the kit would leave pins, sidebar/project organization and archive
choices to the human. Future native adapters must compare supported app state,
preview changes and detect partial failures without editing raw app databases.
This design does not assert that either client's current UI supports every
section or grouping option. Manual/native-tool changes can be verified for an
instance without claiming the general reconciler shipped.
