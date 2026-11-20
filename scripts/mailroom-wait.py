#!/usr/bin/python3 -I
"""mailroom-wait.py - the Claude mailroom bridge's watcher (EXPERIMENTAL).

Usage: /usr/bin/python3 -I mailroom-wait.py DIR
       /usr/bin/python3 -I mailroom-wait.py --t1 DIR TARGETS SELF
       /usr/bin/python3 -I mailroom-wait.py --fingerprint
       /usr/bin/python3 -I mailroom-wait.py --receipt TRANSCRIPT RING

Run through `mailroom.sh wait claude` (docs/mailroom.md). Watches DIR with
a kqueue vnode push notification (zero CPU while waiting, no polling).

Tier 2 only (DIR): as soon as a ring (a visible *.md file) waits, each is
claimed by an atomic rename into DIR/.watcher/handing/, printed as
'=== <name>' and its body, oldest name first, and the script exits 0. The
exit wakes the bridge session, which sends each with SendMessage, files
them with `mailroom.sh file claude ... --wait` and so starts this again.

Tier 1 (--t1, opt-in with bridge_claude_t1=socket): the watcher stays armed
and delivers each ring to a warm session itself, with no model turn. Per
ring it re-reads the target's live session record (never cached), reads
the session's peer key in memory only (never logged or printed), writes the
message to the session's socket the way the client does for a local peer,
prefixed `Doorbell [<ring>]`, and confirms it by finding the session's own
receipt in its transcript within 10 s. It then files the ring with a
t1-socket row and keeps waiting. Any miss (cold target, no or several
records, another peer protocol, no transcript, rate limit, a connect or
write error, no receipt, the kill switch DIR/.watcher/t1-off) records the
step and hands the ring to the bridge model as above (tier 2). Only rings
to a session listed in TARGETS (the registry's Claude sessions) and the
supervisor's canaries (sent to SELF, the bridge's own session) are sent;
per target at least 2 s apart and at most 10 a minute.

This relies on an undocumented interface of the Claude Code CLI (its
session records, peer keys and local socket). It can change in any build;
the fallback to tier 2 is automatic and the supervisor flags it.

Each claimed ring gets DIR/.watcher/meta/<ring>: `publish-ms <TAB> step`,
read by `mailroom.sh file` for the latency and the miss step. Pid record:
DIR/.watcher/pid, touched again on exit. One watcher per folder (an flock
on DIR/.watcher/lock); a second start prints "armed: another watcher is
running" and exits 3.

--fingerprint prints `cli=<version> proto=<peer protocol>` of the newest
live session record (or cli=unknown). --receipt exits 0 when TRANSCRIPT
holds the session's own receipt of RING, 1 when it is readable without one,
and 3 when it cannot be read (used by the supervisor for claims a dead
watcher left, or held after a send whose outcome is unknown).

Exit codes: 0 rings printed; 2 usage error, DIR missing, or no kqueue on
this platform (the supervisor's timed tiers still deliver); 3 another
watcher is running.
"""
import collections
import fcntl
import hashlib
import json
import os
import re
import select
import socket
import stat
import sys
import time
import uuid

SETTLE_QUIET, SETTLE_MAX = 2.0, 5.0
# Overridable for tests only.
CONFIRM_S = float(os.environ.get("AO_MR_T1_CONFIRM_S", "10"))
RATE_GAP_S, RATE_PER_MIN = (float(x) for x in os.environ.get("AO_MR_T1_RATE", "2,10").split(","))
MAX_BODY = 4096
CANARY_RE = re.compile(r"^echo--canary-[A-Za-z0-9._-]+\.md$")
CONF = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
SESS = os.path.join(CONF, "sessions")
PROJ = os.path.join(CONF, "projects")


class Miss(Exception):
    pass


def iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def rings(d):
    return sorted(f for f in os.listdir(d)
                  if f.endswith(".md") and not f.startswith(".")
                  and os.path.isfile(os.path.join(d, f)))


