# Mailroom

**Experimental since 0.3.1.** How messages reach sessions across the two
desktop apps without any model polling, and how the system recovers after
an app restart or a reboot. Commands: `scripts/mailroom.sh --help`.

## One rule

**The relay routes, the bridges deliver, and one model-free supervisor
keeps both bridges armed.**

| Sender and recipient | Path |
| --- | --- |
| Same app (Claude to Claude, Codex to Codex) | Direct, in real time, with the app's own tool (Claude Code `SendMessage`; Codex `send_message_to_thread`). No file, no bridge |
| Different apps, or a script, hook or timer as the sender | A note in the recipient's inbox (`inbox-put.sh`), then the relay, a ring, and the receiving app's bridge |

Messages are pointers only: the relay's fixed-shape message names the
archived note files and a relay id, never the note text
([K-01](../kit/KIT.md); [relay trust boundary](../scripts/README.md#clients)).
A Codex ring is `steer` when a note's file name says `urgent` or `steer`,
otherwise `queue`.

**Lanes are never pre-woken.** A session gets its first turn from the first
message sent to it; nothing pokes idle operators after a restart. Only the
two bridges are kept warm.

## Moving parts

| Part | What it is |
| --- | --- |
| Relay unit | launchd job (`install.sh timers`) running `mailroom.sh cycle`: on any change in a registry inbox folder (WatchPaths), every 60 s, and at login. `cycle` runs `relay.sh`, then `mailroom.sh supervise`, each under its own lock |
| Relay | `relay.sh`: archives new notes and writes one **ring** per hand-off into `<bridge_dir>/<client>/` (default `inbox/.mailroom/`). No model |
| Ring | A file named `<session>--<key>-<stamp>.md` (Codex: `...--steer.md` or `--queue.md`), body = the pointer message |
| Claude bridge | A session on the cheapest model in its own home (`install.sh bridge claude`), whose whole duty is its 15-line `AGENTS.md`. It keeps `mailroom.sh wait claude` running as a background task: a kqueue push watch, zero CPU, no polling, one watcher per folder (an flock, a pid record). The watcher files probe rings itself; for real rings it claims each (an atomic rename into `.watcher/handing/`), prints them and exits, which wakes the bridge. The bridge sends each with `SendMessage` to the session id in its name, then runs one background command, `mailroom.sh file claude <rings> --wait`, that files and logs them and re-arms the watcher. Two tool calls per batch |
| Codex bridge | A chat in its own home (`install.sh bridge codex`) that only keeps the **Codex watcher** armed. No model turn per message |
| Codex watcher | `mailroom-codex-watcher.cjs`, started by the bridge chat with `mailroom.sh arm-codex` from its own command session (not detached), run by the app's bundled node under a kernel lock (one watcher). It opens an MCP connection to the app's bundled `codex-app-tools` server over the pipe the app gives its chats, checks it, then watches the ring folder and sends each ring with `send_message_to_thread` straight to the target thread: `steer` rings at once (they can land mid-turn), `queue` rings when the target's latest turn is no longer running (checked every 5 s only while one is held, released after 10 min). The tool has no mode parameter, so the watcher decides; the mode used is logged per delivery. Each ring is claimed (renamed into `.watcher/sending/`) before its send |
| Supervisor | `mailroom.sh supervise`: deterministic checks every minute (and from the tick). A model runs only when something is down or stuck, and then once |
| Registry rows | The bridges are rows with the reserved keys `mailroom-claude` and `mailroom-codex`: the one file every script reads for their ids. They are never relayed to, watched for stalls or cross-reviewed |

**Delivery is at-least-once.** A pointer can arrive twice (for example
when a stuck Claude bridge sent a ring and the fallback sends it again);
the relay id is the same, so receivers drop repeats. Every sender claims a
ring by an atomic rename before sending, so two paths never send it at the
same moment. A Codex send whose outcome is unknown (a timeout, a crash or a
closed pipe mid-call) is filed `unknown` and never sent again.

**The Codex watcher is experimental twice over:** it relies on an
undocumented pipe the desktop app provides only to commands started inside
one of its chats, and the read-thread result it uses to tell a busy thread
from an idle one is not documented either (an unreadable state sends at
once, logged `queue-unknown`). It dies with the app and is re-armed by the
supervisor after each app restart.

## Timed safety nets

All in the supervisor, outside the relay lock, so a slow fallback never
holds up new notes.

| Ring waiting | Claude | Codex |
| --- | --- | --- |
| Held by a live watcher (queue ring, busy target) | n/a | Left alone, up to the watcher's 10-minute cap |
| 3 min (Claude: also 3 min after the watcher claimed it, if the bridge has not filed it) | `hooks/wake` if present, then one direct delivery through `relay_claude` (a confined headless `SendMessage` run, confirmed from its event stream; the credential is read only inside it), filed as `fallback` | One `codex queue --resume` straight to the target thread (no steering), filed as `queue-direct` |
| 10 min | One alarm | One alarm |

Before a fallback the supervisor re-checks who owns the ring's operator now
(registry, lease, gate): a held operator waits; one that moved to another
session or app gets a new ring there, and the old one is filed `rerouted`.
A failed fallback is retried at most `relay_max_attempts` times, five
minutes apart. An **alarm** is one note to the Oracle and, because the
Oracle's own inbox may need the broken bridge, one `notify high` through
the `chat` adapter when one is configured.

## Restart recovery

| Failure | Detection (script) | Recovery |
| --- | --- | --- |
| Claude app restart | The Claude watcher's pid (`.watcher/pid`) is dead and has not been renewed for 2 min | Once per app process (its pid, from `lsappinfo`): `hooks/wake claude <bridge-session>` if present, then one confined headless run sends the bridge a fixed "Re-arm" message (it carries no mail). Still down 2 min later: one alarm |
| Codex app restart | Once the watcher is deployed (its log exists): its heartbeat is older than 3 min, or its pid is dead | Once per app process: one `codex queue` to the bridge thread, "Re-arm doorbell watcher"; the re-armed watcher catches up on waiting rings. Still down 2 min later: one alarm |
| Reboot or login | `lsappinfo` finds no process for the app; the units run at load | The supervisor opens the app in the background (`open -g -b <bundle id>`, at most once an hour), then re-arms as above once it runs. Both units have `RunAtLoad` |
| Watcher crash | As for an app restart, with the app still running | As for an app restart |
| Bridge stuck | A ring older than 3 min while its watcher looks armed; the hourly echo probe not filed | The 3-minute fallback above; a failed probe alarms |
| Relay crash | Nothing to detect | launchd runs the cycle again; its kernel lock is released when the process dies |

`hooks/wake <client> <session>` is optional and yours: an executable in the
hooks folder that gives a cold session a process to receive, for example by
opening the desktop app's own link to that session in the background. The
kit ships none: such links are not documented and do not submit a prompt.
Whether `SendMessage` to a cold session's id starts it is **unverified**.

## Telemetry and review

- Events: `<state_dir>/mailroom.tsv` (rings, fallbacks, re-arms, alarms,
  probes). Deliveries: `delivered/log.tsv` in each ring folder, one line per
  ring with who delivered it, the mode and the status (`ok`, `accepted`, or
  `unknown` after a call timeout, which is never re-sent).
- `mailroom.sh status`: each watcher's state and waiting rings now.
- `mailroom.sh metrics [HOURS]`: rings, who delivered them, median
  ring-to-delivery time, fallback use, re-arms, alarms, probes. Put the
  24-hour line in the daily digest.
- **Hourly echo probe** (free): the supervisor drops a probe ring for each
  armed bridge; the watcher files it without a send or a model turn; a probe
  still waiting an hour later alarms. Real rings exercise the bridge itself.
- **Weekly robustness review**: the Oracle reads `mailroom.sh metrics 168`
  ([example hook](../examples/hooks/weekly/55-mailroom-review)) and asks:
  did any fallback fire, any re-arm fail, any delivery come back `unknown`?
  Once a path has run clean for weeks, remove what it made redundant rather
  than keeping both ([K-32](../kit/KIT.md)).

## Efficiency

No model where a script will do ([K-23](../kit/KIT.md)): the relay, the
supervisor, the probes and the Codex watcher run no model. The Claude
bridge spends one cheap turn per batch of rings; clear its context daily.
The Codex bridge takes a turn only to re-arm. A headless model run happens
only on failure. The largest cost left is the recipients' own turns: every
note wakes a full session, so batch routine script notes where you can.

## Set it up

1. `install.sh host` (App Nap, folders, units, bridges; see
   [hosts](hosts-and-ci.md#always-on-host)), then `install.sh timers` and
   load both units.
2. `install.sh bridge claude` and `install.sh bridge codex`; start and name
   each bridge session as printed, record its session id in the registry,
   and allow it to run `mailroom.sh` without asking.
3. For Codex, set `bridge_codex_node` (the node binary bundled in the
   desktop app) and `bridge_codex_server` (its `codex-app-tools/server.mjs`;
   find both inside the app bundle), then send the bridge "Re-arm doorbell
   watcher".
4. Check: `mailroom.sh status`, then drop a test note with `inbox-put.sh`
   and watch it arrive.

`relay_bridge=off` turns the mailroom off: the relay then delivers through
the transports directly, as the fallback does. Rows on `custom` clients and
rows without a session id always do.

## What is proven

| Piece | Status |
| --- | --- |
| Relay rings, supervisor, fallbacks, re-arms, probes, metrics, installer, both watchers against fakes | Test suite (`tests/t_mailroom.sh`), macOS, 2026-11-19 |
| The pattern (relay, ring, Claude bridge with a kqueue watcher, `SendMessage` by session id) | Observed in one private deployment, 2026-11-19, about 12 s per ring; not yet this kit's code |
| Codex watcher sending natively, steering mid-turn | One private proof of the transport, 2026-11-19; the kit's watcher is fakes only |
| Restart recovery, `SendMessage` to a cold session, deep-link wake | **Unverified**: the live acceptance tests T1 to T4 in [TESTING.md](../TESTING.md#mailroom-live-acceptance) |
| Re-arm per app process, app relaunch | Test suite with fake `lsappinfo` and `open`; where `lsappinfo` is missing, one re-arm per clock hour |
| Linux | No push watch (kqueue is macOS); the relay timer runs every minute. **Untested** |
