# Team

The team layer: parameters, team rules and conventions shared by every
member's instance. Changed only by pull request; see the kit's
docs/architecture.md, section Teams.

kit: <kit tag this team is pinned to>
maintainer: <name>
deputy: <name>
away-until:
wait-days: 2

## Review bar

- Code: cross-family agent review (K-19), plus the other person's own
  account for pull requests into the integration branch.
- Releases: the release owner's yes for production.

## Tracker and chat

- tracker: <none | adapter name>
- chat: <none | adapter name>

## Team rules

Each is `T-nn`, marked `required` or `default` (only `default` rules may be
overridden personally).

## Decisions

Dated record of maintainer decisions on ownership, priority and review
deadlocks.
