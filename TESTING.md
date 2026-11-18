# v0.3.0 draft validation

Release remains maintainer-owned. The records below separate deterministic tests,
isolated installs and installed-client acceptance. Do not mark pending items green.

| Check | Evidence / result |
| --- | --- |
| Fresh Oracle install plus home check | PASS, November 18, 2026: isolated temporary HOME and AO_PROFILE for claude-only, codex-only, both and custom templates; four install exit 0 and four home-check exit 0; no models/network |
| Full sh/dash test suite | PASS: all 13 test files under sh and dash; 274 cases per shell. Full suite plus final changed-file regression pass, no models/network |
| Kit links/skills and shellcheck | PASS scripts/check.sh kit and full shellcheck; exit 0 |
| Local denylist privacy scan | PASS local uncommitted denylist scan; no findings |
| Independent privacy-only read | PASS final public-only independent read; prior attribution finding fixed; final documentation additions reviewed separately |
| Technical review | PASS independent technical review, clean round 3; maintainer cross-family review PENDING |
| New worktree helper | PASS: 10 cases per shell including nonempty-container custody guard; isolated draft seat excluded on actual macOS host |
| Native Codex delivery | PASS fake queue/owner routing and opt-in doorbell fixtures; live clean-machine kit queue/resume/readback remains unrun |
| PR watcher | PASS: 17 cases per shell for baseline/change/failure/recovery/state custody. Live bundled GraphQL polling unrun; windows and no-closure coverage explicit |
| Clean separate-machine install | NOT RUN for any profile; isolated HOME tests above are narrower |
| Planned next-day provider switch-back | PENDING: prepare COLD HANDOFF notes; after the live test record provider versions, exact lease/registry change, resume-from-files, one pointer/readback and dormant-side suppression. Release need not claim this unrun test complete; follow-up corrections require a patch |

## Final result record

The draft is based on `17281d5`; enclosing Git history identifies the committed
review artifact. No source changed after the final code review. The full
`tests/run.sh` invocation and final `tests/run.sh tests/t_jobs.sh
tests/t_pr_watch.sh tests/t_worktree.sh tests/t_install.sh` regression invocation
both exited 0. Together they cover all 13 test files and 274 distinct cases per
shell, including the final job comparison and watcher-error repairs. Repeated
changed-file checks are not extra distinct tests.

Independent technical review settled three findings: existing nonempty backup
container custody, durable watcher failure/recovery deduplication, and literal
numeric-looking owner/cadence identity. The third bounded round was clean.
Review was same-family with a fresh independent context; maintainer cross-family
review still gates integration/publication. The privacy-only pass has no private
source context; its final doc delta and deterministic gates are recorded in this table.

Queue acceptance, recipient reading, runtime deployment and human acceptance
are separate stages (K-10).

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

Doorbells reaching a live session (the Claude doorbell uses the relay's
confirmed `SendMessage`; Codex has none by default), the interactive
permission prompt of either client, multi-machine use, automatic failover.