def safe_read(path, limit=MAX_BODY):
    """A ring's text, read without following a symlink or blocking on a
    FIFO; None for anything but a regular file or one over the limit."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > limit:
            return None
        return os.read(fd, limit + 1).decode(errors="replace").strip()
    finally:
        os.close(fd)


class Watcher:
    def __init__(self, d, targets=None, self_sid=None):
        self.d = d
        self.state = os.path.join(d, ".watcher")
        self.handing = os.path.join(self.state, "handing")
        self.meta = os.path.join(self.state, "meta")
        self.t1dir = os.path.join(self.state, "t1")
        self.delivered = os.path.join(d, "delivered")
        self.targets = targets or set()
        self.self_sid = self_sid
        self.sent_at = collections.defaultdict(collections.deque)
        for p in (self.handing, self.meta, self.t1dir, self.delivered):
            os.makedirs(p, exist_ok=True)

    def log(self, msg):  # never called with a key or a body
        try:
            with open(os.path.join(self.state, "log"), "a") as h:
                h.write("%s [%d] %s\n" % (iso(), os.getpid(), msg))
        except OSError:
            pass

    def row(self, name, tier, mode, status, pub_ms, step="-"):
        now = time.time()
        with open(os.path.join(self.delivered, "log.tsv"), "a") as h:
            h.write("%s\t%d\t%s\t%s\t%s\t%s\t%d\t%s\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)), int(now), name,
                tier, mode, status, max(0, int(now * 1000) - pub_ms), step))

    def file_old_probe(self, name):
        """An old echo-- probe (not a canary): filed with no send."""
        try:
            pub = int(os.lstat(os.path.join(self.d, name)).st_mtime * 1000)
            os.rename(os.path.join(self.d, name), os.path.join(self.delivered, name))
        except OSError:
            return
        self.row(name, "none", "echo", "ok", pub)

    def hand(self, name, step):
        """Claim a ring for the bridge model: meta first (publish time and
        the miss step), then the rename into handing/, stamped with the
        claim time for the supervisor."""
        src = os.path.join(self.d, name)
        try:
            pub = int(os.lstat(src).st_mtime * 1000)
        except OSError:
            return None
        mp = os.path.join(self.meta, name)
        with open(mp + ".tmp", "w") as h:
            h.write("%d\t%s\n" % (pub, step))
        os.replace(mp + ".tmp", mp)
        dest = os.path.join(self.handing, name)
        try:
            os.rename(src, dest)
        except OSError:
            rm(mp)
            return None
        os.utime(dest, None)
        return dest

    # ------------------------------------------------------------ tier 1

    def rate_ok(self, target):
        q, t = self.sent_at[target], time.time()
        while q and t - q[0] > 60:
            q.popleft()
        if q and 0 <= t - q[-1] < RATE_GAP_S:
            time.sleep(RATE_GAP_S - (t - q[-1]))
        return len(q) < RATE_PER_MIN

    def deliver(self, name):
        """Tier 1 for one ring: True when delivered and filed; raises Miss
        with the step otherwise (the ring is back where it waited)."""
        if os.path.exists(os.path.join(self.state, "t1-off")):
            raise Miss("kill-switch")
        if CANARY_RE.match(name):
            target, mode = self.self_sid, "canary"
        else:
            target, mode = name.split("--", 1)[0], "send"
            if target not in self.targets:
                raise Miss("not-mailroom")
        if not target:
            raise Miss("not-mailroom")
        rec = resolve(target)
        tx = transcript(rec)
        if not self.rate_ok(target):
            raise Miss("rate-limit")
        src, claim = os.path.join(self.d, name), os.path.join(self.t1dir, name)
        try:
            pub = int(os.lstat(src).st_mtime * 1000)
            os.rename(src, claim)  # claimed: no fallback can take it meanwhile
        except OSError:
            return False
        sidecar = claim + ".tx"
        sent = False  # True once any byte of the message may have reached the session
        try:
            body = safe_read(claim)
            if not body:
                raise Miss("not-regular" if body is None else "empty")
            marker = "Doorbell [%s]" % name
            text = ("%s: mailroom canary (automated): no action, end the turn with no text." % marker
                    if mode == "canary" else "%s: %s" % (marker, body))
            start = os.path.getsize(tx)
            # Written before the send and kept until the ring is filed: a
            # restarted watcher or the supervisor finds an earlier receipt
            # instead of sending again.
            with open(sidecar + ".tmp", "w") as h:
                h.write(tx + "\n")
            os.replace(sidecar + ".tmp", sidecar)
            self.sent_at[target].append(time.time())
            try:
                send(rec, text)
            except Miss as e:
                sent = str(e) not in ("key", "connect")  # those fail before any byte is written
                raise
            sent = True
            if not confirm(tx, start, marker, time.monotonic() + CONFIRM_S):
                # The transcript was read to the deadline with no receipt:
                # absence is confirmed, so the next tier may send it.
                sent = False
                raise Miss("no-receipt")
        except Miss as e:
            self.miss_after_send(name, claim, src, sidecar, sent, str(e))
            raise
        except Exception as e:  # never die on one ring
            self.miss_after_send(name, claim, src, sidecar, sent, "error-" + type(e).__name__)
            raise Miss("error-" + type(e).__name__) from None
        try:
            os.rename(claim, os.path.join(self.delivered, name))
        except OSError:
            self.log("%s: delivered by t1-socket but the claim was taken back; no row" % name)
            return True
        rm(sidecar)
        self.row(name, "t1-socket", mode, "ok", pub)
        self.log("%s: t1-socket delivered to pid %s" % (name, rec.get("pid")))
        return True

    def miss_after_send(self, name, claim, src, sidecar, sent, step):
        """A miss before any byte was sent, or with absence confirmed, puts
        the ring back for the next tier. A miss after a possible send keeps
        the claim and its transcript sidecar, so the ring is never resent
        until the target's transcript is read and shows no receipt (K-28)."""
        if not sent:
            put_back(claim, src)
            rm(sidecar)
            return
        self.log("%s: outcome unknown after a send (%s); held for a receipt check, not resent" % (name, step))

    def settle_claims(self):
        """Claims a killed watcher left: filed if the receipt is there,
        else back in the queue (never resent after a receipt)."""
        for f in os.listdir(self.t1dir):
            c = os.path.join(self.t1dir, f)
            if not f.endswith(".md") or os.path.exists(os.path.join(self.d, f)):
                continue
            try:
                tx = open(c + ".tx").readline().strip()
            except OSError:
                tx = ""
            got = has_receipt(tx, "Doorbell [%s]" % f) if tx else False
            if got is None:
                # The transcript cannot be read: no evidence either way, so the
                # claim stays for the supervisor (it alarms; never resent).
                self.log("%s: transcript unreadable; claim kept, not resent" % f)
                continue
            if got:
                pub = int(os.lstat(c).st_mtime * 1000)
                os.rename(c, os.path.join(self.delivered, f))
                self.row(f, "t1-socket", "canary" if CANARY_RE.match(f) else "send", "ok", pub)
            else:
                os.rename(c, os.path.join(self.d, f))
            rm(c + ".tx")


