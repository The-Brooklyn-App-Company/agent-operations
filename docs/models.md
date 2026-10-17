# Models

## Principles

- Choose a model and effort level for each role, and write them down explicitly.
- Escalate to a stronger model only when there is demonstrated need, such as repeated failures, disagreement or high-risk changes.
- Before changing versions or catalogs, check the provider's official documentation. Confirm that the model exists, your plan includes it and the rollout has reached you.
- Do not claim benchmark results or token savings that you have not measured yourself.
- No client is required to install any particular agent. Use what your organization supports.

## Tested starting example

This is one configuration that has worked in practice. It is not a requirement.

| Role | Example model | Effort |
| --- | --- | --- |
| Regular operator | Sol 6.1 | medium |
| Narrow routine watcher | Luna | medium |
| Delegated implementer or reviewer | Opus 5.5 | medium |
| Escalation | stronger available model | only by demonstrated need |

Each delegate uses the owning human’s existing approved subscription/provider route; no separate worker subscription is required. There is no billing fallback; see [delegation-review.md](delegation-review.md).

## Recording choices

Record role-to-model choices in the machine-local profile or in the repository's instruction file. When a model is retired or renamed, update the owning record and note the change in the queue.
