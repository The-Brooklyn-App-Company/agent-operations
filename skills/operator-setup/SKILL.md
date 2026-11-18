---
name: operator-setup
description: Use when setting up Agent Operations (an Oracle home or a new operator) or re-checking an existing setup. Not for routine repository work.
---

# Operator setup

`<kit>`: two levels above this skill's real path
(`install.sh skills` links it there). Stop if it does not resolve.

1. Read `<kit>/README.md` and `<kit>/docs/operators-and-repos.md#install-and-bootstrap`.
2. Inventory first, read-only: existing homes, the registry, the profile,
   timers, sessions and signed-in clients. Reuse what exists.
3. Run `<kit>/scripts/install.sh --dry-run oracle <home>` (or `operator
   <key> ...`) and show the human the list.
4. On the human's yes, run it without `--dry-run`; it never overwrites.
5. Have the human fill in the profile and put any token in the OS secret
   store themselves (`<kit>/docs/profiles-and-integrations.md`).
6. Fill in `MANDATE.md` from the human's own words (`<kit>/templates/home/MANDATE.md`).
7. Leave `settings/` for the human to apply in each client.
8. Run `<kit>/scripts/check.sh home <home>` and `<kit>/scripts/status.sh`.
9. Give the human the printed timer command; do not load timers yourself.
10. Record what was created in the Oracle's journal.
