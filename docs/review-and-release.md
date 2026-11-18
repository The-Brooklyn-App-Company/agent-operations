# Review and release

## Delegation

Delegated work travels as a written packet built from
[templates/packets/delegation.md](../templates/packets/delegation.md), so
any capable client can run it without one conversation's memory: the goal
and how it serves the human's outcome ([K-11](../kit/KIT.md)), the exact
base commit, scope and paths not to touch, acceptance criteria,
constraints, stop criteria and the return format. Include only the context
the task needs.

A delegate uses the owner's existing subscription. If quota or access runs
out it stops and reports; it never switches to API keys, another plan or
another provider ([K-26](../kit/KIT.md)).

The implementer works on a scoped branch from the base commit, runs every
locally reproducible check that CI runs, and returns notes: what changed,
the head commit, tests run with results, known gaps and anything skipped.
A delegate's exit is not delivery: the operator checks the actual head
against the packet's acceptance.

**Useful checks** exercise the changed behaviour through its external
contract: they fail when the contract breaks and survive a refactor. Reuse
existing suites and fixtures; never delete a failing guard just to get
green, and never add production seams only for tests.

## Review

Review is independent ([K-19](../kit/KIT.md)) and bounded
([K-20](../kit/KIT.md)).

1. **Verify the source.** Before a review, confirm the working directory,
   repository, branch and exact commit. Keep that checkout unchanged while
   the reviewer uses it; if you need to keep working, review from a separate
   worktree.
2. **Brief neutrally.** The packet holds the acceptance criteria, the exact
   head and the diff or paths. Ask the reviewer to find problems, not to
   confirm the work, and never pass on the implementer's reasoning.
3. **Run it boxed.** `scripts/review-run.sh <packet> <out> [<worktree>] [<effort>]`
   runs the profile's reviewer read-only, ephemeral, with stdin closed, a
   hard timeout and effectful tool servers switched off
   ([K-25](../kit/KIT.md)). It writes the review only on success, so a stale
   file from an earlier round is never mistaken for a new verdict, and
   prints the `review_family` to record with the result.
4. **Settle every finding** with location, severity (P0 to P3), evidence and
   the acceptance item it breaks; then a disposition: fixed (commit),
   rejected (a reason the reviewer can check) or deferred (owner, link).
   Verify any external identifier a reviewer cites, such as an advisory ID,
   before recording it.
5. **Stop** when a round is clean at the current head, or after three
   rounds. Then park valid minor findings with an owner and escalate open
   P0 and P1 findings with a recommendation. A narrow verify-only pass on
   the last fixes is allowed after the cap; a new major finding there stops
   the work.

Persistent disagreement about whether a finding is real goes to a third
model; product, design and architecture disagreements go to the human. A
new head needs current evidence: re-review the changed part, not an
unchanged whole.

Style preferences the repository does not enforce are not findings. Review
the useful delta and whether it delivers the outcome: challenge unnecessary
machinery with a concrete simpler alternative.

### Running a review by hand

Prefer `review-run.sh`: it applies every safeguard below. By hand, Codex,
read-only and ephemeral, with stdin closed and one
`-c mcp_servers.<name>.enabled=false` for **every** server that
`codex mcp list` shows (the sandbox does not cover tool servers):

```sh
codex exec --ephemeral -s read-only -m <reviewer-model> \
  -c model_reasoning_effort='"high"' -c mcp_servers.<each-server>.enabled=false \
  -o review.txt "$(cat packet.md)" </dev/null
```

Claude Code, headless and restricted, with read-only tools and no tool
servers or hooks:

```sh
claude -p "$(cat packet.md)" --restricted --model <reviewer-model> \
  --tools Read,Grep,Glob --strict-mcp-config \
  --settings '{"disableAllHooks":true}' --no-session-persistence </dev/null >review.txt
```

Check `--help` and model access on your installation before relying on
either.

## Cross-model accountability

On by default ([K-22](../kit/KIT.md)). Each model family has blind spots
the other is better at catching, so every operator's work is also read,
every week, by the family it does not run on: Claude Code operators by a
Codex reviewer and Codex operators by a Claude Code reviewer, and the
Oracle's home along with them.

