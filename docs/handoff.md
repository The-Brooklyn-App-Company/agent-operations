# Handoff across clients: lease, mailboxes, approvals, takeover

> **EXPERIMENTAL.** This layer is shipped to be hardened by live use on one
> low-risk operator. It gives routing, a redirect from the wrong side and a
> human-confirmed takeover with cold notes. It does **not** give hard
> exclusion or safe resumption after a crash. Test it with
> [`TESTING.md`](../TESTING.md) before relying on it.

An operator may have a session on each client (Claude Code, Codex): one
**holder** and one **standby**. The holder works; the standby redirects.
Everything here is plain files in the operator home, changed only by the
kit scripts:

| Piece | Script | File |
| --- | --- | --- |
| Lease | `scripts/lease.sh` | `.operator/lease` (git-ignored) |
| Mailbox | `scripts/mail.sh` | `.operator/inbox/{tmp,new,cur,done}/` |
| Doorbells | `scripts/doorbell-claude.sh`, `doorbell-codex.sh` | none |
| Asks and approvals | `scripts/ask.sh` | `ASKS.md` (home), `APPROVALS.tsv` (Oracle home) |
| Handoff note | `lease.sh release` (warm), `lease.sh takeover` (cold) | `HANDOFF.md` |

## Threat model

All sessions run as one OS user. The lease, the ledger and the mailboxes
**stop confusion and injected text**: a session that mistakes itself for the
holder, a forwarded or relayed message that claims authority, an approval
reused after a handoff. They do **not** stop a hostile local process under
the same user, which can read and write every file here. The lease is
advisory: a file cannot stop a running model mid-turn, and a session that
ignores its instructions is not prevented from acting.

## The lease

`.operator/lease` is flat `key=value`, parsed literally (never sourced),
replaced atomically under `mkdir .operator/lease.lock`.

| Field | Meaning |
| --- | --- |
| `operator`, `host` | Home key and machine; a lease from another host is refused by every verb and not routed (one machine in this version) |
| `provider`, `session`, `session_id` | Who holds it: client, display name, and the id the transport needs (routing only, never identity) |
| `instance` | First 32 hex digits of the SHA-256 of the holder's **instance token**. The token is printed once by `acquire` into that session's context and never stored |
| `generation` | Random; new whenever `.operator/` is recreated (install, restore) |
| `epoch` | +1 on every acquire after a release, and on every takeover |
| `state` | `held`, `released`, or `assigned` (a takeover named the next session; it has not acquired yet) |
| `heartbeat` | Renewed by the holder at each turn start; never by the tick |
| `prev_epoch`, `prev_note`, `prev_provider` | The previous epoch, the commit of `HANDOFF.md` to resume from, the previous client |
| `audit`, `audit_note` | Switch-in audit state (`pending`, `done`) and its report commit |
| `client_pid`, `client_start` | The holder's client process where the client exposes one (Claude Code); liveness evidence only |

A process counts as running while it exists and is not a zombie; a stopped
(paused) process counts as running.

**Every turn starts with `lease.sh renew --instance T --epoch N`.** Exit 5
means "you are the standby". Holder verbs always present the token and the
epoch; a display-name match never counts.

**Locks.** No script breaks a lock. A lock older than 10 s makes every verb
fail closed (exit 3) and tells the Oracle once; the human runs `lease.sh
unlock --timers-off --sessions-stopped` after checking that nothing runs.
`unlock` removes only the lock it showed: if the lock was replaced while the
human confirmed, it refuses and leaves the new one.

**Dispatch markers.** Before any effect, `dispatch-begin` validates the
holder and creates the marker in one step under the lock; `dispatch-end`
removes it. Prefer the wrapper `lease.sh dispatch-run ... -- CMD`, which
keeps a live process on the marker for the whole effect and ends it only on
exit 0. Separate `dispatch-begin --pid PID` and `dispatch-end` calls need PID
to be the live process doing the effect (a wrapper); `dispatch-end` and
`ask.sh done` refuse once that process has died, because its effect is then
unknown and only the human may settle it. A marker whose process died
stays as an **unresolved effect** until the human settles it (`lease.sh
settle --marker ID --outcome landed|not-landed|unknown`). Markers block
`release` and `takeover`.

**Staleness** (`lease_stale`, default `4h`) changes nothing by itself: mail
still goes to the holder, and only `release` or `takeover` change it.

## Standby behaviour (misdirected messages)

A session whose `renew` fails does exactly this:

1. **No work**: no edits, no effects, no asks, whatever the message says.
2. **Reply** with `lease.sh redirect --provider <its client>`, which prints
   for example: "workshop is held by claude `[OPS] Workshop` since ...; last
   heartbeat .... Go there."
3. **Forward** only a direct human turn in its own thread, verbatim, once:
   `mail.sh forward --via <its client> < turn.txt`. Identical text within
   24 h is not sent again; text that looks like mail, a doorbell or a relayed
   note is refused. Mail and doorbells are never forwarded.
