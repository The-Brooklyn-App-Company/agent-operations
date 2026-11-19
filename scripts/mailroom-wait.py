#!/usr/bin/python3 -I
"""mailroom-wait.py - block until a ring is waiting, with no polling.

Usage: /usr/bin/python3 -I mailroom-wait.py DIR

For a mailroom bridge's background task (EXPERIMENTAL, docs/mailroom.md).
Watches DIR with a kqueue vnode push notification (zero CPU while
waiting) and returns as soon as at least one ring (a visible *.md file) is
there: prints each ring as '=== <name>' followed by its body, oldest name
first, and exits 0. The watcher exiting is what wakes the bridge session,
which hands the rings off and starts this again. Its pid goes to
DIR/.watcher/pid, for the mailroom supervisor.

Exit codes: 0 rings printed; 2 usage error, DIR missing, or no kqueue on
this platform (no push watch available: the relay's timed fallback still
delivers).
"""
import os
import select
import sys


def rings(d):
    return sorted(f for f in os.listdir(d)
                  if f.endswith(".md") and not f.startswith(".")
                  and os.path.isfile(os.path.join(d, f)))


def show(d):
    for name in rings(d):
        try:
            with open(os.path.join(d, name), errors="replace") as h:
                body = h.read().strip()
        except FileNotFoundError:
            continue  # handed off by someone else meanwhile
        print("=== " + name)
        print(body)
    sys.stdout.flush()


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    d = sys.argv[1]
    if not os.path.isdir(d):
        print("mailroom-wait: not a directory: " + d, file=sys.stderr)
        return 2
    if not hasattr(select, "kqueue"):
        print("mailroom-wait: no kqueue on this platform; no push watch", file=sys.stderr)
        return 2
    # The supervisor reads this pid to tell an armed bridge from a dead one.
    state = os.path.join(d, ".watcher")
    os.makedirs(state, exist_ok=True)
    tmp = os.path.join(state, ".pid.%d" % os.getpid())
    with open(tmp, "w") as h:
        h.write("%d\n" % os.getpid())
    os.replace(tmp, os.path.join(state, "pid"))
    fd = os.open(d, os.O_RDONLY)
    kq = select.kqueue()
    ev = select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                       flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                       fflags=select.KQ_NOTE_WRITE)
    kq.control([ev], 0, 0)  # register first, then look: no missed ring
    while not rings(d):
        kq.control([ev], 1, None)  # sleeps until the folder changes
    show(d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
