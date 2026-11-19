# Changelog

Entries are keyed by rule ID ([kit/KIT.md](kit/KIT.md)). Rule IDs started
with 0.2.0; 0.1.x guidance had none.

## Unreleased

## 0.3.1 (2026-11-19)

- **K-01, K-10, K-23, K-27, K-37:** experimental [mailroom](docs/mailroom.md).
  One rule: the relay routes, the in-app bridges deliver, and a model-free
  supervisor keeps both bridges armed. Same-app messages go direct with the
  app's own tool; cross-app and script notes become pointer-only rings
  (`steer` or `queue`). **Degradation ladders per side:** tier 1 model-free
  (Claude: opt-in `bridge_claude_t1=socket`, the bridge's watcher writes to
  a warm session's socket and confirms the session's own receipt; Codex: the
  bridge-owned watcher sends natively, steers at once and queues on the
  target's turn-complete event read from its rollout file, with no status
  polling), tier 2 a bridge model turn (cold targets, misses, re-arm),
  tier 3 headless or CLI queue, tier 4 an alarm and then a push to the owner
  (`hooks/push` or the chat adapter) when the Oracle has not received it in
  15 minutes. **Telemetry:** one delivered-log row format for both sides
  (tier, mode, status, latency in ms, the step that missed);
  `mailroom.sh metrics` reports the share per tier with p50/p90. **Version
  fingerprint and canary** per side, and a once-per-cause degradation alarm
  (side, step, fingerprint), cleared by the next first-tier delivery; the
  hourly probes are retired. **Supervisor recovery:** desktop-app restart
  (relaunch, deep-link warm-up of the bridge through `wake_link` or
  `hooks/wake`, then back to the Oracle's session, plus a headless re-arm),
  Codex app restart (one re-arm per app process), reboot (open in the
  background at login), and **Codex thread recovery**: a thread that keeps
  timing out while others deliver is marked unresponsive and its recovery
  routine opens (a queued, then a native no-op turn; else a new thread in
  the operator's home with the model set at creation, the old one archived,
  the registry updated, the lane switch re-run). **Unknown sends are
  reconciled** against the target's own record five minutes later: a late
  receipt is settled, a confirmed absence is escalated once to tier 3, an
  unreadable record alarms (`resolve` rows, counted apart in `metrics`).
  Both bridges are titled "Mailroom"; ids live in the registry rows
  `mailroom-claude` and `mailroom-codex`. `relay_bridge=off` keeps direct
  delivery.
- **K-27, K-36:** turnkey always-on host. `install.sh host [--apply]`, check
  then set: App Nap off for both desktop apps, power check, folders, the
  tick and relay launchd units rendered (WatchPaths from the registry),
  replaced when stale and loaded, both bridge homes with lean duty files,
  retired probe state removed; checks the Claude tier-1 switch, the
  supervisor pause and lane holds, the Oracle lock and `ProcessType`
  Background; ends with the few in-app steps a person must do, each marked
  done or to do. `check.sh host` re-checks launchd priority.
- **K-36, K-27:** `bootstrap.sh`, the guided first run: starts the Oracle
  on whichever client you begin with, explains each step and asks only for
  your choices (client, Oracle home, clients used, timezone, models, the
  Oracle lock); automates the rest (the Oracle home and profile, the Codex
  app's bundled node and tool server found in the app bundle, `install.sh
  host --apply`, a toehold in the other client by `install.sh sync`); ends
  with a checklist of the in-app steps, each with its check, the last a
  test note that must reach the Oracle.
- **K-26, K-29, K-36:** `operator.sh`, the operator routines as guided
  scripts with verifiers: `create` (model and effort for both clients
  decided at creation, recorded in `operator.conf`), `archive` (worktrees to
  verified local git bundles, the registry row retired last), `model` (the
  one, owner-initiated path to change an operator's model; refused without
  the owner's words or from the operator's own session), `session`,
  `recover`, `verify`, `mark`.
- **K-13, K-36:** `lane.sh`: a lane switch as a scripted checklist with a
  verifier (handoff, routing, watchdog, labels, pins on both sides, models
  from `operator.conf`, switch-in audit, ACK proof with a one-time token;
  in-app marks carry the app's readback as evidence, or a stated gap); `side` for the
  parked-side guard now first in every home's recovery steps; `check`;
  holds with owner and expiry; the Oracle lock. New
  [conventions](docs/conventions.md) page: one active side per operator and
  one active Oracle, same app direct and cross-app via the mailroom, the
  Mailroom titles, pinned active operators, an "Inactive Operators" section
  on Claude, pinned active threads and Mailroom on Codex.
- **K-32:** `hygiene.sh`, the nightly model-free hygiene check (expired holds,
  open switches, uncommitted work, budgets, standing grants against the
  Claude permission rules), with a daily hook example.
- **K-15:** client-neutral recovery: `recover-context.sh` answers the
  `SessionStart` sources `startup|resume|compact|fork` (Claude Code and
  Codex), reads the operator's bounded `## Current state` block of
  `NOTES.md` (new in the template) instead of a tail of the history, and
  orders an explicit re-read until recovery is verified on the client. New
  [client capabilities](docs/client-capabilities.md) page: each operation's
  tool on both clients, with evidence levels and the known gaps.
- **K-24 changed:** the schedule inventory records mechanism, native id,
  owner and side, cadence with timezone, paused state and last verified
  run. The delegation packet opens with the short handoff shape.
- **K-05 changed:** credentials move store to store. **K-07 changed:** holds,
  pauses and kill switches name an owner, an expiry and a reason
  (`lane.sh hold --reason` is required; a hold without one is not obeyed).
  **K-26 changed:** models are set at creation with the human; an operator
  never changes its own; no model changes by a message to an idle session.
  **K-28 changed:** check a tool's schema first; after an ambiguous result,
  repeat only once the target's own record confirms absence. **K-29
  changed:** finished worktrees become local bundles. The introduction
  states that no rule overrides a client's platform instructions, its
  sandbox or a review. **K-12 changed:**
  report times in the owner's local timezone; convert UTC logs. **K-13
  changed:** one active side per operator and one active Oracle (a lock
  file). **K-32 changed:** derived rules quote the human's words, dated, and are
  marked derived until confirmed;
  clean as you go with a nightly hygiene check. **K-36 added:** build
  alongside, switch atomically, and run multi-step procedures as scripted
  checklists with a verifier. **K-37 added:** degrade, never stop. The rules
  file now has a byte budget of 11000, enforced by `check.sh kit`; other
  rules were tightened to fit (no meaning changed).
- **K-15:** `recover-context.sh`, a SessionStart (`compact|resume`) recovery
  digest capped at 8 KB, because Claude Code replaces hook output over about
  10 KB with a short preview; a test fails above the cap.
- **K-09 changed:** routine machinery under an approved goal (CI cancels and
  re-runs, one re-run of an approved deploy) is not a decision for the human.
- **K-10 changed:** claims name the mechanism and say MATCHES or DEVIATES
  against the agreed design; deviations are told when they happen.
- **K-35 added:** daily oversight: each operator's product progress, not its
  machinery, and the human's words checked against the backlog and journal.
- Validation in [TESTING.md](TESTING.md).

## 0.3.0 (2026-11-18)

- **K-13, K-14, K-22, K-23, K-24, K-26, K-34:** end-to-end two-client
  [manual](MANUAL.md), exclusive owning-side routing, switch-in and bounded
  partner retirement, change-only PR sensing, usage handoff and token design.
- **K-13, K-24, K-28:** bounded schedule snapshot validation and job cutover
  planner, preserving paused intent and blocking unmatched active peers; native
  execution/sidebar/lifecycle adapters and usage automation remain roadmap.
- **K-29:** distinguish replaceable churn from irreplaceable application state;
  preserve unique commits and dirty/private artifacts before exclusions or cleanup.
- **K-16, K-27, K-29:** repo-local `worktrees.noindex` creation helper with a
  verified sticky macOS backup exclusion; no new broad writable roots.
- **K-10, K-23, K-28:** native Codex queue relay and deterministic PR
  watcher; transport acceptance, fixture tests and installed runtime proof stay
  distinct. One isolated ordinary Codex relay round trip was observed on macOS,
  2026-11-18, codex-cli 0.169.0-alpha.11.1, using an existing account/machine;
  resume is not guaranteed. Both lease-mail doorbells are fakes only; live unrun.
- **K-10, K-28, K-34 upgrade from 0.2.0:** Codex rows with actual owner thread
  IDs now queue pointers by default (`relay_codex=queue`). Set `relay_codex=off`
  for passive inbox pickup; existing inbox/claimed/pending state is preserved
  while off. Missing IDs hold notes; display names are never thread addresses.
  The experimental Codex doorbell remains separately opt-in and default off.
- **K-10, K-13, K-24, K-34:** dated unshipped manual designs for ownership
  generation/drain, job occurrences, capability evidence and complete package
  hashes, and deterministic wake/restart proof before polling-fallback retirement.
- Full release validation and remaining live acceptance recorded in
  [TESTING.md](TESTING.md).

## 0.2.1-rc1 (release candidate; folded into 0.3.0)

Adds the handoff layer between Claude Code and Codex, **experimental**,
and makes the switch-in audit one mechanism.

### Rules

- **K-22** The switch-in audit counts as done only when the incoming
  family's report is committed in the operator's home and recorded
  (`lease.sh audit-done`). The reviewer is chosen from the operator's model
  family (its lease's provider, else the registry client), never from a
  `file-only` transport.
- **K-34** Lease checks are available, experimental (no longer "coming in
  0.2.x"); see [docs/handoff.md](docs/handoff.md).

### Scripts

- **Experimental** handoff layer (K-34, K-28, K-08): `lease.sh` (advisory
  lease per operator home: holder and standby, redirect, dispatch markers,
  warm release, human-only takeover with a cold note, `settle`, `unlock`),
  `mail.sh` (file mailboxes, once-only forward of a direct human turn,
  `ring-all` hook), `doorbell-claude.sh`, `doorbell-codex.sh`, `ask.sh`
  (asks and the approvals ledger bound to the lease epoch). Routed through
  `ao_operator_resolve` and `ao_gate`; profile keys `lease_stale`,
  `doorbell_codex`, `doorbell_rering_min`; exit code 5 for a lease refusal.
  The lease keeps its own fail-closed directory lock rather than core's
  kernel lock: lease verbs run without a profile, lock one operator home
  each, and must stay locked after a crash mid-change.
- One switch-in audit (K-22): a lease handoff to another client, or a
  family change without a lease (recorded by `cross-review.sh` in
  `<state_dir>/audit/`, also with `cross_review=off`), makes the audit
  pending; `cross-review.sh` writes the incoming family's headless report
  to `<home>/audits/`; `lease.sh audit-done --report PATH` records its path
  and commit and clears the gate. `status.sh` gains an AUDIT column (a new
  last field in `--tsv`). With a lease, dispatches and new asks refuse
  while it is pending.
- `cross-review.sh` uses `OP_PROVIDER` (the model family) for every
  reviewer choice, and names family and transport in the packet.
- `doorbell-codex.sh` is always unavailable (exit 2; the chat slot is the
  fallback): 0.2.0 has no Codex delivery transport. `doorbell_codex` is
  reserved; `off` is the only value.
- `install.sh sync <client>` brings every registry row up to date for a
  second client (instruction pointers, settings patterns including the new
  `settings/handoff.md`, a `session.<client>` name) and prints the per-
  operator steps; `status.sh --drift` reports mismatches across clients
  (registry, lease holders, pointers, `operator.conf`, kit pin) with a fix
  each, exit 1 while anything drifts (K-14, K-15).
- Codex runs pass `--disable plugins --disable apps`: a plugin's tool
  servers cannot be switched off by name, and the attempt made every Codex
  run fail at configuration load on machines with such plugins (K-27).

### Docs

- New [docs/handoff.md](docs/handoff.md) (threat model, lease, standby,
  mailboxes, asks, takeover, switch-in audit, per-client validation,
  settings patterns, limits) and [TESTING.md](TESTING.md) (automated suite
  and a live test on one low-risk operator). The Claude Code deny patterns
  now put a wildcard between `lease.sh` and the verb, so `--home DIR`
  before the verb is covered too.
- `docs/continuity.md` points its placeholders at the handoff doc;
  README's "What is proven" lists each experimental piece with its
  evidence.

### Unverified

- The live test on a real operator (TESTING.md, part 2), which needs a
  human at a terminal: the takeover, `settle` and `unlock` confirmations
  were typed through a pseudo-terminal by the tests and the sandboxed
  end-to-end, never by a person.
- Either client's interactive permission prompt for the takeover command;
  a desktop-app thread as holder or standby.
- A doorbell reaching a live session; any Codex doorbell.
- A registry switch-in audit with a real reviewer (fakes only), and the
  weekly cross-review on real clients.
- In the Codex sandbox, `dispatch-begin --pid` cannot read process state
  and committing fails (`.git` is read-only under `workspace-write`).
- `install.sh sync` and `status.sh --drift` against a real two-client
  setup (fakes only so far).
- A forward whose run dies after publishing and before marking it sent is
  sent again by a later run (a duplicate notification, never a lost turn).

## 0.2.0 (2026-11-17)

A clean break from 0.1.x: the kit becomes rules with stable IDs, six
guides, templates for a fixed home layout, and scripts that run the
scheduled parts. See [upgrading from 0.1.x](docs/architecture.md#upgrading-from-01x).

### Rules

- **Added K-01 to K-34.** Most restate 0.1.x guidance as one rule each,
  in one place: authority and consent (K-01 to K-09), claims and outcomes
  (K-10 to K-12), structure (K-13 to K-18), review (K-19 to K-21),
  scheduled work and model runs (K-23 to K-26), hosts and effects (K-27 to
  K-29), records and privacy (K-30 to K-32), opt-in (K-33, K-34).
- **New in substance:** K-04 (no trades or money movement unless enabled
  in writing), K-16 and K-17 (one merge owner per work repository,
  shared files owner-only), K-18 (instances share no sessions), K-22
  (weekly cross-model review and the switch-in audit, on by default), K-33
  (security auto-ship as an opt-in with a recovery precondition), K-34
  (lease checks, experimental).
- **Fixed rules** (no overlay may override them): K-01, K-02, K-03, K-04,
  K-05, K-10, and K-34 once enabled.

### Scripts

- `tick.sh`, `relay.sh`, `worker-run.sh`, `review-run.sh`, `status.sh`,
  `inbox-put.sh`, `check.sh`, `drift-check.sh` (K-23 to K-26).
- `relay.sh` sends a fixed-shape pointer to the archived notes, never the
  note text; the delivery is confirmed from the client's event stream, read
  even when the client fails; repeated failures back off and tell the
  Oracle once (K-01, K-10).
- `cross-review.sh` and the hourly hook (K-22).
- `install.sh`: `oracle`, `operator`, `skills`, `timers`, each with
  `--dry-run`; never overwrites, never edits client settings, never loads
  a timer, never uses the network.
- `check.sh kit|links|home` (K-14, K-16).
- Kernel locks, interruptible children, Claude runs in `--restricted`
  mode, every Codex tool server switched off for runs (K-25, K-27).

### Removed

`START-HERE.md`, `VALIDATION.md`, the Python helpers, the scheduled-worker
fixture and skill, the routing sections of the worker docs, the
`operator-handoff`, `worker-profile` and instruction templates, and the
JSON machine-local profile. Their useful content moved into the rules, the
guides and the templates.

### Known issues

- Prompts and relay messages are passed as one command-line argument:
  visible in the process list to other local users while a run lasts, and
  capped at 120000 bytes.
- Logs under the state directory grow without bound; rotate them with your
  OS tools.
- A timeout reported by coreutils `timeout` as exit 137 is reported as a
  timeout even when the cause was a manual `kill -9`.
- A registry home reached through a symlink produces a different
  transcript slug, so the watchdog reports `no-transcript` for it.
- A failed Codex run's failure note can include the start of the prompt,
  which Codex echoes to stderr.
- `cross-review.sh`, Claude-side runs, `install.sh` on a clean machine,
  systemd units and Linux are not yet proven outside the test suite (see
  the README).
- Whether `codex mcp list` reflects a project's own Codex configuration is
  unverified; runs list servers from the run's directory to cover it.
- Not yet built: the advisory pre-push guard for contributors (K-16 is
  convention plus review), `install.sh restore` (rerunning `oracle` and
  `operator` restores what is missing), and the lease, mailbox and
  takeover layer. The registry's session column gives way to the lease in
  0.2.x.

### How the kit evolved

0.1.0 to 0.1.14 were guidance only: a growing set of documents written
after real incidents, each adding a clarification. By 0.1.14 the same
rule could appear in several places with slightly different wording, and
nothing ran on its own. 0.2 keeps the lessons and changes the shape: each
rule is stated once with an ID, the docs explain rather than legislate,
the scheduled parts are small scripts with tests, and the two clients are
peers behind one interface. Recurring findings from the weekly
cross-review are meant to become rule changes here, recorded by ID.

## 0.1.x

### 0.1.14 — 2026-11-17

Make the kit client-agnostic (Claude Code or Codex) around a main operator, detached operators with durable homes and disposable cheap workers. Adopt cross-family adversarial code review with neutral briefs, a three-round cap, verify-only passes and third-model tie-breaks. Route approvals through the main operator, with explicit harness support for relays, no unlocking of denials and no relayed money movement. Add the claims ladder, a security-release exception pattern, mutual-review scope for promotion PRs, schedule stewardship, rule hygiene, unattended-host practices without permission pop-ups, and a new self-hosted CI guide. Source guidance only; no installed configuration changes.

### 0.1.13 — 2026-11-13

Reconcile completed milestones against the full authorized outcome and continue ready work through its existing owner. Keep actual dependencies and parked scope distinct, using the existing handoff and result-return path.

### 0.1.12 — 2026-11-12

Verify that an immediate handoff starts at the intended destination. Carry unresolved handoffs through interruptions using the existing recovery route.

### 0.1.11 — 2026-11-12

Verify the intended source before repository review, preserve the review checkout while it is in use, and refresh the canonical integration checkout at normal maintainer checkpoints.

### 0.1.10 — 2026-11-12

Preserve direct consent, later corrections and a verifiable source when handing a decision to another operator. Carry platform denials across routes and ask again only for the specific direct decision the platform requires.

### 0.1.9 — 2026-11-08

Clarify prompt handback of blocked decisions, checking later replies, exact authenticated confirmation relay and owner consumption. Reuse existing delivery records and preserve action-time consent; no timer, approval queue or spend authority is added.

### 0.1.8 — 2026-11-07

Clarify route addressability, exact-event acknowledgements and scoped denial evidence. Verify the actual consumer loads pinned guidance; unused files and unrelated checkouts do not prove adoption. Source guidance only; no installed configuration changes.

### 0.1.7 — 2026-11-06

Clarify one accountable outcome owner, stable acceptance, early bounded authentication preparation and evaluation on representative outputs across quality, time and cost. Reuse the existing consent, handback and empty-result procedures. Source guidance only; no runtime installation or permission change.

### 0.1.6 — 2026-11-06

Clarify responsive operator returns, evidence for each delivery stage, bounded diagnosis of empty results and native lifecycle acceptance. Check actual capabilities and the smallest effective path before adding infrastructure; preserve clear consent and exact denial scope. Reuse existing receipts and natural outcomes rather than adding queues or repeated demonstrations. Public examples remain synthetic. No installed profiles, security settings, schedules or services change.

### 0.1.5 — 2026-11-03

Tighten external-contract test value and reuse, diagnosis of a common failed premise, and delivery acceptance after a delegated worker exits. Route the existing review skill to these checks. Existing source ownership, valid evidence reuse and authority remain unchanged; no new framework, service, schedule, memory integration or model selection.

### 0.1.4 — 2026-11-02

Clarify intended integration identity and user-persona acceptance, maintainer closure of stale/stacked PRs, meaningful validation and compatible proof reuse, actual cross-account review availability, lightweight meeting-to-work reconciliation, and local adoption evidence. Keep repository-specific choices, machine bindings and private source material outside this kit. No new runtime service, mandatory timer or expanded authority.

### 0.1.3 — 2026-10-28

Publish the reviewed outcome-alignment, request-privacy and scheduled-routing amendments accumulated since 0.1.2. Clarify scoped readiness, iterative repair capability, existing result ownership, independent release flow, per-source freshness and rollback delivery continuity. Existing review/permissions remain; no new service, timer, status form or runtime activation. Adopt the reviewed full release delta deliberately and verify the next relevant behavior; source publication is not installation or operational acceptance.

### 0.1.2 — 2026-10-17

Resolve independent audit findings: consistent owner-provider delegation, solo/team account examples, acknowledged-delivery/disposal scenarios, explicit profile/version upgrade and rollback records, clear role/model names, and reproducible kit-version checks. No runtime schedules or product effects.

### 0.1.1 — 2026-10-17

Clarify that delegated workers use the owning human’s approved existing provider route, not a subscription per worker. No runtime or permission changes.

### 0.1.0 — 2026-10-17

Initial public operating kit: laptop-first operators/oracle, bounded delegation/review, disposable scheduled workers, release settlement, host transition, four routing skills, templates and offline examples/helpers.