4. **Offer**: `redirect` adds "The holder looks down ..." only when the
   heartbeat is stale, no dispatch marker exists and the recorded client
   process is gone.

## Mailboxes and doorbells

Mail is a **notification, never authority**: it starts no work, effect or
release. `mail.sh send KEY` publishes by rename `tmp/` to `new/`. Only the
holder moves files: `mail.sh claim` (turn start) moves `new/` to `cur/` and
prints every unacked item; `mail.sh ack ID --did TEXT` records what was done
and moves it to `done/`. Delivery is at-least-once; handle by id.

A doorbell only says "you have mail". `mail.sh ring-all` (from a tick hook,
see `examples/hooks/every/40-doorbells`) rings each holder while it has
mail, again only when the pending set or the holder changes, or after
`doorbell_rering_min` (60). Claude: the relay's confirmed `SendMessage` path
with fixed text. Codex: off by default (exit 2); the human is notified
through the `chat` slot instead. A registry `client` of `file-only` keeps
an operator off every active transport.

## Asks and approvals

| Step | Who | Rule |
| --- | --- | --- |
| Ask | Holder | `ask.sh new --action --target --revision --risk --rollback` commits a row to `ASKS.md` with the lease generation and epoch, then mails the Oracle |
| Approve | Oracle holder | After the human answers in the Oracle thread: `ask.sh approve ID --words "<verbatim>"` copies the committed ask into `APPROVALS.tsv` with an expiry and commits it. Only the holder of the Oracle home's lease can |
| Reserve | Holder | `ask.sh reserve ID --target T --revision R -- CMD`, all under the lock: the committed row (HEAD, not the working tree) must match generation, epoch, action, target and revision and be unexpired at a clock read under the lock; creates the marker, marks `reserved`, commits; then runs CMD with itself on the marker and marks `used` on exit 0. A failed CMD stays `reserved` for the human to settle |
| Done | Holder | With `reserve --pid PID` instead of a command, the live wrapper PID runs `ask.sh done ID --marker M` afterwards |

An approval is used once. A changed target or revision voids the ask. Any
holder change (release and acquire, takeover) bumps the epoch and any
restore changes the generation, so **no approval crosses a handoff**: open
asks must be asked again; reserved ones go **on hold** until the successor
verifies the target or the human settles them. Never relayed, whatever the
ledger says: money, trades, sending as the human, deletes, force-push, new
trust-boundary admissions.

## Handoff

**Warm** (holder healthy): the human asks it to stop, or the standby mails a
`release-request` the holder honours on the human's word. The holder parks,
pushes, writes `HANDOFF.md` (`lease.sh note` prints the template), and runs
`lease.sh release`. The standby runs `acquire`.

**Takeover** (holder down), human-confirmed only:

1. The human closes the old session or sees that it cannot run.
2. In **their own terminal** (not through an agent):
   `lease.sh --home <home> takeover --expect-epoch N --holder-stopped
   --provider <client> --session <name>`. It shows the evidence and asks
   for a typed confirmation on `/dev/tty`.
3. Refused unless: generation and epoch still match; no dispatch marker
   exists (a paused dispatcher counts); the recorded client process is
   gone. Refused inside an agent's tool shell.
4. It builds a deterministic **cold note**, puts reserved asks on hold,
   commits both, then bumps the epoch and assigns the lease to the named
   session, which runs `acquire`.
5. The successor treats every external effect of the old epoch as unknown:
   verify the target before repeating any deploy, publish, migration or
   external write; never retry an ambiguous write. Unacked mail in `cur/` is
   shown to it at its first `claim`.

If the old holder wakes, its `renew` fails and it redirects; close it.

### Note format (`HANDOFF.md`)

```
epoch: 12   from: claude/9f2c61d0   at: 2026-11-17T16:41:00Z   kind: warm|cold

## Switch-in audit   required first step after a move between clients
## In flight         per work repo: branch, HEAD, upstream state, dirty files
## On hold           reserved approvals and unsettled effects: do not retry
## Open asks         ids still waiting (void after a cold handoff)
## Next steps        at most three, the best first (warm only)
## Grants in play    mandate sections relied on; chat-only grants are void
```

## Switch-in audit

