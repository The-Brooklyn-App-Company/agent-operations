# Start here

You can start on your laptop today. Remote hosts, scheduled workers and delegation are optional later stages. Each stage has an acceptance checkpoint. If you approve a setup plan, the agent carries its disclosed reversible steps through those checkpoints without asking again for every command. It pauses only for missing authority, owner-controlled authentication/UI consent, a consequential choice or changed scope.

## What you need

- A laptop with your agent client installed and signed in.
- A git repository you want an operator for.
- An existing conversation you are willing to use as the Oracle or as the operator. Reusing a conversation is better than creating one.

## Bootstrap prompt

Paste this into an existing Codex conversation. Replace the placeholder first.

```text
Adopt Agent Operations v0.1.1 from <local kit checkout, or github.com/The-Brooklyn-App-Company/agent-operations at tag v0.1.1>.
Read README.md, START-HERE.md and docs/roles-and-context.md. If reading remotely, include cloning a local checkout at the pinned tag in the proposed setup and record it as kit.kitRoot before linking skills. Read the other docs only when a step needs them.

Rules for this setup:
- Reading the kit alone grants no authority. Inspect first, propose a concrete setup scope, then carry out the steps I approve without per-command reconfirmation. Preserve existing standing instructions. New recurring work, remote pairing, account changes and domain effects need their actual scope; UI/authentication consent remains separate.
- Inventory first and read-only. Check existing conversations and tasks for this repo, the client and its version, the native tools that are actually available (scheduler, remote connections, skills, git hosting CLI) and the signed-in accounts. Report what exists. Do not assume a universal API or CLI.
- Reuse existing tasks. Propose creation only for real gaps, and label each item as either "existing" or "proposed new".
- Verify accounts read-only. Do not start login flows, open or control UIs, or copy credentials. If something needs sign-in or UI control, tell me exactly what and why, then wait.
- Run supported operations yourself. Do not ask me to run terminal commands for you.
- If a capability is missing, say so and propose a handoff or fallback. Never edit application databases or internal state files to simulate it.
- Follow the staged checkpoints in START-HERE.md and stop at the first one that needs my approval.
```

## Staged walkthrough

**Stage 1: Inventory (read-only).** The agent reports existing tasks, conversations, schedules, client version, available native tools, signed-in accounts and the state of the repository.
*Checkpoint:* Record observed capabilities and gaps; ask only about information that changes setup.

**Stage 2: Roles.** Choose an existing conversation as the Oracle and an existing conversation as the operator for this repository, then pin both. The agent proposes creating a new conversation only if none fits. See [docs/roles-and-context.md](docs/roles-and-context.md).
*Checkpoint:* Verify the approved role mapping and supported creation/pinning; do not create duplicates. If pinning is UI-only, ask the owner to pin it or obtain specific UI consent.

**Stage 3: Machine-local profile.** The agent drafts a profile from [templates/machine-local-profile.example.json](templates/machine-local-profile.example.json). The profile lives outside every repository. It holds credential references, never secrets.
*Checkpoint:* Use an appropriate local untracked location within approved setup and record it. Keep secrets out of the profile.

**Stage 4: Instructions.** The agent merges [templates/global-AGENTS.md](templates/global-AGENTS.md) into your existing global instructions without overwriting local rules. It then proposes a short repository `AGENTS.md` based on [templates/repo-AGENTS.md](templates/repo-AGENTS.md).
*Checkpoint:* Inspect both diffs, preserve local rules and apply within the approved setup; surface real conflicts.

**Stage 5: Skills.** The agent links only the selected skills from a clean pinned local Git checkout. An extracted release tarball can be read but cannot satisfy the link helper’s tagged-Git check. It uses a symlink on macOS and Linux, and a configured kit-root pointer on Windows. See [docs/maintenance.md](docs/maintenance.md).
*Checkpoint:* The agent confirms that the client lists the skills and that each skill resolves the kit root.

**Stage 6: First low-risk task.** Follow [examples/first-task.md](examples/first-task.md). It is a documentation change with no paid provider calls and no runtime effects.
*Checkpoint:* Verify the artifact and normal checks; merge only if the approved task/repository authority includes it. An approval-ready PR is a valid first result.

**Later stages (optional):**
- Delegation: [docs/delegation-review.md](docs/delegation-review.md)
- A scheduled worker: [docs/scheduled-workers.md](docs/scheduled-workers.md)
- Release closeout: [docs/releases.md](docs/releases.md)
- A remote or replacement host: [docs/host-lifecycle.md](docs/host-lifecycle.md)

An approved plan may cover several stages. Do not infer unrelated effects from it or ask the human to reapprove already-covered steps.
