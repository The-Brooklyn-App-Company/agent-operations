# Changelog

Entries are keyed by rule ID ([kit/KIT.md](kit/KIT.md)). Rule IDs started
with 0.2.0; 0.1.x guidance had none.

## Unreleased

## 0.2.0-rc1 (2026-11-17)

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
