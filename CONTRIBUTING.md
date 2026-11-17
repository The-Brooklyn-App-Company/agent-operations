# Contributing

Changes arrive as pull requests and are reviewed by someone (or a model
family) other than the author ([K-19](kit/KIT.md)).

## Before you open a pull request

```sh
scripts/check.sh kit                                   # links, skills, duplicate text
shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh adapters/*.sh
tests/run.sh                                           # sh and dash, no network
scripts/check.sh privacy --denylist <your local list>  # never commit the list
```

## Rules for changes

- **One home per rule** ([K-14](kit/KIT.md)). A rule is stated once, in
  `kit/KIT.md`, with a stable ID. Docs explain how to apply it and point to
  the ID; skills route to docs and contain no rules.
- **IDs are stable.** Never renumber a released rule. Retire one by marking
  it `retired` with the release and the reason; new rules take the next
  free number.
- **Changelog by rule ID.** Every pull request that changes behaviour adds
  a line under `Unreleased` in [CHANGELOG.md](CHANGELOG.md), naming the
  rule IDs it adds, changes or retires.
- **Scripts:** POSIX sh, `shellcheck` clean, no sudo, no new OS permission
  prompts, stdin closed on every non-interactive model call, failure paths
  tested. Python only where sh cannot do the job, standard library only,
  run with a pinned interpreter (`/usr/bin/python3 -I`), never a bare
  `python3`.
- **Claims carry evidence.** A behaviour of Claude Code or Codex is stated
  with the client, version and date it was checked, or marked unverified.
  Update the README's "What is proven" table.
- **Privacy** ([K-31](kit/KIT.md)). Fictional names in examples
  (`example.com`, invented people and products). No real people,
  companies, hosts, accounts, paths or incidents. No AI attribution in
  commits or text.
- **Keep it small.** The kit should stay readable in one sitting. Prefer
  removing a rule that no longer prevents a real mistake to adding one
  ([K-32](kit/KIT.md)).

## Releases

The maintainer tags releases. Before every publish: the privacy scan
against a local, uncommitted denylist plus a human read of the diff; a
cross-family review clean within three rounds and a separate privacy-only
pass by a model that has not seen private sources; a clean-machine install
per shipped profile that can be run, others marked untested; `shellcheck`
clean; the "What is proven" table updated.
