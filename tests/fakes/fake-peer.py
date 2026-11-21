#!/usr/bin/python3 -I
"""fake-peer.py - stands in for a warm Claude Code session's local peer
socket in tests. Never talks to a client or a model.

Usage: /usr/bin/python3 -I fake-peer.py SOCKET TOKEN TRANSCRIPT MODE

Listens on the unix SOCKET. Each connection sends an auth line and a
message line; when the auth token equals TOKEN, the message is recorded in
TRANSCRIPT the way a session records a queued peer message (an enqueue
record), unless MODE says otherwise:
  ok       record the receipt
  silent   accept but record nothing (no receipt)
  mention  record only an assistant line that mentions the text (not a
           receipt)
Every connection is also appended to TRANSCRIPT.log as one JSON line
(without the token).
"""
import json
import os
import socket
import sys

sock_path, token, tx, mode = sys.argv[1:5]
try:
    os.unlink(sock_path)
except OSError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path)
s.listen(8)
while True:
    c, _ = s.accept()
    data = b""
    c.settimeout(5)
    try:
        while data.count(b"\n") < 2:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
    except OSError:
        pass
    c.close()
    lines = data.decode("utf-8", "replace").split("\n")
    try:
        auth, msg = json.loads(lines[0]), json.loads(lines[1])
    except (ValueError, IndexError):
        continue
    ok = auth.get("type") == "auth" and auth.get("token") == token
    content = msg.get("message", {}).get("content", "")
    with open(tx + ".log", "a") as h:
        h.write(json.dumps({"auth_ok": ok, "content": content}) + "\n")
    if not ok:
        continue
    with open(tx, "a") as h:
        if mode == "ok":
            h.write(json.dumps({"type": "queue-operation", "operation": "enqueue", "content": content}) + "\n")
        elif mode == "mention":
            h.write(json.dumps({"type": "assistant", "message": {"content": "saw " + content}}) + "\n")
