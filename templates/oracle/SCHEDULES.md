# Schedules

Every timed job, wherever it runs (K-24). Review weekly: drop stale or
duplicate jobs, move jobs to a cheaper tier where one works.

| Job | Where it runs | Cadence | Owner | Model | Cost tier | Added |
| --- | --- | --- | --- | --- | --- | --- |
| tick (watchdog, hooks, relay, mailroom supervisor) | OS timer, at load | every 10 min | oracle | none; a model only for a fallback or re-arm | free | @DATE@ |
| relay unit (`mailroom.sh cycle`) | OS timer, at load | on inbox change and every 60 s | oracle | none; a model only for a fallback or re-arm | free | @DATE@ |
| cross-review (K-22) | tick hook, hourly | each operator once a week | oracle | reviewer roles | strong models, weekly | @DATE@ |