def resolve(target):
    """The target's live session record (re-read on every ring)."""
    hits = []
    try:
        names = os.listdir(SESS)
    except OSError:
        raise Miss("cold-target") from None
    for f in names:
        if not re.fullmatch(r"\d+\.json", f):
            continue
        rec = load_json(os.path.join(SESS, f))
        if not isinstance(rec, dict) or rec.get("hostSessionId") != target:
            continue
        if not alive(rec.get("pid")):
            continue
        hits.append(rec)
    if not hits:
        raise Miss("cold-target")
    if len(hits) > 1:
        raise Miss("resolve-ambiguous")
    rec = hits[0]
    if rec.get("peerProtocol") != 1:
        raise Miss("protocol-%s" % re.sub(r"[^A-Za-z0-9._-]", "-", str(rec.get("peerProtocol"))))
    if not rec.get("messagingSocketPath") or not rec.get("sessionId") or not rec.get("cwd"):
        raise Miss("resolve-fields")
    return rec


def load_json(p):
    try:
        with open(p) as h:
            return json.load(h)
    except (OSError, ValueError):
        return None


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def transcript(rec):
    p = os.path.join(PROJ, re.sub(r"[^A-Za-z0-9]", "-", rec["cwd"]), rec["sessionId"] + ".jsonl")
    if not os.path.isfile(p):
        raise Miss("no-transcript")
    return p