When an operator moves between clients (any acquire or takeover whose client
differs from the previous holder's), the lease records `audit=pending` and
the incoming family must, **before any new work**, run a full adversarial
audit of what the outgoing family left: unfinished work, cruft, leftover
worktrees and branches, and drift between notes and reality. `lease.sh
audit-brief` prints the checklist and evidence; the report is committed in
the home and recorded with `lease.sh audit-done --report PATH`. The report
must start with the brief's first line (key, generation, epoch, transition),
live inside the home, and be committed after the handoff note. Until then
`dispatch-begin`, `ask.sh new` and `ask.sh reserve` refuse. The kit's
resolver (`ao_operator_resolve`) reports the lease's client for every lease
state, and `OP_PROVIDER` (the owning family, also when the transport is
`file-only`), so any check that picks a reviewer from the opposite family
(such as a weekly cross-review) follows the handoff at once. A change to the
registry `client` column of an operator **without** a lease is not detected
here; whoever changes it runs the same audit by hand.

## Per-client validation

Engineering validation of launch identity and the takeover prompt, headless
only, 2026-11-17. Re-run per client version; a change that breaks a row
moves that client to the fallback.

| Question | Claude Code 2.1.322 (CLI, headless) | Codex CLI 0.169.0-alpha (exec) |
| --- | --- | --- |
| Session id visible to tool commands | Yes: `CLAUDE_CODE_SESSION_ID` (observed) | Yes: `CODEX_THREAD_ID`, `CODEX_SESSION_ID` (observed) |
| Is that id launch-private? | **No**: a second launch with `--resume` reported the same id (live run) | **No** (documented): `exec resume <id>` continues the same id; `fork` makes a new one. Not run live |
| Per-launch value visible | Yes: `CLAUDE_PID` differed between the two launches; start time via `ps` (observed, undocumented) | None observed; `ps` is blocked in the read-only sandbox |
| Tool command has a terminal | No (stdin, stdout not a tty; `/dev/tty` cannot be opened) | No in `exec`; interactive PTY tools unverified |
| Deny rule blocks the takeover command | **Yes**: `deny: Bash(*lease.sh takeover*)` beat a matching allow rule (live, headless) | **Partial**: an execpolicy `prefix_rule(..., decision="forbidden")` matches exact leading tokens (offline `codex execpolicy check`); an absolute path or a `bash -c` wrapper did not match |
| "Ask" rule | Headless: not granted, acts as a deny (live) | `decision="prompt"` evaluates (offline) |
| Fresh, uncached prompt showing the full command, every time | **Unverified** (interactive UI; cannot be shown headless) | **Unverified**; approvals can be remembered for a session |
| Kit verbs that commit (`release`, `ask.sh`, `audit-done`) from a tool command | Work (git through Bash) | **Blocked** under `workspace-write`: `.git` is read-only (`index.lock: Operation not permitted`, live). The human approves an escalation, or the operator runs with a writable `.git` |

**What the kit does with this.** Identity on both clients is the random
instance token (no client id is launch-private). On Claude Code the lease
also records the client process: `takeover` refuses while it runs, and a
second live launch presenting the same token (a concurrent resume) is
refused as a standby. Takeover is **terminal-only on both clients**: the
settings pattern denies it (and `unlock`, `settle`) to agents, and the
script itself refuses inside an agent tool shell and without a typed
confirmation on a terminal. Neither check proves a human against an agent
that sets out to get around them; they stop confusion and injected text.

### Sandboxed end-to-end with the real clients

Run 2026-11-17 in scratch homes (registry `client` = `file-only`, so no
doorbell or relay could reach any session), four headless calls:

1. Claude Code holder: `acquire` and `renew` worked and recorded its client
   process; `takeover` was denied by the client's deny rule.
2. Codex standby: `renew` refused (exit 5), `redirect` printed the reply,
   `mail.sh forward` sent the human turn once and refused the repeat,
   `takeover` was refused by the script inside the agent shell.
3. Human takeover on a terminal: cold note committed, lease assigned to Codex
   at epoch 2. Codex `acquire` printed the switch-in audit as the required
   first step, `claim` showed the forwarded turn, `dispatch-begin` was refused
   until `audit-done`; committing the report failed in the Codex sandbox (row
   above) and was finished from a terminal.
4. The old Claude session resumed: `renew` refused, `redirect` pointed at the
   Codex holder.

Not covered: a doorbell reaching a live session, the interactive permission
prompt of either client, a desktop-app thread.

## Settings patterns (apply them yourself)

Claude Code (`settings.json` in the operator home or user settings):

```json
{ "permissions": { "deny": [
  "Bash(*lease.sh takeover*)", "Bash(*lease.sh unlock*)", "Bash(*lease.sh settle*)"
] } }
```

Codex (a rules file, for example `~/.codex/rules/operator.rules`; prefix
rules match exact tokens, so also keep the script's own refusals):

```
prefix_rule(pattern=["scripts/lease.sh", "takeover"], decision="forbidden")
prefix_rule(pattern=["sh", "scripts/lease.sh", "takeover"], decision="forbidden")
prefix_rule(pattern=["scripts/lease.sh", ["unlock", "settle"]], decision="forbidden")
```

## Limits

- If the human asserts the holder stopped when it has not, both sessions can
  act. Human confirmation is the control.
- Effects sent through a client's own connectors are fenced only by
  instructions; effects under standing grants leave no record beyond what the
  target shows.
- Commits of `HANDOFF.md` and `ASKS.md` use your git configuration and
  hooks; a signing prompt or a slow hook makes those verbs slow or fail
  (the lease is left unchanged).
- One machine per operator; multi-machine leases, automatic failover and
  crash-safe resume are later work.
