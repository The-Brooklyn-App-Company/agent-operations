# Hosts and devices

## Clients

Desktop and mobile clients behave according to each client's actual installed version, signed-in account and feature rollout. Check what is available on a specific device. Do not assume parity between devices.

Each client documents its own remote access and scheduled tasks; read the current pages for the client you use and verify them before you depend on them. For example, the Codex pages:

- [Remote connections](https://learn.chatgpt.com/docs/remote-connections): another device works with a host only while that host is connected, awake, online and signed in.
- [Automations](https://learn.chatgpt.com/docs/automations): scheduled runs can be fresh standalone tasks or tasks attached to existing context, and the client manages them with native controls.

These pages were verified on 2026-10-17.

Do not claim that every older conversation will migrate or sync to a new host. Never clone or edit application databases to move state between hosts.

## Laptop first, always-on host when needed

Start on the laptop you use every day. A remote host is optional. Add one only when a specific job needs it, such as a main operator the human reaches from a phone, scheduled workers or self-hosted CI. Verify that remote access to it keeps working when sessions sit idle, and give urgent alerts a push route.

Even an always-on host sleeps, reboots and loses network. Workers must report it as unknown rather than as healthy.

## No routine permission pop-ups on an unattended host

An OS permission dialog on an unattended host blocks work and may go unanswered for hours, because the human is often on a phone. Treat each unexpected prompt as a defect, and make any genuinely new grant a planned, one-time ask.

- **Pin interpreters.** Do not run routine or scheduled work under a package-manager interpreter such as bare Homebrew `python3`: its path and signing identity can change on upgrade, and depending on signing and launch context the OS may ask for access again. Verify the actual unattended launch route after any runtime change. Use the system interpreter or a pinned runtime installed at a stable path. A virtual environment counts only if its base interpreter is itself stable: one created from a package-manager interpreter inherits the problem.
- **Quiet test servers.** Test and dev servers bind loopback (`127.0.0.1`) only and do no hostname lookups at start-up. A non-loopback listener can trigger a firewall dialog, and a start-up `getfqdn`-style lookup can trigger a local-network prompt.
- **Close stdin.** Run CLI agents with `</dev/null` so they never hang waiting for input.
- **Reap everything.** Tests reap every child process and temporary directory, even on failure; leaked helpers can raise prompts long after the test.
- **Detect, then tune.** A detector that reads the system log for permission-dialog activity catches regressions. Tune it against false positives, replay known prompts after each change and attribute each hit before acting on it. In zsh, `log` is a builtin: call the macOS tool as `/usr/bin/log`.

## Switching hosts

1. **Inventory the old host.** Record:
   - Source checkouts and worktrees
   - Tools and their versions
   - Skill versions and the pinned kit tag
   - Authentication bindings, by account name only
   - Locale and time zone
   - Schedules
   - Pending deliveries
2. **Set up credentials separately.** The owner signs in on the new host directly. Credentials are never copied.
3. **Hand off durably.** If the client cannot transfer tasks, write a handoff in the owning repository or issue using [../templates/operator-handoff.md](../templates/operator-handoff.md).
4. **Transfer the overlapping schedules, not the whole machine.** Stop the schedules on the old host and confirm that they stopped before you enable them on the new host. See [scheduled-workers.md](scheduled-workers.md).
5. **Run acceptance.** Verify basic operation on the new host. Treat remote wake and restart behavior as separate acceptance items, and test them only if you rely on them.

Record the result in the machine-local profile and in the owning queue.
