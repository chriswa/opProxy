"""Does each Unix session get its own 1Password 12-hour authorization clock?

A = the opProxy daemon's session (probed with `op whoami` through the shim). The daemon gets
    restarted during development, so A is noise; B-style sessions answer the question.
B = this script's own fresh session (start_new_session), authorized at launch.
Logs both every minute for 13 hours. argv[1] names the run's log (default refresh_12h).
"""
import os, subprocess, sys, time
NAME = sys.argv[1] if len(sys.argv) > 1 else "refresh_12h"
LOG = os.path.expanduser(f"~/opProxy/experiments/{NAME}.log")
SHIM = os.path.expanduser("~/opProxy/bin/op")

def log(msg):
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")

def whoami(cmd):
    p = subprocess.run([cmd, "whoami"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)
    return "ok" if p.returncode == 0 else "EXPIRED"

log(f"B pid={os.getpid()} sid={os.getsid(0)}; A before B auth: {whoami(SHIM)}")
t = time.time()
p = subprocess.run(["op", "vault", "list"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
log(f"B authorized rc={p.returncode} in {time.time()-t:.1f}s (prompt expected); A after: {whoami(SHIM)}")
prev = None
end = time.time() + 13 * 3600
while time.time() < end:
    state = f"A={whoami(SHIM)} B={whoami('op')}"
    if state != prev:
        log("CHANGE " + state)
        prev = state
    time.sleep(60)
log("done")
