# Mailroom

**Experimental since 0.3.1.** How messages reach sessions across the two
desktop apps without any model polling, how delivery degrades instead of
stopping, and how the system recovers after an app restart or a reboot.
Commands: `scripts/mailroom.sh --help`. Conventions (titles, pins, one
active side): [conventions](conventions.md). Which tool does what on each
client: [client capabilities](client-capabilities.md).

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
otherwise `queue`. Lanes are never pre-woken: a message is an operator's
first wake. Only the two bridges, both titled **Mailroom**, are kept warm.

## Degradation ladders

Every ring walks its side's ladder ([K-37](../kit/KIT.md)). A broken tier
never stops delivery: the ring drops to the next tier, which is slower,
and the drop is logged on the delivery's row and flagged once per cause
([degradation reporting](#degradation-reporting)).

| Tier | Claude target | Codex target | Drops to the next tier when |
| --- | --- | --- | --- |
| 1, model-free | `t1-socket` (opt-in, `bridge_claude_t1=socket`): the bridge's watcher writes the message to a **warm** session's local socket and confirms the session's own receipt in its transcript within 10 s | `t1-native`: the bridge-owned watcher sends with the app's native `send_message_to_thread`; `steer` at once, `queue` on the target's turn-complete event (it tails the target's rollout file: no status polling) | Claude: a cold target, no or several session records, another peer protocol, no transcript, the rate limit, a connect or write error, no receipt, the kill switch. Codex: a send error (twice), no rollout to tail, a queue target still busy at 10 min, the watcher down |
| 2, bridge model turn | `t2-bridge`: the watcher hands the ring to the bridge session (cheapest model), which sends with `SendMessage`; this also reaches **cold** sessions | `t2-bridge`: the supervisor's one "Re-arm doorbell watcher" turn of the bridge chat; the re-armed watcher's catch-up delivers what waited | The ring still waits 3 minutes |
| 3, headless or CLI | `t3-headless`: the supervisor wakes the target ([restart recovery](#restart-recovery)) and makes one confined headless `SendMessage` run, confirmed from its event stream | `t3-cli-queue`: one CLI queue straight to the target thread (no steering); also, once, for a send whose outcome was unknown and whose ring is confirmed absent from the target's rollout 5 minutes later | The ring still waits 10 minutes, or the escalation is itself unconfirmed |
| 4, alarm | One note to the Oracle per ring or outage | Same | The Oracle has not received the alarm in 15 minutes: one push to the owner (`hooks/push`, else the chat adapter's `notify high`) per outage |

**Proof of delivery.** A ring leaves its folder only into `delivered/`,
with a row. Tier 1 on Claude counts only the session's own receipt (its
enqueue record or the user turn it became), never text that merely
mentions the ring. Every sender claims a ring by an atomic rename before
sending, so two paths never send it at the same moment. Delivery is
at-least-once: the relay id is stable, so receivers drop repeats.

**Unknown outcomes are reconciled, never retried blind** ([K-28](../kit/KIT.md)).
A send whose outcome is unknown (a timeout, a crash, a closed pipe) is
filed `unknown`; 5 minutes later the supervisor reads the target's own
record. Codex: the ring's `Doorbell [<ring>]` text in the thread's rollout
means it arrived (a `resolve` row, `late-receipt`); a readable rollout
without it confirms absence, and the ring goes out once more by tier 3 (a
`resolve` row, `unknown-absent`); no readable record, or an escalation that
is itself unconfirmed, alarms once and stops. Only grep's own "read to the end, absent" counts as absence; a rollout that
cannot be read alarms. The escalation is claimed before the CLI runs, so
one cut off midway is settled `unknown`, never sent twice. Before it the
supervisor re-checks who owns the operator now: a moved owner (a switch, a
replaced thread) gets a new ring, never the retired thread; a queue ring
the watcher holds for a turn to end is taken back and re-rung the same way
(within a supervisor pass, about a minute). Claude: a
tier-1 send whose outcome is unknown keeps its claim; the target's
transcript decides later (a receipt files it, a readable transcript without
one returns it to the next tier, an unreadable one alarms once and keeps
it). An alarm counts as received only when the ring that lists its note is
delivered (`ok`, not a bare CLI acceptance). Rings are never deleted undelivered, so "eventually
delivered" holds as long as tier 4 reaches someone.

**Tier 1 on Claude is opt-in and undocumented.** It reads the target
session's peer key (a per-process, owner-only file the client writes) in
memory only, never logs it, sends only mailroom rings to registry sessions
and the supervisor's canaries to the bridge itself, rate-limits each target
(2 s apart, 10 a minute), and stops at once with the kill switch
`<bridge_dir>/claude/.watcher/t1-off`. A future client build can change
the interface; then tier 2 carries the load and the supervisor flags it.

**Tier 1 on Codex is experimental twice over:** the app provides its tool
pipe only to commands started inside one of its chats, and neither the
read-thread result nor the rollout format is documented. An unreadable
thread state counts as busy (the ring waits for a turn-complete event).

## Moving parts

| Part | What it is |
| --- | --- |
| Relay unit | launchd job running `mailroom.sh cycle`: on any change in a registry inbox folder (WatchPaths), every 60 s, and at login. `cycle` runs `relay.sh`, then `mailroom.sh supervise`, each under its own lock |
| Relay | `relay.sh`: archives new notes and writes one **ring** per hand-off into `<bridge_dir>/<client>/` (default `inbox/.mailroom/`). No model |
| Ring | `<session>--<key>-<stamp>-<random>.md` (Codex: `...--steer.md` or `--queue.md`; a doorbell's key is `.doorbell`), body = the pointer message. Names are never reused. Canaries: `echo--canary-<stamp>.md` |
| Claude Mailroom | A session on the cheapest model in its own home (`install.sh bridge claude`), whose whole duty is its short `AGENTS.md`. It keeps `mailroom.sh wait claude` running as a background task: a kqueue push watch, zero CPU, one watcher per folder. With tier 1 on, the watcher delivers warm targets itself and exits only with the rings it leaves; the bridge sends those and runs one command that files, logs and re-arms. Two tool calls per wake |
| Codex Mailroom | A chat in its own home (`install.sh bridge codex`) that only keeps the Codex watcher armed. No model turn per message |
| Codex watcher | `mailroom-codex-watcher.cjs`, started by the bridge chat with `mailroom.sh arm-codex` from its own command session (not detached), run by the app's bundled node under a kernel lock. Opens an MCP connection to the app's bundled `codex-app-tools` server, checks it, records a fingerprint of its tool list, then watches the ring folder. Queue rings to one target go out in order, each after the target's turn completes |
| Supervisor | `mailroom.sh supervise`, every minute and from the tick: the timed tiers, re-arms, the version fingerprint and canaries, degradation alarms, tier 4. A model runs only when something is down, and then once |
| Registry rows | The bridges are rows with the reserved keys `mailroom-claude` and `mailroom-codex`: the one file every script reads for their ids. Never relayed to, watched for stalls or cross-reviewed |

## Telemetry

Both `delivered/log.tsv` files share one row format, written by whatever
delivered the ring:

```
ISO-time  epoch  ring  tier  mode  status  latency-ms  step
```

`tier` is `t1-socket`, `t1-native`, `t2-bridge`, `t3-headless` or
`t3-cli-queue` (`none` for a reroute); `mode` is `send`, `steer`, `queue`,
`canary`, or `resolve` (a later row settling an `unknown` one, counted
apart from deliveries); `status` is `ok`, `accepted` or `unknown`; `latency-ms` runs
from the ring's publication; `step` names why an earlier tier missed (for
example `cold-target`, `no-receipt`, `watcher-down`, `queue-cap`), `-` when
none. Events (rings, fallbacks, re-arms, alarms, canaries, pushes) go to
`<state_dir>/mailroom.tsv`.

- `mailroom.sh status`: per side, the watcher, the first tier and its
  health, waiting rings, the last delivery.
- `mailroom.sh metrics [HOURS]`: per side, the share of deliveries per tier
  with p50 and p90 latency (for example "t1-native 92% (p50 0.4s, p90
  1.9s), t2-bridge 6%, t3-cli-queue 2%"), the first tier's health,
  fallbacks, re-arms, canaries, alarms and pushes. Put the 24-hour line in
  the daily digest and the 168-hour line in the weekly review
  ([example hook](../examples/hooks/weekly/55-mailroom-review)).

## Degradation reporting

"The whole system keeps working with slightly higher latency, and you get
a flag." No hourly model probes: these checks cost nothing.

- **Version fingerprint**, every supervisor pass, no model: Claude, the CLI
  version and peer protocol of the newest live session record plus the
  desktop app's version; Codex, the watcher's hash of the app tool server's
  tool list plus the app's version. History:
  `<state_dir>/mailroom-versions.tsv`.
- **Canary**: on a fingerprint change, one canary ring through the side's
  normal path (Claude: tier 1 to the bridge's own session, or the bridge
  model with tier 1 off; Codex: the watcher reads its own chat). Confirmed
  by its row from the first tier; any other row, or none in 10 minutes,
  alarms once per side and version.
- **Once-per-cause alarm**: two deliveries in a row that miss a side's
  first tier at a real failure (a cold target, the kill switch, the rate
  limit, a busy queue target and rings that waited out a watcher restart
  do not count; the bridge-down alarm reports a restart) write one note to the Oracle
  with the failing step, the fingerprint and the last first-tier delivery.
  Deduplicated by side, step and fingerprint; the next first-tier delivery
  clears it, so the same cause can alarm again later.

## Restart recovery

| Failure | Detection | Recovery |
| --- | --- | --- |
| Claude desktop app restart | The Claude watcher's pid is dead and was not renewed for 2 min | Once per app process (its pid, from `lsappinfo`): relaunch if needed; warm the bridge session by deep link (`hooks/wake`, else `wake_link`); 2 s later open the Oracle's own session link, so the window lands back on the Oracle; then one confined headless "Re-arm" to the bridge (no mail). Still down 2 min later: one alarm |
| Codex desktop app restart | Once the watcher is deployed: its heartbeat is older than 3 min, or its pid is dead | Once per app process: one CLI queue "Re-arm doorbell watcher" to the bridge chat; the re-armed watcher catches up. Still down 2 min later: one alarm |
| Reboot or login | `lsappinfo` finds no app process; the units run at load | The supervisor opens the app in the background (`open -g -b <bundle id>`, at most once an hour), then re-arms as above |
| Watcher crash | As for an app restart, with the app running | As for an app restart. A tier-1 claim the dead watcher left is filed if the target's receipt is there, else put back (never resent after a receipt) |
| Bridge stuck | A ring older than 3 min while its watcher looks armed | Tier 3 |
| Codex thread unresponsive | Two sends in a row to one thread end `unknown` while other threads deliver | [Thread recovery](#thread-recovery), started by the supervisor |
| Relay crash | Nothing to detect | launchd runs the cycle again; its kernel lock dies with the process |

### Thread recovery

One Codex thread can stop answering while the app and every other thread
work. The supervisor marks it (`<state_dir>/mailroom/unhealthy/<thread>`),
writes one note to the Oracle and opens the operator's recovery routine,
`operator.sh recover KEY`, which it advances on every pass:

1. **Revive, queued:** one no-op turn by the CLI queue. A new turn-complete
   event in the thread's rollout within 3 minutes means it is back; the
   routine closes.
2. **Revive, native:** one no-op through the Codex watcher, steered. Same
   check.
3. **Replace:** the Oracle (or the human) creates a new thread in the
   operator's home with the same title and with the model and effort from
   `operator.conf` set at creation, sends it the start message the routine
   prints, and records it: `operator.sh recover KEY --replaced THREAD`.
4. **Archive the old thread** in the app (`operator.sh mark KEY archive-old`).
5. **Switch:** the routine opens `lane.sh switch` to the new thread with a
   cold handoff; `lane.sh verify` finishes it as for any switch.

A closed recovery writes a `resolve` row, so the old unknown sends no longer
count against the thread. Prevention: models are set only at creation or
through the app's own setting, never by a message to an idle thread
([K-26](../kit/KIT.md)); the mailroom sends only pointers, never
configuration.

`wake_link` is the desktop app's own link to a session, with `{session}`
where the id goes; such links are undocumented, so the kit ships none and
leaves the setting empty. `hooks/wake <client> <session>` replaces it with
your own executable. Whether `SendMessage` to a cold session's id starts
it is **unverified**.

Pause the supervisor for maintenance with an owner, an expiry and a reason:
`lane.sh hold mailroom --owner <you> --until <date> --reason <why>`
([conventions](conventions.md#holds-pauses-and-switches)).

## Efficiency

No model where a script will do ([K-23](../kit/KIT.md)): the relay, the
supervisor, the fingerprint, the canaries and both tier-1 watchers run no
model. With tier 1 working, the Claude Mailroom takes a turn only for cold
targets and misses; the Codex Mailroom only to re-arm. A headless model run
happens only at tier 3. The largest cost left is the recipients' own turns:
every note wakes a full session, so batch routine script notes.

## Set it up

On a new host, `bootstrap.sh` does all of this and walks you through the
in-app steps ([first run](hosts-and-ci.md#first-run)). By hand:

1. `install.sh host --apply`: App Nap, folders, both launchd units
   (generated and loaded), both bridge homes with their duty files, then a
   table and the few in-app steps a person must do
   ([hosts](hosts-and-ci.md#always-on-host)).
2. In the apps, as it lists them: start the Claude Mailroom and create the
   Codex Mailroom (both titled "Mailroom", cheapest model set at creation),
   record their ids (`operator.sh session mailroom-claude ID`, and the same
   for `mailroom-codex`), pin per the [conventions](conventions.md#sidebar-and-titles).
3. For Codex, set `bridge_codex_node` (the node binary bundled in the
   desktop app) and `bridge_codex_server` (its `codex-app-tools/server.mjs`;
   `bootstrap.sh` finds both inside the app bundle), then send the bridge
   "Re-arm doorbell watcher".
4. Optional: `bridge_claude_t1=socket` for Claude tier 1; `wake_link` for
   the deep-link warm-up; `hooks/push` or the `chat` adapter for tier 4.
5. Check: `install.sh host` again (all rows done), `mailroom.sh status`,
   then drop a test note with `inbox-put.sh` and watch it arrive.

`relay_bridge=off` turns the mailroom off: the relay then delivers through
the transports directly, as tier 3 does. Rows on `custom` clients and rows
without a session id always do.

## What is proven

| Piece | Status |
| --- | --- |
| Relay rings, ladders, telemetry rows, metrics, supervisor (re-arm per app process, relaunch, deep-link wake and return, fingerprint, canary, degradation alarm, tier 4, unknown-send reconciliation, thread recovery), both watchers, installer, first run | Test suite (`tests/t_mailroom.sh`, `t_operator.sh`, `t_lane.sh`, `t_install.sh`, `t_bootstrap.sh`) against fakes: a fake peer socket, a fake app tool server, fake rollouts, `lsappinfo`, `open`, `launchctl`; macOS, 2026-11-19 |
| The pattern (relay, ring, bridge with a kqueue watcher, `SendMessage` by session id; a Codex watcher sending natively and steering mid-turn; a model-free socket send to a warm Claude session) | Observed in one private deployment, 2026-11-19; not yet this kit's code |
| Live restart recovery, `SendMessage` to a cold session, deep-link wake, Codex queue on a real turn-complete event, thread recovery on a real thread | **Unverified**: the live acceptance tests in [TESTING.md](../TESTING.md#mailroom-live-acceptance) |
| Linux | No push watch (kqueue is macOS); the relay timer runs every minute. **Untested** |
