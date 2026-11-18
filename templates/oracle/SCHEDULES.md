# Schedules

Every timed job, wherever it runs (K-24). Review weekly: drop stale or
duplicate jobs, move jobs to a cheaper tier where one works.

| Job | Where it runs | Cadence | Owner | Model | Cost tier | Added |
| --- | --- | --- | --- | --- | --- | --- |
| tick (watchdog, hooks, relay) | OS timer | every 10 min | oracle | none; relay model only when there is mail | free | @DATE@ |
| cross-review (K-22) | tick hook, hourly | each operator once a week | oracle | reviewer roles | strong models, weekly | @DATE@ |
