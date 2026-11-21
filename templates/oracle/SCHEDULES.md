# Schedules

Every timed job, wherever it runs (K-24). Review weekly: drop stale or
duplicate jobs, move jobs to a cheaper tier where one works. Mechanisms
differ by client (OS timer, app scheduled task, session cron, Codex
automation heartbeat or cron): record which, never assume one maps to
another. When moving a job between mechanisms, disable the old one before
enabling the new, and keep a paused job paused.

| Job | Mechanism | Native id | Owner / side | Cadence (timezone) | Model | Cost tier | Paused | Delivery / result | Last verified | Added |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| tick (watchdog, hooks, relay, mailroom supervisor) | OS timer, at load | local.agent-operations.tick | oracle / host | every 10 min | none; a model only for a fallback or re-arm | free | no | Oracle inbox | - | @DATE@ |
| relay unit (`mailroom.sh cycle`) | OS timer, at load | local.agent-operations.relay | oracle / host | on inbox change and every 60 s | none; a model only for a fallback or re-arm | free | no | delivered logs | - | @DATE@ |
| cross-review (K-22) | tick hook, hourly | hooks/hourly/60-cross-review | oracle / host | each operator once a week | reviewer roles | strong models, weekly | no | operator homes' audits/ | - | @DATE@ |
