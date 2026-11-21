# Client capabilities

The rules ([kit/KIT.md](../kit/KIT.md)) say what must happen, in words that
fit both clients. This page says how each client does it: one row per
operation, so a routine written for one client has a known counterpart in
the other. Each client keeps its own column current; when a client changes,
fix the row here, not the rules.

**Evidence levels.** *Used*: the kit's scripts or tests exercise it.
*Schema*: seen in the client's tool schemas or documentation on the date
given, not exercised by the kit. *Gap*: no supported way; the routine says
so instead of guessing.

## Operations

| Operation | Claude Code | Codex | Evidence (2026-11-19) |
| --- | --- | --- | --- |
| Message a session in the same app | `SendMessage` to the session id | `send_message_to_thread` (no mode: the caller decides steer or queue) | Used (mailroom tier 1 and 2) |
| Model-free delivery to a warm session | The session's local peer socket (opt-in tier 1, [mailroom](mailroom.md)) | The bridge-owned watcher on the app's tool server | Used against fakes; undocumented interfaces |
| Wait for another session's turn to end | A peer message is absorbed at the session's next tool boundary | `wait_threads` (a bounded native completion wait, allowed by [K-23](../kit/KIT.md); recurring checks stay in scripts) | Schema |
| List and read sessions | The desktop app's session tools | `list_threads`, `read_thread` | Schema; `read_thread` used by the watcher |
| Create a session with its model | Create the session with the model and effort chosen then | `create_thread` with `model` and `thinking` | Schema |
| Change an existing session's model | The app's own model setting | **Gap**: no silent setter or readback; per-message overrides also send a prompt, so the kit never uses them. Create a new thread with the model and switch | Schema |
| Pin, or move to a sidebar section | The desktop app's sidebar tools (pin; section "Inactive Operators") | `move_thread_to_sidebar_section`; read back with `list_threads` | Schema |
| Read files | `Read` | Shell reads | Used |
| Recovery after compaction | `SessionStart` hook, matcher `compact\|resume` | `SessionStart` hook, sources `startup\|resume\|compact\|fork`; non-managed hooks must be trusted | Claude: used; Codex: schema |
| Recovery output limit | Output over about 10 KB becomes a short preview (observed, not documented) | Guide asks for about 2,500 tokens | The kit's digest is capped at 8000 bytes (about 2,000 tokens) |
| Instructions loaded | `CLAUDE.md` (the kit's imports `AGENTS.md`) at session start | `AGENTS.md` discovered at run start, about 32 KiB combined by default; linked files are not imported | Schema |
| Timed jobs | OS timers; the app's scheduled tasks; session crons (gone with the session) | OS timers; automations: a thread heartbeat or a standalone cron with its own model and effort, inspected with `automation_update` in view mode | Schema; OS timers used |
| Permissions | `permissions` allow, ask, deny in settings | Sandbox mode, approval policy and rules | Used (settings patterns) |

## Recovery on both clients

One renderer, `scripts/recover-context.sh`, prints the same bounded digest
on either client: the read-first order, the rule titles, and the
operator's `## Current state` block of `NOTES.md` (never a tail of the
history). Each client registers it its own way
([settings patterns](../templates/home/settings/README.md)). A registered
hook is not proof: until the live recovery test passes on a client
([TESTING.md](../TESTING.md#mailroom-live-acceptance)), the session re-reads
the read-first files itself after every compaction or resume.

## Models

The model and effort of an operator are decided once, at creation, with the
human, for both clients, and recorded in its `operator.conf`
(`model.<client>`, `effort.<client>`); the profile's `implementer_*` values
are only the defaults offered then. The registry is the one routing source
(which client and session run an operator); `operator.conf` holds the
models. An operator spawns cheaper or stronger subagents as its work needs
but never changes its own model; the one path to change it is
`operator.sh model`, on the human's words ([K-26](../kit/KIT.md)).

## Evidence for app settings

A switch or a routine marks an in-app step with the app's own readback (a
sidebar listing, the model as the app shows it), or with `gap: <why>` where
the row above says there is none. A receipt or an acknowledgement proves
that a message arrived, not that the app is set up
([K-36](../kit/KIT.md)).
