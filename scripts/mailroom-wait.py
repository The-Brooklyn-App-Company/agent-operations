#!/usr/bin/python3 -I
"""mailroom-wait.py - block until a ring is waiting, with no polling.

Usage: /usr/bin/python3 -I mailroom-wait.py DIR

For the Claude mailroom bridge's background task (EXPERIMENTAL,
docs/mailroom.md). Watches DIR with a kqueue vnode push notification (zero
CPU while waiting). Probe rings (echo--*) are filed here, with no model
turn: moved to DIR/delivered/ and logged as `watcher echo`. As soon as at
least one other ring (a visible *.md file) is there, each is claimed by an
atomic rename into DIR/.watcher/handing/ (so the supervisor's fallback
cannot send it too), printed as '=== <name>' followed by its body, oldest
name first, and the script exits 0. The watcher exiting is what wakes the
bridge session, which hands the rings off, files them with
`mailroom.sh file claude ... --wait`, and so starts this again. A ring the
bridge does not file stays in handing/ for the supervisor's fallback.

Its pid goes to DIR/.watcher/pid, touched again on exit, so the supervisor
can tell an armed bridge from a dead one.

One watcher per folder: it holds an flock on DIR/.watcher/lock for its
life; a second start prints "armed: another watcher is running".

Exit codes: 0 rings printed; 2 usage error, DIR missing, or no kqueue on
this platform (no push watch available: the supervisor's timed fallback
still delivers); 3 another watcher is running.
"""
import fcntl
import os
import select
import sys
import time


def rings(d):
    return sorted(f for f in os.listdir(d)
                  if f.endswith(".md") and not f.startswith(".")
                  and os.path.isfile(os.path.join(d, f)))


def file_echo(d, name):
    """File a probe ring without a send; False if someone else took it."""
    dest = os.path.join(d, "delivered")
    os.makedirs(dest, exist_ok=True)
    try:
        os.rename(os.path.join(d, name), os.path.join(dest, name))
    except FileNotFoundError:
        return False
    now = time.time()
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))
    with open(os.path.join(dest, "log.tsv"), "a") as h:
        h.write("%s\t%d\t%s\twatcher\techo\tok\n" % (stamp, int(now), name))
    return True


def claim(d, name, handing):
    """Move a ring into handing/ and stamp the claim time; its new path."""
    dest = os.path.join(handing, name)
    try:
        os.rename(os.path.join(d, name), dest)
    except FileNotFoundError:
        return None
    os.utime(dest, None)
    return dest


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
    state = os.path.join(d, ".watcher")
    handing = os.path.join(state, "handing")
    os.makedirs(handing, exist_ok=True)
    # One watcher: a lock held for this process's life. A second start
    # (a re-arm while one is armed) says so and exits.
    lockf = open(os.path.join(state, "lock"), "a")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("armed: another watcher is running")
        return 3
    pidfile = os.path.join(state, "pid")
    tmp = os.path.join(state, ".pid.%d" % os.getpid())
    with open(tmp, "w") as h:
        h.write("%d\n" % os.getpid())
    os.replace(tmp, pidfile)
    try:
        fd = os.open(d, os.O_RDONLY)
        kq = select.kqueue()
        ev = select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                           flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                           fflags=select.KQ_NOTE_WRITE)
        kq.control([ev], 0, 0)  # register first, then look: no missed ring
        while True:
            names = rings(d)
            for n in [n for n in names if n.startswith("echo--")]:
                file_echo(d, n)
            names = [n for n in names if not n.startswith("echo--")]
            claimed = [(n, p) for n, p in ((n, claim(d, n, handing)) for n in names) if p]
            if claimed:
                break
            kq.control([ev], 1, None)  # sleeps until the folder changes
        for name, path in claimed:
            with open(path, errors="replace") as h:
                body = h.read().strip()
            print("=== " + name)
            print(body)
        sys.stdout.flush()
        return 0
    finally:
        try:
            os.utime(pidfile, None)  # completion time, for the supervisor's grace
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
