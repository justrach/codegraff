#!/usr/bin/env python3
"""Cube transport proof: run `graff serve` inside a Daytona sandbox (via the
codegraff gateway) and stream a real agent turn from this Mac through the
Daytona preview URL — the exact pipe the iOS app will use.

Steps: create sandbox -> install graff -> start serve (async exec, detached)
-> mint preview URL -> create session + stream one NDJSON turn from outside
-> report cost meter. Leaves the sandbox running (autoStop reaps it) so a
client (e.g. the iOS app via GRAFF_SERVE_BASE/GRAFF_SERVE_TOKEN) can reuse
it via .graff/cube-state.json. Run from the repo root:

  python3 scripts/e2e-cube-serve.py
"""
import json, os, secrets, sys, time, urllib.request, urllib.error

GATEWAY = "https://gateway.codegraff.com"
KEY = json.load(open(os.path.expanduser("~/.simple-harness-codegraff.json")))["api_key"]
STATE = os.path.join(".graff", "cube-state.json")
PORT = 8787


def mask(s):
    return (s[:6] + "…" + s[-4:]) if isinstance(s, str) and len(s) > 14 else "<short>"


def req(method, url, body=None, headers=None, timeout=120, stream=False):
    # Gateway sits behind Cloudflare bot-fight, which 1010-blocks the default
    # python-urllib UA; send a recognized client UA like the harness does.
    h = {"Content-Type": "application/json", "User-Agent": "claude-code/1.0.0"}
    if headers:
        h.update(headers)
    r = urllib.request.Request(url, method=method, headers=h,
                               data=json.dumps(body).encode() if body is not None else None)
    resp = urllib.request.urlopen(r, timeout=timeout)
    if stream:
        return resp
    data = resp.read().decode()
    return json.loads(data) if data.strip() else {}
def gw(method, path, body=None, **kw):
    return req(method, GATEWAY + path, body, headers={"Authorization": f"Bearer {KEY}"}, **kw)


def execute(sb, command, timeout=90, asynch=False):
    body = {"command": command, "timeoutSeconds": timeout}
    if asynch:
        body["async"] = True
    return gw("POST", f"/v1/sandboxes/{sb}/exec", body, timeout=timeout + 10)


def step(msg):
    print(f"\n== {msg}", flush=True)


try:
    # 1. sandbox
    step("create sandbox")
    sb = gw("POST", "/v1/sandboxes", {"autoStopMinutes": 30, "labels": {"purpose": "cube-demo"}})
    sbid = sb["id"]
    print(f"   id={sbid} state={sb.get('state')}")
    info = sb
    for _ in range(60):
        info = gw("GET", f"/v1/sandboxes/{sbid}")
        if info.get("state") == "started":
            break
        time.sleep(2)
    else:
        sys.exit(f"sandbox never reached started: {info}")
    print(f"   state={info['state']} cpu={info.get('cpu')} mem={info.get('memory')}GiB")

    # 2. install graff
    step("install graff (release binary)")
    r = execute(sbid, "curl -fsSL https://raw.githubusercontent.com/justrach/codegraff/main/install.sh | bash", timeout=90)
    print(f"   exit={r.get('exitCode')} tail: {r.get('result', '')[-200:].strip()!r}")
    if r.get("exitCode") != 0:
        sys.exit("install failed")
    v = execute(sbid, "$HOME/bin/graff --version 2>&1 || $HOME/bin/graff --help 2>&1 | head -1", timeout=30)
    print(f"   graff: {v.get('result', '').strip()[:120]}")

    # 3. start serve detached on 0.0.0.0 with a fresh token
    step("start graff serve inside the sandbox")
    serve_token = secrets.token_urlsafe(24)
    launch = (f"CODEGRAFF_API_KEY={KEY} exec $HOME/bin/graff serve "
              f"--host 0.0.0.0 --port {PORT} --token {serve_token}")
    a = execute(sbid, launch, asynch=True)
    print(f"   execId={a.get('execId')} state={a.get('state')}")
    for i in range(20):
        probe = execute(sbid, f"curl -s -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{PORT}/", timeout=15)
        code = probe.get("result", "").strip()
        if code and code != "000":
            print(f"   serve is listening (local probe HTTP {code})")
            break
        time.sleep(1)
    else:
        log = execute(sbid, f"cat /tmp/cg-exec/{a.get('execId')}.out 2>/dev/null | tail -5", timeout=15)
        sys.exit(f"serve never came up; log tail: {log.get('result')!r}")

    # 4. preview URL (the new gateway endpoint)
    step("mint Daytona preview URL for the serve port")
    pv = gw("GET", f"/v1/sandboxes/{sbid}/ports/{PORT}/preview")
    purl, ptok = pv["url"].rstrip("/"), pv.get("token")
    print(f"   url={purl}")
    print(f"   preview token={mask(ptok) if ptok else 'none (public)'}")

    cube_headers = {"Authorization": f"Bearer {serve_token}"}
    if ptok:
        cube_headers["x-daytona-preview-token"] = ptok

    # 5. create a session THROUGH the preview URL, from this Mac
    step("create session through the cube pipe")
    s = req("POST", f"{purl}/v1/sessions", {"model": "codegraff"}, headers=cube_headers, timeout=60)
    sid = s["session_id"]
    print(f"   session_id={sid}")

    # 6. stream one real turn
    step("stream a live turn (NDJSON) from outside")
    turn = {"type": "user", "text": "Reply with exactly: CUBE-LIVE-VIA-DAYTONA — nothing else."}
    resp = req("POST", f"{purl}/v1/sessions/{sid}", turn, headers=cube_headers, timeout=240, stream=True)
    final_text, events = [], 0
    for raw in resp:
        line = raw.decode().strip()
        if not line:
            continue
        events += 1
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            print(f"   ?? {line[:120]}")
            continue
        et = ev.get("type")
        if et == "text":
            final_text.append(ev.get("text", ""))
            print(f"   [text] {ev.get('text', '')[:100]}")
        elif et in ("turn", "error"):
            print(f"   [{et}] {json.dumps({k: v for k, v in ev.items() if k != 'type'})[:200]}")
            break
        else:
            print(f"   [{et}] {str(ev)[:100]}")
    print(f"   ({events} events)")

    # 7. cost so far
    step("meter")
    try:
        m = gw("GET", f"/v1/sandboxes/{sbid}/meter")
        print(f"   uptime={m.get('current_uptime_seconds')}s "
              f"billed_so_far=${(m.get('billed_so_far_micro_usd') or 0) / 1e6:.4f} "
              f"unbilled=${(m.get('unbilled_cost_micro_usd') or 0) / 1e6:.4f}")
    except Exception as e:
        print(f"   meter read failed: {e}")

    os.makedirs(".graff", exist_ok=True)
    json.dump({"sandbox_id": sbid, "preview_url": purl, "preview_token": ptok,
               "serve_token": serve_token, "session_id": sid,
               "exec_id": a.get("execId")}, open(STATE, "w"), indent=1)
    print(f"\nstate -> {STATE}")
    verdict = "".join(final_text)
    print(f"\nVERDICT: {'PASS' if 'CUBE-LIVE-VIA-DAYTONA' in verdict else 'CHECK OUTPUT'} — streamed reply: {verdict[:200]!r}")
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code} on {e.url}: {e.read().decode()[:400]}")