| Piece | How |
| --- | --- |
| Who reviews | The profile's per-family reviewer roles, `reviewer_codex_*` and `reviewer_claude_*`, chosen from the operator's model family: its lease's provider when it has a lease (experimental), else the registry `client` column. A `file-only` transport never decides it. Each team sets its own models per seat |
| What is reviewed | The last seven days of commits (with patches) in the home and in each repository the operator owns, its `MANDATE.md`, `NOTES.md` and `AGENTS.md`, its worktrees, unmerged branches and uncommitted files |
| What it looks for | Cruft and dead code, drift from the mandate, unfinished or abandoned work, contradictions, risky untested changes, and mistakes the implementing family tends to make |
| Where findings go | The operator's inbox, unless the answer is `NOTHING`; the Oracle gets one digest when the week's reviews are done |
| Triage | The operator settles each finding within a working day, as in [Review](#review): fixed, rejected with a reason, or deferred with an owner |
| Switch-in audit | When an operator moves to the other family (registry `client`, or a lease handoff), the incoming family's reviewer audits the last 30 days once and the report is written to the operator's `audits/`. The incoming session triages it, commits it and records it with `lease.sh audit-done`; until then `status.sh` shows the audit pending and, with a lease, new dispatches and asks refuse ([handoff](handoff.md#switch-in-audit)). The weekly direction flips with the family |
| One family only | A different model of the same family reviews, the result is marked `same-family`, and `status.sh` warns until both families are configured |
| Cost and bounds | `scripts/cross-review.sh` runs from an hourly tick hook and reviews at most `cross_review_per_run` operators per run, each under `cross_review_timeout`, so the week's reviews spread out and never hold the tick for long. `cross_review=off` turns the reviews off; switches are still recorded |

**Learning loop.** At the weekly rule review ([K-32](../kit/KIT.md)), look
across the digests: a finding that recurs becomes a change to a kit rule, a
team rule or a mandate, recorded by ID, never a pile of one-off incident
rules.

## Integration

The operator shepherds approved work to the repository's integration branch
within its authority. Inventory open and stacked pull requests, their bases,
approvals and checks before calling the work complete. A stale base or an
unavailable reviewer is a condition to resolve, not a reason to drop
accepted work. Give each superseded pull request an honest disposition:
link its replacement and account for its unique changes.

At handoffs the owner refreshes the primary checkout by fast-forward only,
and only when it is on the integration branch, clean and idle; otherwise it
records the exception and its next action.

## Release

**Declared in the pull request.** Every pull request says whether it needs
operational work: migrations, configuration, feature flags, jobs, prompt
activation. A change with rollout effects carries its versioned scripts and
tests and fills the activation section of
[templates/packets/release-record.md](../templates/packets/release-record.md):
compatibility, ordering, idempotency, recovery and the permissions needed.

**Promotion** has one owner, the exact source commit and artifact, the
target environment and the ordered activations, recorded in the
repository's existing release record. Do not start a parallel tracker.

**Match the target** before any effect ([K-28](../kit/KIT.md)): service,
account or tenant, project, environment, resource and acting principal, from
read-only evidence on the actual execution route. A valid credential or a
reachable deployment can belong to the wrong target. A mismatch stops the
effect; it does not authorize switching accounts.

**Close out.** The owner executes the plan, verifies the changed production
behaviour, completes each activation and owns recovery until the release
settles. Record each state separately, since each is a different rung of
the claims ladder ([K-10](../kit/KIT.md)): CI green, merged, artifact built,
staging verified, runtime verified, accepted by the intended user through
their real route. An administrator's smoke test proves only what it
exercised.

**Authority.** Release approval covers that release. Production promotion
needs the release owner's yes unless a written standing grant names it
([K-07](../kit/KIT.md)); widening what reaches production without asking
needs the owner's words naming that change. Sign-in, outbound email,
purchases and spend stay separate decisions ([K-03](../kit/KIT.md),
[K-06](../kit/KIT.md)).

**Security fixes** may ship without waiting for the owner only under the
opt-in gates in [the auto-ship example](../examples/security-auto-ship.md)
([K-33](../kit/KIT.md)).

## Teams

Review between people comes from the other person's own account: code
written as `author` is reviewed as `reviewer`. Check that your git host
dismisses stale approvals on a new push rather than assuming it does.
Mutual human review applies to pull requests into the integration branch,
where each change is reviewed once; a promotion from staging to production
carries only already-reviewed changes and needs the release owner's yes. A
solo exception to human review is explicit, scoped and recorded, and keeps
the required checks.