def send(rec, text):
    """Two JSON lines (auth, then the message) to the session's socket. The
    key lives only in this frame and is never logged."""
    sock_path = rec["messagingSocketPath"]
    keyfile = os.path.join(SESS, "%s.%s.key" % (rec["pid"], hashlib.sha256(os.path.abspath(sock_path).encode()).hexdigest()))
    data = load_json(keyfile)
    if not isinstance(data, dict) or not isinstance(data.get("peerToken"), str):
        raise Miss("key")
    msg = {"msgV": 1, "msg_id": str(uuid.uuid4()), "type": "user", "priority": "next",
           "message": {"role": "user", "content": '<cross-session-message from-name="Mailroom">\n%s\n</cross-session-message>' % text}}
    payload = (json.dumps({"type": "auth", "token": data["peerToken"]}) + "\n" + json.dumps(msg) + "\n").encode()
    del data
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(5)
        try:
            s.connect(sock_path)
        except OSError:
            raise Miss("connect") from None
        try:
            s.sendall(payload)
        except OSError:
            raise Miss("write") from None
        time.sleep(0.15)
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass  # the session may already have closed its end; the transcript decides
    finally:
        del payload
        s.close()


def receipt(line, marker):
    """True when one transcript record is the session's own receipt of the
    message: its enqueue record or the user turn it became. Text that only
    mentions the marker (tool output, an assistant turn) never counts."""
    if isinstance(line, bytes):
        line = line.decode("utf-8", "replace")
    if marker not in line:
        return False
    try:
        rec = json.loads(line)
    except ValueError:
        return False
    if not isinstance(rec, dict):
        return False
    if rec.get("type") == "queue-operation" and rec.get("operation") == "enqueue":
        c = rec.get("content")
    elif rec.get("type") == "user":
        c = rec["message"].get("content") if isinstance(rec.get("message"), dict) else None
        if isinstance(c, list):
            c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"
                          and isinstance(b.get("text"), str))
    else:
        return False
    return isinstance(c, str) and "<cross-session-message" in c and marker in c


def has_receipt(path, marker):
    """True or False from the transcript; None when it cannot be read."""
    try:
        with open(path, "rb") as h:
            return any(receipt(line, marker) for line in h)
    except OSError:
        return None


def confirm(path, start, marker, deadline):
    """kqueue on the transcript; each complete record appended after START
    is checked until a receipt or the deadline."""
    fd = os.open(path, os.O_RDONLY)
    try:
        kq = select.kqueue()
        ev = select.kevent(fd, filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                           fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)
        kq.control([ev], 0, 0)
        pos, part = start, b""
        while True:
            os.lseek(fd, pos, os.SEEK_SET)
            while time.monotonic() < deadline:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    break
                pos += len(chunk)
                lines = (part + chunk).split(b"\n")
                part = lines.pop()
                if len(part) > 1 << 20:
                    part = b""
                if any(receipt(ln, marker) for ln in lines):
                    return True
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            kq.control([ev], 1, left)
    finally:
        os.close(fd)


def rm(p):
    try:
        os.unlink(p)
    except OSError:
        pass


