# v0.3.1 validation

Release remains maintainer-owned. This release adds the experimental
mailroom with per-side degradation ladders, tier telemetry, version
fingerprints and canaries, unknown-send reconciliation and Codex thread
recovery; the guided first run (`bootstrap.sh`) over the turnkey
`install.sh host --apply`; the operator routines (`operator.sh`) and lane
switching (`lane.sh`) as scripted checklists; the nightly `hygiene.sh`;
client-neutral recovery with a bounded current-state block; and rule edits
(K-05, K-07, K-09, K-10, K-11, K-12, K-13, K-24, K-26, K-28, K-29, K-32
changed; K-35, K-36, K-37 added). Everything below is
deterministic tests with fakes on one macOS machine; nothing in 0.3.1 has
run live yet.

| Check | Evidence / result |
| --- | --- |
| Full suite, sh and dash | PASS: all 18 files under sh and dash, 346 cases per shell (692 in all), macOS, 2026-11-19; no network, no model calls |
| New tests | `t_mailroom.sh`: Claude tier 1 against a fake peer socket (warm delivery with the session's receipt, cold target and kill switch handed to the bridge with the step, a mention that is not a receipt, claims a dead watcher left), the Codex watcher queueing on a turn-complete line of a fake rollout (no read for unrelated lines, release with `no-rollout` or `queue-cap`), tier rows with latency and step, metrics with tier shares and p50/p90, fingerprint and canary (one alarm per cause, unique canary names), the degradation alarm and its clearing, tier 4 push once per outage, the Claude app restart waking the bridge then returning to the Oracle. `t_lane.sh`: a switch through every step, refusals, cold handoff, ACK by token from the right client, holds with owner and expiry, the mailroom pause, the Oracle lock, hygiene's grants-against-permissions diff. `t_install.sh`: `host --apply` with a fake `launchctl` (units installed, loaded, stale units and duty files replaced with a backup, in-app steps marked done). `t_mailroom.sh` also: unknown Codex sends reconciled against the target's rollout (late receipt settled, absence escalated once, an unconfirmed escalation alarmed and stopped, metrics). `t_operator.sh`: create with both clients' models decided at creation, refusal without a model decision, the owner-only model change (refused without words or from the operator's own session), archive to verified bundles with the row retired last, an unresponsive thread detected and revived, a dead one replaced with the lane switch opened. `t_bootstrap.sh`: the unattended first run (home, profile, the Codex app paths found, host, toehold, lock, checklist through the test note's delivery), invalid choices refused. `t_recover.sh`: the current-state block instead of a notes tail, the Codex sources, `clear` silent |
| shellcheck, `check.sh kit` | Clean; `kit/KIT.md` is within its 11000-byte budget |
| Cross-family review | Earlier design: three rounds (13, 7 and 6 findings), all fixed. Final design: two rounds by the other model family through `review-run.sh` (8 findings, then 6), all fixed with regression tests; round-2 fixes not re-reviewed (round cap for this release) |
| Live mailroom | **Not run** (below) |

## Mailroom live acceptance

Run on the always-on host with both desktop apps and both Mailrooms set up
([docs/mailroom.md](docs/mailroom.md#set-it-up)). Record the client
versions, the delivered-log rows and the times (in your local timezone).

| # | Do | Expect |
| --- | --- | --- |
| T1 | With an operator's Claude session cold (no process since the last app start), drop a note for it | Tier 2: the bridge sends to its session id; the session starts and reads the pointer; the row says `t2-bridge`, step `cold-target` |
| T2 | With `wake_link` set (or your `hooks/wake`), let the supervisor warm a cold session | The session gets a process; the window returns to the Oracle about 2 s later |
| T3 | After T2, let the supervisor's headless "Re-arm" reach the bridge | The bridge's watcher pid appears in `.watcher/pid` |
| T4 | Quit each desktop app while idle and leave it | The supervisor opens it again, re-arms its bridge once, and `mailroom.sh status` shows the watcher armed; time it. Then one round trip each way across the apps |
| T5 | With `bridge_claude_t1=socket`, drop a note for a warm Claude operator | A `t1-socket` row within seconds; no bridge turn |
| T6 | Drop a `steer` and a `queue` note for a busy Codex operator | The steer lands mid-turn; the queue note arrives about a second after the turn completes (`t1-native`, mode `queue`) |
| T7 | Turn on the Claude kill switch and send two notes to warm sessions; after a client update, watch the next supervisor pass | Both delivered at tier 2 with step `kill-switch` (no alarm: neutral); after the update, one canary row from the first tier |
| T8 | With the Oracle's app quit and an alarm pending, wait 15 minutes | One push through `hooks/push` or the chat adapter; none repeated |
| T9 | Switch one low-risk operator to the other client with `lane.sh switch` and `verify` | Every step passes, each in-app mark carries the app's readback; the incoming session's ACK names its client |
| T10 | On a clean user account, run `bootstrap.sh` from inside the client you start with and follow it to the end | Every checklist step passes; the test note reaches the Oracle; count the in-app steps you did |
| T11 | Rehearse thread recovery on a scratch Codex thread registered as a throwaway operator: make two sends time out (or mark it by hand), then let the supervisor run | A queued no-op and, if needed, a native no-op; on no answer, the replace request; after `--replaced`, the lane switch opens and closes |
| T12 | Register the recovery hook on Codex (trust it), then compact or resume an operator thread | The digest arrives before the next turn, under its cap; if not, record the gap in client capabilities and keep the re-read |

---

# v0.3.0 validation

Release remains maintainer-owned. Evidence below separates deterministic tests,
actual installed CLI use, an existing-account live recipient, and unrun paths.

| Check | Evidence / result |
| --- | --- |
| Final stable-code suite | PASS: all 13 files under sh/dash, 279 cases per shell; final relay/mail/tick/install regressions add three distinct cases per shell, giving 282 final cases per shell across the two invocations |
| Repaired acquisition race | PASS: 50 independent dash invocations × five races = 250 races, plus five sh races; exactly one winner and one refused loser in each race, emitted token matches final lease |
| Deterministic guard regression | FAILS before repair with a false permissions error; PASSES after repair under sh and dash. Real unwritable parent still fails promptly; persistent creation failure remains bounded and fail-closed |
| Fresh Oracle profile templates | PASS: four isolated HOME/profile installs and home checks for claude-only, codex-only, both and custom; no models/network in these template tests |
| Real-binary clean-HOME proof | PASS, macOS November 18, 2026: real Claude Code 2.1.322 and codex-cli 0.169.0-alpha.11.1 version-only calls, Oracle and embedded operator install/home checks, real worktree helper and exclusion readback; no sign-in or model calls in this phase |
| Ordinary Codex relay | LIVE recipient read/ack observed: installed isolated kit profile → real CLI queue → existing native app thread → exact archived-fixture/relay-ID acknowledgement. Recipient turns use the existing Codex subscription |
| Experimental lease-mail doorbells | FAKES ONLY; LIVE UNRUN for both Claude and Codex. Ordinary relay proof does not verify either doorbell |
| PR watcher | PASS fake cases for baseline/change/error/recovery/state custody; live bundled GraphQL polling unrun, bounded windows/no-closure coverage explicit |
| Worktree helper | PASS fake failure/custody tests plus actual macOS scratch canonical repo and excluded child; temporary filesystem exclusion is not proof of backup restore |
| Independent technical fix review | CLEAN fresh independent same-family, different-model final review in two rounds; routing, guard repair and both final configuration P2 fixes verified. Maintainer release authority remains |
| Kit links/skills, shellcheck, whitespace | PASS final kit links/skills, full shellcheck and whitespace checks |
| Local privacy scan / independent privacy read | PASS deterministic local scan and independent public-only review of all 19 changed files; no findings. Private denylist stays outside this public checkout |
| Separate clean machine/user account | NOT RUN. Installed binary and existing-account app proof above are narrower |
| Planned next-day switch-back | PENDING live lease/routing/job-custody/readback test; source-file recovery and paused-state acceptance must not be inferred from a plan |

## Lease failure disposition

An earlier independent full run reported one failure in the two-acquirer test
under dash, then two 40-case lease reruns passed. That original failure retained
no contender streams. New instrumented stress reproduced three failures in the
28th dash invocation: each race still had one winner, but a losing process
returned a permissions error rather than the normal refusal. No double holder
or losing token was observed.

The guard directory could disappear after a failed atomic `mkdir` and before
its existence check, so transient contention was mistaken for denied access.
The repair retries that vanished-guard window within the existing bound, keeps
real unwritable-parent failure prompt, and never removes another holder's guard.
The new deterministic regression fails before and passes after the repair.
Strict winner/token/final-lease and no-loser-output assertions remain; no return
code was broadened merely to make stress green. The final 250 dash plus five
sh races all passed on unchanged source hashes. This is bounded tested evidence,
not a claim that every possible interleaving is proven safe.

## Live proof limits and cleanup

The transport command was explicitly bound to the actual installed Codex binary.
The portable profile's HOME-relative Oracle path was explicitly bound to the
absolute isolated fixture home when the delivery phase used the normal existing
app context. No credential was copied into the fresh HOME. The queue command
returned a resume warning; a later actual recipient turn independently read and
acknowledged the fixture. Its success is not inferred from the CLI status alone.
The disposable app thread was archived, its linked seat was removed without
force, and owned temporary roots were removed after preserving private evidence.
No real lane route, grant, scheduled job, service or account was changed.

The default-on Codex relay and explicit `relay_codex=off` are both fixture-tested,
including custody preservation and actual-session-ID requirements. Both lease
mail doorbells remain separately opt-in/unrun live. Native job application,
capability rendering/doctor, managed-app reconciliation and lifecycle adapters
are dated design/roadmap items, not shipped automation. Enclosing Git history
identifies the returned review artifact; maintainer approval gates publication.

---

# Testing the experimental handoff layer

The lease, mailboxes, approvals ledger and takeover
([docs/handoff.md](docs/handoff.md)) are **experimental**. This page
says how to test them: the automated suite, then a live test on one
low-risk operator. The automated suite sends nothing outside your machine;
the live test uses your two clients (their own model requests), one
headless review in step 13, and, if your profile's `chat` slot is set, a
doorbell fallback notification through it.

## 1. Automated suite (no models, no network)

```sh
tests/run.sh                       # every test, under sh and dash
tests/run.sh tests/t_lease.sh tests/t_ask.sh tests/t_mail.sh   # this layer only
shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh
```

The takeover, settle and unlock tests drive a pseudo-terminal with
`script(1)`; they take about two minutes per shell.

## 2. Live test on one operator

Pick an operator whose work is low-risk (no deploys, no external writes
during the test) and which has a session on each client. Below its key is
`demo` and its home `~/ops/demo`; replace both. Keep a terminal open in the
home. `K` is your kit checkout:

```sh
K=~/src/agent-operations; H=~/ops/demo; cd "$H"
```

### Prepare (once)

1. `.operator/` must be git-ignored in the home: `git check-ignore -q .operator/lease && echo ok`.
2. Apply the settings patterns from
   [handoff.md#settings-patterns-apply-them-yourself](docs/handoff.md#settings-patterns-apply-them-yourself)
   to both clients (Claude Code deny rules; Codex rules file).
3. `$K/scripts/lease.sh init` and `$K/scripts/lease.sh status` (expect
   `lease: none`).
4. Add to the operator's `AGENTS.md`, for this test: "Start every turn with
   `lease.sh renew --instance <token> --epoch <n>`. If it is refused, you are
   the standby: do no work, reply with `lease.sh redirect --provider <your
   client>`, and forward a direct human message only with `mail.sh forward
   --via <your client>`. Then run `mail.sh claim`."
5. For a Codex session, either allow it to commit in the home (approve the
   escalation when asked) or expect `release`, `ask.sh` and committing the
   audit report to fail there: its `workspace-write` sandbox makes `.git`
   read-only.

Record every step's result (pass, fail, surprise) in the operator's notes.

### Steps

| # | Do | Expect |
| --- | --- | --- |
| 1 | In the **Claude** session: "Run `lease.sh acquire --provider claude --session '<its name>'` and keep the token." | `acquired`, `epoch: 1`, a token. `status` in your terminal shows the holder and `client process: pid ... live` |
| 2 | Ask the Claude session to run `lease.sh takeover --expect-epoch 1 --holder-stopped --provider codex --session x` | Denied by Claude Code's permission rule (the command never runs) |
| 3 | In the **Codex** session, send a plain request ("please update the changelog") | It runs `renew` (refused), replies "demo is held by claude ... Go there.", forwards your message once. `ls $H/.operator/inbox/new` shows one file |
| 4 | Send the same text to Codex again | "already forwarded"; still one file |
| 5 | Back in Claude, start a turn | `mail.sh claim` shows the forward, marked as notification. It does **not** start the changelog work by itself; it tells you and acts when you say so in this thread. Ask it to `ack` |
| 6 | Ask Claude to file a dummy ask: `ask.sh new --action noop --target test --revision 1 --risk none --rollback none`. In the **Oracle** thread, approve it in words; the Oracle runs `ask.sh approve demo-1 --words "<your words>"` | Row in `ASKS.md` (open) and in the Oracle's `APPROVALS.tsv`, both committed |
| 7 | Claude: `ask.sh reserve demo-1 --target test --revision 1 -- true` (the command stands in for the effect) | `reserved` then `used`, both committed; a second `reserve` is refused |
| 8 | Ask Claude to run, in the background: `lease.sh dispatch-run --instance <token> --epoch 1 --what test -- sleep 600`. In your terminal, `lease.sh status` shows the marker and its pid; pause it: `kill -STOP <pid>` | `status` shows the marker `stopped` |
| 9 | Close the Claude session. In **your terminal**: `$K/scripts/lease.sh takeover --expect-epoch 1 --holder-stopped --provider codex --session '<codex name>'` | Refused: dispatch marker exists (and, while the Claude process lives, its client process too) |
| 10 | `kill -KILL <pid>`; `$K/scripts/lease.sh settle --marker <id> --outcome not-landed` (type the confirmation) | Settled; marker moved to `settled/` |
| 11 | Run the takeover again; type the confirmation | Cold note committed (`git log -1`), lease `assigned` to codex, epoch 2 |
| 12 | In Codex: "Acquire the lease: `lease.sh acquire --provider codex --session '<its name>'`" | Prints **REQUIRED FIRST STEP: switch-in audit**; `dispatch-begin` and `ask.sh new` refuse until `audit-done`; `$K/scripts/status.sh` shows `pending` in the AUDIT column |
| 13 | With a `reviewer_codex_model` in the profile, in your terminal: `$K/scripts/cross-review.sh --key demo` (one headless model call) | `audits/switch-in-lease-<generation>-2.md` in the home, starting with the audit line; a note in the operator's inbox |
| 14 | Ask Codex to run `lease.sh audit-brief` (it lists that report), triage every finding in it (or write its own report, starting with the brief's first line), commit it and run `audit-done` | `switch-in audit recorded (lease, claude -> codex)`; dispatch now allowed; `lease.sh status` shows the report path and commit; `status.sh` shows `done` |
| 15 | Re-open the old Claude session and send any message | Its `renew` fails; it redirects to Codex and does no work |
| 16 | Approval from step 6 (if unused, file a new one in epoch 1 first) | `reserve` in Codex is refused: approvals do not cross a takeover |

### Afterwards

- Warm handback (optional): Codex writes `HANDOFF.md` from `lease.sh note`,
  runs `release`; Claude acquires (another switch-in audit is required).
- Registry switch without a lease (optional, on an operator with no
  `.operator/lease`): run `$K/scripts/cross-review.sh --key <key>` once so
  it records the operator's family, change its registry `client` column to
  the other family, run it again, and expect
  `status.sh` to show `pending` and a report in its `audits/`; after the
  session commits it, `$K/scripts/lease.sh --home <home> audit-done --report
  <path>` records it and `status.sh` shows `done`.
- To stop testing: remove the `AGENTS.md` lines; `rm -rf $H/.operator`
  removes the lease, mailbox and markers (a later `acquire` starts a new
  generation).
- Report: which steps passed, any surprise, and the client versions
  (`claude --version`, `codex --version`), so the validation table in
  docs/handoff.md can be dated.

## 3. Second client and drift

On your real setup, read-only first: `$K/scripts/status.sh --drift` lists
what differs between the clients. Then `$K/scripts/install.sh --dry-run
sync codex` (or `claude`) shows what would be added; run it without
`--dry-run`, start and name each session as printed, apply
`settings/handoff.md` yourself, and rerun `status.sh --drift` until it
prints `no drift`. Expect nothing overwritten and one commit per home.

## What this does not test

Experimental lease-mail doorbells reaching a live session (both are fakes
only; the ordinary registry relay has separate live evidence above), the interactive
permission prompt of either client, multi-machine use, automatic failover.

## Complete final test coverage

`tests/run.sh` passed all 13 files under both shells after the guard repair:
279 cases per shell. The last two review fixes affected relay startup validation
and addressability only; the subsequent command
`tests/run.sh tests/t_relay.sh tests/t_mail.sh tests/t_tick.sh tests/t_install.sh`
passed 97 cases per shell, including three additional relay cases. Two existing
lease-routing functions were also rerun successfully per shell. Together these
cover 282 distinct final cases per shell; duplicate reruns are not extra tests.
Unchanged long-running lease cases were not needlessly replayed for relay-only
input validation changes. All functional edits were complete before final review.
The final staged whitespace, kit links/skills, full shellcheck and private local
privacy scan results are required before the review commit is returned.
