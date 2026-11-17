# Delegation and review

## Neutral packets

Delegation uses a written packet built from [../templates/delegation-packet.md](../templates/delegation-packet.md). Any capable CLI agent can run the packet; the packet does not depend on one conversation's memory. It includes:

- The goal
- The exact base commit SHA
- The scope and the paths that must not be touched
- The acceptance criteria
- The constraints
- The stop criteria
- The expected return format

Include only the context that the task needs. Carry the human’s outcome and this task’s contribution to it, following [outcome alignment](roles-and-context.md#keep-the-humans-outcome-fixed). Do not turn an engineering subtask into the project’s success criterion.

The delegated model uses the owning human’s existing approved subscription or provider route; workers do not need separate subscriptions. There is **no billing fallback**. If quota or access runs out, the delegate stops and reports. It does not switch to API keys, a different paid plan or another provider. Changing spend is a separate decision for the human.

## Finite operation budgets

Before launching a finite operation, reserve time for setup, useful work and settlement/cleanup inside the actual authorization window. Recheck remaining time at the launch boundary; a nominal job timeout alone is insufficient.

Nested RPC/CLI polling and final receipt retrieval must share an absolute deadline anchored before the caller starts waiting. Bound each child request by the remaining outer budget, including the last logs/status call; equal numeric client/server timeouts can still overrun when their clocks start at different moments. Preserve cleanup time rather than starting another request that cannot finish within it. Use the existing controller's deadline mechanism, not a second timer service. Fixture acceptance proves the tested budgeting behavior, not live runtime or isolation acceptance.

## Implementation

The implementer works on a scoped branch from the base SHA and returns implementer notes. The notes record:

- What changed
- The head SHA
- Tests run, with their results
- Known gaps
- Anything the implementer skipped and the reason

Before pushing, the implementer runs every locally reproducible, non-effectful check that CI runs within scope, not just the named suite, and records any CI-only checks. The implementer respects its packet’s merge/deploy boundary and does not broaden scope. Usually it returns a reviewed artifact for the operator to integrate. A worker’s exit or returned notes do not settle the requested delivery. The operator checks the actual head and result against the packet’s acceptance, retaining the existing delivery owner and next action for any missing or partial outcome.

## Behavioral checks and reusable evidence

Choose checks that exercise the changed behavior and its failure boundaries through the external contract: a useful check fails when that contract breaks and survives a behavior-preserving refactor. Reuse existing suites, representative fixtures and helpers before adding coverage. Avoid tests that mirror constants or internal calls, and production seams, flags or branches added only for tests; use the existing interface or an established fixture boundary. A failing guard or test is evidence to investigate: repair an incorrect expectation with a documented reason, or repair the behavior; do not delete a protection just to obtain green checks. Before removing a check, name its unique protected contract and the evidence that remains. Apply this to the current change or existing audit candidate, not a new all-repository test inventory.

Reuse accepted evidence when its artifact identity, relevant inputs, environment and test coverage remain compatible. Record which exact commit/artifact the checks exercised and why they apply to the candidate. Re-run affected checks when those conditions change; an unrelated green run or an old approval is insufficient. Source equivalence may justify reuse under the repository's policy, but it must be demonstrated rather than assumed.

## Evidence behind a proposal

Before concluding a useful signal is absent from a public API or entity, inspect the actual adapter/version: normalization or deduplication may have collapsed distinct upstream states. A narrow source/offline proof can establish that mapping; it does not prove real-device intent, API stability or permission for private hooks, capture or new hardware/services.

When recommending a fix, separate its incremental benefit on the recent failure/feedback cohort from its total historical replay gain. An older-coverage improvement may still be justified without solving the newest misses. If recent evidence is absent or too small, report the benefit as unknown; do not invent zero benefit, require repeated labeling or create another tracker or promotion gate.

## Independent review

For code, use **cross-family review**: one model family implements and a different family reviews adversarially at high effort. Differently trained models agreeing is the useful signal; the work moves when they agree, or once an authorized tie-break or escalation has given every open finding a disposition. The review is truly adversarial but not nitpicking for its own sake.

The reviewer receives the packet's acceptance criteria and the **exact head SHA**. It does not receive the implementer's reasoning, which keeps the findings independent. Brief it neutrally: ask it to find problems, not to confirm that the work is good, and do not lead it toward a verdict.

Before starting a repository review, verify the working directory, repository, branch and commit. For a review of current integration, compare the checkout with the verified integration ref. For a PR or release review, use the intended head even if another branch is newer. If the review needs local changes, identify those changes alongside the base commit.

Keep the review input stable while the reviewer is using it. Coordinate before switching, updating or cleaning that checkout, including changes to uncommitted review inputs. If the intended source differs, use a separate checkout at the intended commit and tell the reviewer which path to use. Treat findings from an older checkout as evidence about that revision and recheck them against the intended source before acting.

Report findings with these fields:

- Location
- Severity
- Evidence
- The failed acceptance item

Review is about the useful delta and its contribution to the human’s outcome. Challenge unnecessary machinery or a substituted milestone with concrete evidence and a simpler safe alternative; do not invent a mandatory pilot or framework. For a consequential launch or repair proposal, also ask whether the actual capability and path will produce the requested result, including any needed repair, result retrieval and cleanup, or only another intermediate proof. Style preferences that the repository does not enforce are not findings.

Every existing finding needs a substantiated disposition:

- **Fixed:** cite the commit SHA.
- **Rejected:** give a reason the reviewer can verify.
- **Deferred:** name an owner and a tracking link.

## Bounded rounds and stopping

Set a round limit in the packet. Three rounds is the example default.

The implementer addresses every major finding, may push back and make the reviewer defend a weak one, and uses judgment on minor ones. Verify any external identifier a reviewer cites, such as a security advisory ID, before recording it; reviewers can cite ones that do not exist. Keep running review rounds until one comes back clean or the limit is reached.

Review stops when either of these is true:

- Every acceptance item passes at the current SHA and no blocking findings remain open.
- The round limit is reached. Park valid minor findings (for example P2/P3) in the backlog with an owner, and escalate unresolved major ones (P0/P1) with a recommendation. A narrow verify-only pass that checks just the last fixes is allowed after the limit; a new major finding there stops the work and escalates.

If the implementer and reviewer keep disagreeing about whether a finding is real, a third model breaks the tie. Product, user-experience and architecture disagreements go to the human.

A new head requires current evidence; use the repository’s stale-approval/content-identity rules. Re-review the affected delta rather than rerunning an unchanged full audit.

## Maintainer integration

The operator shepherds approved work to the repository's accepted integration branch within its actual authority. Inventory open and stacked PRs, their bases, dependencies, current approvals and checks before declaring the work complete. A stale base or unavailable reviewer is a condition to resolve, not a reason to abandon accepted work silently. Rebase or update only within the authorized route, preserve unique changes, and verify the resulting delta and required checks.

At an ordinary handoff or completed integration checkpoint, the repository operator checks the canonical checkout against the documented integration branch. Refresh that branch by fast-forward only after confirming the checkout is on it, clean and idle. Verify the resulting commit. If the checkout is on another branch, switch only when the change is safe and within scope. If another task is using it or it contains uncommitted or divergent work, preserve it and leave the specific exception and next action in the existing handoff. Work that needs the current source can use an isolated checkout while the exception is resolved.

Give each superseded PR an honest disposition: link the accepted replacement and account for its unique work, including any deferred portion and owner. Do not close or merge pending work merely to make the branch list tidy. If integration is outside scope, leave the exact next action and owner in the existing handoff.

An explicit, scoped independent-review or solo exception is an available authorized route. Consume it when its conditions are met instead of waiting indefinitely for an unavailable peer or inventing another approval gate. Record its scope and evidence; retain required checks and release limits. Without such authority, report the actual missing decision.

## CLI examples

A Codex review with a read-only filesystem sandbox, run from the repository with the diff and a neutral prompt:

```sh
codex exec --ephemeral -m gpt-6.1-sol -c model_reasoning_effort='"high"' -s read-only -o review.txt "<neutral review prompt>" </dev/null
```

Always give a CLI agent `</dev/null` (or a file) on stdin; otherwise it can wait on stdin indefinitely. The sandbox governs the model's own commands, not configured MCP or connector tools: run reviews with a configuration that disables effectful tools. Verify `codex exec --help` and model access on your installation.

For an already-approved Claude consultation, use the owner’s existing supported CLI/subscription route. Verify `claude --help` and the actual model available on that installation. A read-only, tool-disabled consultation can use:

```sh
claude -p --model claude-opus-5-5 --effort medium --permission-mode default --system-prompt 'You are a read-only reviewer with no tools. Return the requested review as plain text; do not emit tool calls or write a plan file.' --tools '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' --disable-slash-commands --no-session-persistence < packet.md > review.txt
```

Run in a trusted neutral working directory with a bounded packet; inspect CLI customization/hooks before use. The quoted tool-disabled review route was exercised with this model during the kit audit; verify flags/model access again on a different installation. Tool-disabled print reviews use normal permission mode because a plan-specific workflow can ask for unavailable plan-file/exit tools and fail instead of returning the review. This does not bypass permissions: model tools and MCP servers remain disabled. Inspect returned content as data, not executable tool markup. Do not use `--bare` as a substitute for the subscription route or enable permission bypass. A sandbox-only auth failure is not proof of missing credentials: retry an approved read-only normal-context auth-status check before asking the owner to sign in. Do not print credentials.

Implementation needs a scoped worktree, the relevant source and only the file/command permissions required by its packet. Read-only consultation does not silently grant write/merge/deploy tools. A direct request or approved plan calling for provider collaboration authorizes the needed relevant payload within its actual data/billing scope; do not invent a second export ceremony, and do not assume consent for unrelated exports. Keep credentials out of every packet.
