# Hosts and devices

## Clients

Desktop and mobile clients behave according to each client's actual installed version, signed-in account and feature rollout. Check what is available on a specific device. Do not assume parity between devices.

The official documentation describes these capabilities. Verify it again before you depend on it:

- [Remote connections](https://learn.chatgpt.com/docs/remote-connections): another device works with a host only while that host is connected, awake, online and signed in.
- [Automations](https://learn.chatgpt.com/docs/automations): scheduled runs can be fresh standalone tasks or tasks attached to existing context, and the client manages them with native controls.

These pages were verified on 2026-10-17.

Do not claim that every older conversation will migrate or sync to a new host. Never clone or edit application databases to move state between hosts.

## Laptop first

Start on the laptop you use every day. A remote host is optional. Add one only when a specific job needs it.

Do not plan for unconditional 24/7 availability. A sleeping or offline host is a normal state, and workers must report it as unknown rather than as healthy.

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