def put_back(claim, src):
    try:
        if not os.path.exists(src):
            os.rename(claim, src)
    except OSError:
        pass


def clean(v):
    return re.sub(r"[^A-Za-z0-9._-]", "-", str(v))


def fingerprint():
    best = None
    try:
        names = os.listdir(SESS)
    except OSError:
        names = []
    for f in names:
        if not re.fullmatch(r"\d+\.json", f):
            continue
        p = os.path.join(SESS, f)
        rec = load_json(p)
        if not isinstance(rec, dict) or not alive(rec.get("pid")):
            continue
        m = os.path.getmtime(p)
        if best is None or m > best[0]:
            best = (m, rec)
    if best is None:
        return "cli=unknown"
    return "cli=%s proto=%s" % (clean(best[1].get("version", "unknown")), clean(best[1].get("peerProtocol", "unknown")))


def main(argv):
    if len(argv) == 2 and argv[1] == "--fingerprint":
        print(fingerprint())
        return 0
    if len(argv) == 4 and argv[1] == "--receipt":
        got = has_receipt(argv[2], "Doorbell [%s]" % argv[3])
        return 3 if got is None else (0 if got else 1)
    t1 = len(argv) == 5 and argv[1] == "--t1"
    if not t1 and (len(argv) != 2 or argv[1].startswith("-")):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    d = argv[2] if t1 else argv[1]
    if not os.path.isdir(d):
        print("mailroom-wait: not a directory: " + d, file=sys.stderr)
        return 2
    if not hasattr(select, "kqueue"):
        print("mailroom-wait: no kqueue on this platform; no push watch", file=sys.stderr)
        return 2
    targets = set()
    if t1:
        try:
            with open(argv[3]) as h:
                targets = {ln.strip() for ln in h if ln.strip()}
        except OSError:
            pass
    w = Watcher(d, targets, argv[4] if t1 else None)
    lockf = open(os.path.join(w.state, "lock"), "a")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("armed: another watcher is running")
        return 3
    pidfile = os.path.join(w.state, "pid")
    tmp = os.path.join(w.state, ".pid.%d" % os.getpid())
    with open(tmp, "w") as h:
        h.write("%d\n" % os.getpid())
    os.replace(tmp, pidfile)
    try:
        if t1:
            w.settle_claims()
        fd = os.open(d, os.O_RDONLY)
        kq = select.kqueue()
        ev = select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                           flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)
        kq.control([ev], 0, 0)  # register first, then look: no missed ring
        while True:
            while not rings(d):
                kq.control([ev], 1, None)  # sleeps until the folder changes
            if t1:  # settle: a burst across lanes becomes one pass
                seen, start = set(rings(d)), time.monotonic()
                last = start
                while True:
                    left = min(last + SETTLE_QUIET, start + SETTLE_MAX) - time.monotonic()
                    if left <= 0 or not kq.control([ev], 1, left):
                        break
                    now = set(rings(d))
                    if now - seen:
                        last = time.monotonic()
                    seen = now
            claimed = []
            for n in rings(d):
                if n.startswith("echo--") and not CANARY_RE.match(n):
                    w.file_old_probe(n)
                    continue
                step = "-"
                if t1:
                    try:
                        if w.deliver(n):
                            continue
                    except Miss as e:
                        step = str(e)
                        w.log("%s: tier 1 missed at %s; handed to the bridge model" % (n, step))
                    if not os.path.exists(os.path.join(d, n)):
                        continue
                p = w.hand(n, step)
                if p:
                    claimed.append((n, p))
            if claimed:
                break
        for name, path in claimed:
            body = safe_read(path, MAX_BODY * 4)
            print("=== " + name)
            print(body if body is not None else "(not a regular file: file it as failed)")
        sys.stdout.flush()
        return 0
    finally:
        try:
            os.utime(pidfile, None)  # completion time, for the supervisor's grace
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
