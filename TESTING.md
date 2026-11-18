# Testing the experimental handoff layer

The lease, mailboxes, approvals ledger and takeover
([docs/handoff.md](docs/handoff.md)) are **experimental**. This page
says how to test them: the automated suite, then a live test on one
low-risk operator. Nothing here sends anything outside your machine.

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
   escalation when asked) or expect `release`, `ask.sh` and `audit-done` to
   fail there: its `workspace-write` sandbox makes `.git` read-only.

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
| 12 | In Codex: "Acquire the lease: `lease.sh acquire --provider codex --session '<its name>'`" | Prints **REQUIRED FIRST STEP: switch-in audit**; `dispatch-begin` and `ask.sh new` refuse until `audit-done` |
| 13 | Ask Codex to run `lease.sh audit-brief`, do the audit, commit the report (starting with the brief's first line) and run `audit-done` | `switch-in audit recorded`; dispatch now allowed |
| 14 | Re-open the old Claude session and send any message | Its `renew` fails; it redirects to Codex and does no work |
| 15 | Approval from step 6 (if unused, file a new one in epoch 1 first) | `reserve` in Codex is refused: approvals do not cross a takeover |

### Afterwards

- Warm handback (optional): Codex writes `HANDOFF.md` from `lease.sh note`,
  runs `release`; Claude acquires (another switch-in audit is required).
- To stop testing: remove the `AGENTS.md` lines; `rm -rf $H/.operator`
  removes the lease, mailbox and markers (a later `acquire` starts a new
  generation).
- Report: which steps passed, any surprise, and the client versions
  (`claude --version`, `codex --version`), so the validation table in
  docs/handoff.md can be dated.

## What this does not test

Doorbells reaching a live session (the Claude doorbell uses the relay's
confirmed `SendMessage`; Codex has none by default), the interactive
permission prompt of either client, multi-machine use, automatic failover.
