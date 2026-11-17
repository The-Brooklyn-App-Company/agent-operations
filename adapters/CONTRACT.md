# Adapter contract

An adapter connects one integration slot (tracker, chat, git host, CI,
secrets) to the free tick, so deterministic checks can poll and notify
without a model. Agents keep using their client's own connectors for
judgment work. Adapters live in the team layer; the kit ships `none.sh`
and `git-gh.sh` as references. They are the only kit scripts that use the
network.

## Calling convention

```
<adapter> <verb> [ARG...]
```

| Rule | Detail |
| --- | --- |
| Input | Arguments only; stdin is closed |
| Output | TSV on stdout, one record per line, a stable ID in the first column; nothing else on stdout |
| Diagnostics | stderr, one line, no secrets (K-05) |
| Exit `0` | Success. Empty output is a valid answer ("nothing new") |
| Exit `2` | Unavailable (network, outage, rate limit): retried next tick, never read as empty |
| Exit `3` | Misconfigured (missing tool, token, project): the caller tells the Oracle once |
| Time | The caller enforces 30 seconds; an adapter must not wait longer |
| Secrets | Fetched with the profile's secrets slot by the adapter itself, at call time; never passed as arguments |
| Effects | Only the verbs below that are effects (`notify`, `review-request`, `link`) change anything, and only what their arguments name |

## Verbs by slot

| Slot | Verb | Output columns |
| --- | --- | --- |
| tracker | `poll` | `id  state  updated  title` for items changed since the last call (the adapter keeps its own cursor under `$AO_STATE`) |
| tracker | `link <id> <url>` | none |
| chat | `notify <urgency> <text>` | none; urgency is `low`, `normal` or `high` |
| git host | `pr-poll` | `number  head-sha  state  review  url` for open pull requests |
| git host | `review-request <number> <reviewer>` | none |
| CI | `status <sha>` | `sha  state  url`, state one of `pending`, `success`, `failure` |
| secrets | `get <name>` | the secret, on stdout only, for the process that asked |

A hook calls an adapter and turns what it finds into inbox notes with
`scripts/inbox-put.sh`; it never forwards adapter output to a model
unfiltered. Test an adapter with `none.sh` as the template for its exit
codes.
