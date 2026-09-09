#!/usr/bin/env python3
"""Prove remote control works from ANOTHER computer.

Spins up a gateway sandbox (a cloud Linux VM on your account), uploads a
Linux build of graff plus your `graff login` file, and from inside the VM
runs `graff remote` against the machine that is running `graff
remote-control` here. The turn asks the session to run `hostname`, so the
output names the machine that executed it: it must be THIS one, not the VM.

    zig build graff -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl --prefix /tmp/linux
    graff remote-control --name mac &          # on this machine
    python3 scripts/e2e-remote-control.py /tmp/linux/bin/graff [--keep]

Costs a few cents of sandbox time plus one short turn. --keep leaves the
sandbox running (auto-stops after 20 minutes) for poking at by hand."""
import base64, gzip, json, os, sys, time, urllib.request, urllib.error

GW = "https://gateway.codegraff.com"
KEYFILE = os.path.expanduser("~/.simple-harness-codegraff.json")
KEY = json.load(open(KEYFILE))["api_key"]
BIN = sys.argv[1]
STOP = "--keep" not in sys.argv

def gw(method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(GW + path, data=data, method=method, headers={
        "Authorization": "Bearer " + KEY, "Content-Type": "application/json", "User-Agent": "simple-harness/verify"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> HTTP {e.code}: {e.read()[:300]!r}")

def ex(sb, cmd, timeout=120):
    r = gw("POST", f"/v1/sandboxes/{sb}/exec", {"command": cmd, "timeoutSeconds": timeout}, timeout=timeout + 15)
    return r.get("exitCode"), (r.get("result") or "")

t0 = time.time()
sb = gw("POST", "/v1/sandboxes", {"autoStopMinutes": 20, "labels": {"purpose": "remote-control-verify"}})["id"]
print(f"[{time.time()-t0:5.1f}s] sandbox {sb}")
for _ in range(60):
    st = gw("GET", f"/v1/sandboxes/{sb}")["state"]
    if st == "started": break
    time.sleep(2)
print(f"[{time.time()-t0:5.1f}s] state={st}")
code, out = ex(sb, "uname -a; hostname; whoami; echo HOME=$HOME")
print(f"[{time.time()-t0:5.1f}s] sandbox identity (exit {code}):\n" + out.strip())

raw = open(BIN, "rb").read()
gz = gzip.compress(raw, 6)
print(f"[{time.time()-t0:5.1f}s] uploading graff: {len(raw)/1e6:.1f} MB raw -> {len(gz)/1e6:.1f} MB gz")
gw("POST", f"/v1/sandboxes/{sb}/upload", {"path": "/home/daytona/graff.gz", "contentBase64": base64.b64encode(gz).decode()}, timeout=600)
gw("POST", f"/v1/sandboxes/{sb}/upload", {"path": "/home/daytona/.simple-harness-codegraff.json",
   "contentBase64": base64.b64encode(open(KEYFILE, "rb").read()).decode()})
code, out = ex(sb, "cd /home/daytona && gunzip -f graff.gz && chmod +x graff && ./graff --version")
print(f"[{time.time()-t0:5.1f}s] graff in sandbox (exit {code}): {out.strip()[:200]}")

def remote(args, timeout=180):
    code, out = ex(sb, "cd /home/daytona && ./graff remote " + args + " 2>&1", timeout=timeout)
    print(f"[{time.time()-t0:5.1f}s] $ graff remote {args}  (exit {code})\n" + "\n".join("    " + l for l in out.strip().splitlines()[:12]))
    return code, out

remote("agents")
remote("sessions")
remote("new from-cloud --yolo")
code, out = remote('send from-cloud "Use the bash tool to run exactly: hostname && uname -s. Reply with only the raw output."', timeout=240)
remote("close from-cloud")
if STOP:
    r = gw("POST", f"/v1/sandboxes/{sb}/stop")
    print(f"[{time.time()-t0:5.1f}s] sandbox stopped: state={r.get('state')} cost=${(r.get('costMicro') or 0)/1e6:.4f}")
else:
    print(f"sandbox {sb} kept running (autoStop 20m)")
