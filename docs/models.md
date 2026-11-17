# Models

## Principles

- Choose a model and effort level for each role, and write them down explicitly. No silent model switches.
- For code, implementer and reviewer come from different model families; see [cross-family review](delegation-review.md#independent-review). Beyond that, escalate to a stronger model only when there is demonstrated need, such as repeated failures, persistent disagreement or high-risk changes.
- Put frequent, light-judgment scheduled work on the cheapest tier that proves sufficient; see [schedule stewardship](scheduled-workers.md#stewardship). Consider a short head-to-head trial before settling a recurring job's model.
- If you hold subscriptions with more than one provider, route work so each is used for what it does best, within each one's approved scope.
- Before changing versions or catalogs, check the provider's official documentation. Confirm that the model exists, your plan includes it and the rollout has reached you.
- Do not claim benchmark results or token savings that you have not measured yourself.
- No client is required to install any particular agent. Use what your organization supports.

## Tested starting example

This is one configuration that has worked in practice. It is not a requirement.

| Role | Example model | Effort |
| --- | --- | --- |
| Main operator and operators | Claude Opus 5.5 (`claude-opus-5-5`) or GPT-6.1 Sol (`gpt-6.1-sol`) | client default or medium |
| Code implementer | Claude Opus 5.5 | medium |
| Adversarial code reviewer | GPT-6.1 Sol | high |
| Planning, architecture and security audits; review tie-breaks | a third, planning-strong model | high |
| Frequent routine or scheduled work | GPT-6 Luna (`gpt-6-luna`) | medium for this bounded example |
| Relay delivery | a small, cheap model, run only when there is something to deliver | client default |

Each delegate uses the owning human’s existing approved subscription/provider route; no separate worker subscription is required. There is no billing fallback; see [delegation-review.md](delegation-review.md).

## Recording choices

Record role-to-model choices in the machine-local profile or in the repository's instruction file. When a model is retired or renamed, update the owning record and note the change in the queue.

These are provider model names, not private role aliases. [OpenAI model guidance](https://learn.chatgpt.com/docs/models) was checked October 17, 2026; the Claude and GPT examples were in use on November 17, 2026. Model access/effort controls vary by account/client. Luna’s broader recommended starting effort can differ from this narrow demonstrated medium example; inspect task quality and escalate for a named reasoning gap. The Opus identifier was verified in the actual CLI route used to prepare/review this kit; recheck CLI model access on another installation.
