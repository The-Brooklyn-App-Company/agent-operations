# Security auto-ship

**Opt-in, off by default** ([K-33](../kit/KIT.md)). A security fix may merge
without waiting for the owner only where the operator's mandate enables it
and every gate below holds. Otherwise it takes the normal approval path.

## Gates

| Gate | Requirement |
| --- | --- |
| Verification pass | A separate fresh-context run, from the other model family where available, confirms the vulnerability is real and applies here, that its severity justifies skipping the owner, and that the fix resolves it, with a test that fails before and passes after where possible |
| Ordinary review | Clean, by a different run than the verifier ([K-19](../kit/KIT.md)) |
| Exact revision | Both verdicts and CI are bound to one candidate SHA and base SHA; any change voids them. The merge is a host operation conditional on both: a head-SHA match plus an up-to-date-with-base rule, or a merge queue whose result is re-verified. Where the host offers neither, auto-ship is off. The release record with both SHAs is committed before the merge |
| Scope | Mandated work repositories only; a minimal diff; no migrations, major dependency bumps or widened permissions; rollback is one revert |
| Deploy | If merging deploys, the mandate also needs a dated deploy grant; otherwise auto-ship stops at "ready to merge" |
| Recovery precondition | Enabled only where the operator's recovery from an interrupted effect has been proven on that repository, or where the merge has no effect beyond git. Until the continuity layer (experimental since 0.2.1) proves recovery, that means: merges that do not deploy |
| Profile | Not with single-family review profiles ([K-21](../kit/KIT.md)) |
| Record | An immediate heads-up to the owner with the evidence, both verdicts, the SHAs and the rollback |

## Mandate wording

```
## Standing grants
| 2026-12-01 | "Security fixes in app-web may merge without me when every
  auto-ship gate holds; tell me right after." | app-web, merges only, no
  deploys | 2027-03-01 |
```

## Why the recovery precondition

An agent that merges on its own must be able to tell, after a crash or a
handoff, whether its merge or deploy landed. Until that is proven for the
repository, keep auto-ship to effects git itself records.
