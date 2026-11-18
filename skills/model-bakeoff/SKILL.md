---
name: model-bakeoff
description: Use when choosing or changing the model for a role or a recurring job, by comparing candidates on real inputs before deciding.
---

# Model bake-off

`<kit>`: two levels above this skill's real path.
Stop if it does not resolve.

1. Read `<kit>/docs/profiles-and-integrations.md#choosing-models`.
2. Name the role or job, its current model, and what "good" means for it.
3. Pick three to five real recent inputs, including a hard one.
4. Run each candidate on the same inputs with `<kit>/scripts/worker-run.sh
   --role <prefix>` or `<kit>/scripts/review-run.sh --role <prefix>`.
5. Score quality against the job's need first, then time and cost.
6. Use only the owner's existing subscriptions; no paid API calls.
7. Report the results in a small table with your recommendation.
8. On the human's yes, change the profile and the `SCHEDULES.md` row.
9. Confirm the change on the job's next natural run.
