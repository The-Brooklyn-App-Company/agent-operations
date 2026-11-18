# Profiles and integrations

## The profile

Each machine has one profile: a flat `key=value` file outside git (default
`~/.config/agent-operations/profile`, or `AO_PROFILE`). It is parsed
literally, never sourced, so it can hold no code. It says which client runs
each role, with which model and limits, where the Oracle home is, and which
integration adapters to use. Every key and its default is listed in
[scripts/README.md](../scripts/README.md#profile).

Start from one of the shipped profiles and replace every `CHANGE-ME`; an
unset model would silently use the client's default, so the examples fail
loudly instead.

| Profile | For | Review |
| --- | --- | --- |
| [claude-only](../profiles/claude-only.profile) | Claude Code in every role | `same-family` |
| [codex-only](../profiles/codex-only.profile) | Codex roles; default queue relay for actual thread IDs; `relay_codex=off` for passive pickup | `same-family` |
| [both](../profiles/both.profile) | Claude Code sessions, Codex worker and reviewer | `cross` |
| [custom](../profiles/custom.profile) | Any CLI that implements the [custom command contract](../scripts/lib/vendor-custom.sh) | `single-model` |

Codex relay defaults to `relay_codex=queue` for Codex rows with actual owner
thread IDs, including existing rows. `relay_default` and the registry client
select the owner route; `relay_codex=off` keeps Codex relay passive.
`doorbell_codex=queue` separately enables mailbox doorbells. Both Codex
transports require an actual owner session ID. Ordinary relay has one live
isolated round trip observed on macOS, 2026-11-18, codex-cli 0.169.0-alpha.11.1,
on an existing account/machine; this is not a clean account/machine test and
resume is not guaranteed. Both experimental lease-mail doorbells remain fakes
only, live unrun; see [the capability table](../README.md#what-is-proven).
Off relay mode preserves new notes, interrupted claims and pending state.

## Roles

The kit names capability roles; the profile maps them to clients.

| Role | Needs | When it is missing |
| --- | --- | --- |
| Oracle, operators | A persistent session with tools | Required; nothing replaces it |
| Implementer | A strong coding model | The operator implements itself |
| Reviewer (`reviewer_*`) | Another model family | Same family, fresh context, recorded `review_family=same-family`; with one model only, a second isolated pass, `single-model`. Risky changes then also get a human read ([K-21](../kit/KIT.md)) |
| Cheap worker (`worker_*`) | Headless, read-only, cheap | The smallest model available; with none, tick-only checks |
| Relay (`relay_<client>_*`) | A way to put a note in front of a named session | `file-only`: the session reads its inbox at turn start |

A missing role is one note in the Oracle's inbox, never a silent
substitution ([K-26](../kit/KIT.md)).

## Clients

Each harness is one file, `scripts/lib/vendor-<client>.sh`, with three
functions: `run` (one boxed headless run), `deliver` (put a note in front of
a session, confirmed) and `activity` (when the session last did anything).
Adding a client touches nothing else. What each client does today, and how
it was verified, is in [scripts/README.md](../scripts/README.md#clients).

| Concern | Claude Code | Codex | Kit handling |
| --- | --- | --- | --- |
| Instructions | `CLAUDE.md` | `AGENTS.md` | `AGENTS.md` canonical; `CLAUDE.md` imports it |
| Permissions | Allow and deny rules, plus a classifier that can reject relayed approvals | Sandbox level plus approval policy | Grants live in mandates; the human applies a per-client pattern from `settings/`; a denial is reported verbatim ([K-02](../kit/KIT.md)) |
| Scheduled work | Native scheduled tasks | Native automations, headless runs | The OS scheduler by default; native tasks are listed in `SCHEDULES.md` too |
| Messaging a session | A headless run can message a named session (verified, see the README) | Native CLI queue to an actual thread ID; one isolated live ordinary-relay round trip observed (limits above), no guaranteed resume | Inbox files are the transport; delivery is a convenience on top |

## Integration slots

Five slots, each set in the profile. `none` is always valid.

| Slot | `none` means | Kit ships | Adapter verbs |
| --- | --- | --- | --- |
| `tracker` | `BACKLOG.md` is the tracker | `none`; a Linear sketch in [examples/tracker-linear](../examples/tracker-linear/) | `poll`, `link` |
| `chat` | Inbox notes plus client notifications | `none` | `notify <urgency> <text>` |
| `githost` | Local git only | `none`, `gh` ([git-gh.sh](../adapters/git-gh.sh)) | `pr-poll`, `review-request` |
| `ci` | Run checks locally | via the git host | `status <sha>` |
| `secrets` | The OS secret store (`os`) | `os`, `none`, or an adapter path | `get <name>` |

An adapter is one small script per slot, kept in the team layer; it exists
so the free tick can poll and notify, while agents use their client's own
connectors for judgment work. The contract (output format, exit codes,
timeout) is in [adapters/CONTRACT.md](../adapters/CONTRACT.md). Adapters are
the only kit scripts that use the network.

## Choosing models

Write down a model and effort per role in the profile and change them
deliberately ([K-26](../kit/KIT.md)). Put frequent light work on the
cheapest tier that proves sufficient, and escalate only on demonstrated
need: repeated failures, persistent disagreement, high risk. Before
settling a recurring job's model, a short head-to-head on real inputs beats
a guess; the [model-bakeoff skill](../skills/model-bakeoff/SKILL.md) routes
that comparison. Do not claim savings or quality gains you have not
measured, and check the provider's own documentation that a model exists
on your plan before you depend on it.
