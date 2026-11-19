# Delegation packet

A short handoff is enough for most tasks: **outcome**, **scope and
authority** (a reference: mandate section, ask id), **exact artifact or
head**, **acceptance**, **exclusions**, **return path**. Keep uncertainty
and the one next step in your own notes. Use the full packet below for
delegated builds and reviews.

- **Task:** `<existing task link>`
- **Delegate:** `<model / effort>`; reviewer `<other model family / high effort>`; both on the owner's existing subscriptions. No billing fallback: stop and report on quota or access loss (K-26).
- **Repository and base SHA:** `<repo>` @ `<sha>`
- **Branch:** `<scoped branch>`

## Goal

State the human’s intended outcome and how this task contributes. Apply kit rule K-11; a subtask milestone does not redefine project success.

## Scope

- **In:**
- **Out (do not touch):**

## Acceptance criteria

1.

## Constraints

Declare the actual task boundary here. Example implementation scope: return a tested commit; no merge/deploy, credentials, task-triggered paid API calls or UI control. The approved provider route for this delegation is recorded above, not a grant for additional product/provider calls.

## Stop criteria

- All acceptance items pass, or you are blocked and report why.
- Round limit: `<n, example 3>`. After it, park minor findings with an owner and escalate major ones; a verify-only pass on the last fixes is allowed.

## Return format

Return the implementer notes below, or reviewer findings.

## Handoff to the merge owner

When this work reaches the repository's merge owner as a pull request
(K-16), fill this in the pull request body.

- **From operator / branch:**
- **Base and head SHA:**
- **Review:** rounds, reviewer family, open findings and their dispositions
- **Activation needed:** none, or see the release record

---

## Implementer notes

- **Head SHA:**
- **Changed:**
- **Tests run and results:**
- **Skipped, with reason:**
- **Known gaps:**

## Reviewer findings (at head SHA `<sha>`)

| # | Location | Severity | Evidence | Acceptance item | Disposition |
| --- | --- | --- | --- | --- | --- |

Allowed dispositions:

- **Fixed:** cite the commit SHA.
- **Rejected:** give a reason.
- **Deferred:** name an owner and a link.
