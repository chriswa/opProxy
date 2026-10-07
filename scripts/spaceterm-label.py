#!/usr/bin/env python3
"""Names opProxy requesters running in Spaceterm: the agent's name, its surface's title, and
a link that opens the surface. opProxy runs this per request when ~/.opProxy/config.json says:

  {"requesterLabel": {"command": ["<this file>"],
                      "environment": ["SPACETERM_NODE_ID", "SPACETERM_SURFACE_ID"]}}

Reads opProxy's request on stdin, prints a label as JSON, and prints nothing outside Spaceterm.
"""
import json
import os
import socket
import sys

request = json.load(sys.stdin)
env = request.get("environment") or {}
# The node ID is stable; SPACETERM_SURFACE_ID is a pty ID that stops matching once its
# terminal restarts, so it's only a fallback.
node = env.get("SPACETERM_NODE_ID") or env.get("SPACETERM_SURFACE_ID")
session = (request.get("agent") or {}).get("sessionId")
if not node:
    # Spaceterm also opens an agent's surface by its session ID.
    if session:
        print(json.dumps({"openURL": f"spaceterm-surface://{session}"}))
    sys.exit(0)

label = {"id": node, "openURL": f"spaceterm-surface://{node}"}
home = os.environ.get("SPACETERM_HOME") or os.path.expanduser("~/.spaceterm")
try:
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(0.8)
        s.connect(os.path.join(home, "scripts.sock"))
        s.sendall((json.dumps({"type": "script-get-node", "seq": 1, "nodeId": node}) + "\n").encode())
        reply = json.loads(s.makefile().readline())
    surface = reply.get("node") or {}
    titles = surface.get("shellTitleHistory") or []
    title = (surface.get("name") or "").strip() or (str(titles[0]).strip() if titles else "")
    if title:
        label["title"] = title
    if (reply.get("agentName") or "").strip():
        label["name"] = reply["agentName"].strip()
except (OSError, ValueError):
    pass
print(json.dumps(label))
