#!/usr/bin/env python3
"""Automated integration test for the graff --json live control protocol.

Spawns `graff --json`, sends each control request (set_model / compact /
set_mode / set_agent) plus error paths, and asserts the structured ack/error
events. Deterministic and offline: a dummy CODEGRAFF_API_KEY lets the session
start and switch within codegraff, while switching to a keyless provider
exercises the error path -- no real API calls.

Usage: python3 scripts/test-json-controls.py [path-to-graff]
Exit 0 if all assertions pass, 1 otherwise.
"""
import json, os, subprocess, sys, tempfile

BIN = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff"

# (request, predicate(event)->bool, human description)
CASES = [
    ({"type": "set_mode", "mode": "plan"},
     lambda e: e.get("type") == "mode" and e.get("ok") and e.get("mode") == "plan",
     "set_mode plan -> mode ack"),
    ({"type": "set_mode", "mode": "normal"},
     lambda e: e.get("type") == "mode" and e.get("mode") == "normal",
     "set_mode normal -> mode ack"),
    ({"type": "set_mode", "mode": "sideways"},
     lambda e: e.get("type") == "error" and "plan" in e.get("message", ""),
     "set_mode invalid -> error"),
    ({"type": "set_agent", "id": "reviewer"},
     lambda e: e.get("type") == "agent" and e.get("ok") and e.get("id") == "reviewer" and e.get("chars", 0) > 0,
     "set_agent reviewer -> agent ack"),
    ({"type": "set_agent", "id": ""},
     lambda e: e.get("type") == "agent" and e.get("ok") and e.get("id") == "",
     "set_agent reset -> agent ack"),
    ({"type": "set_agent", "id": "definitely-not-an-agent"},
     lambda e: e.get("type") == "error" and "unknown agent" in e.get("message", ""),
     "set_agent unknown -> error"),
    ({"type": "set_model", "model": "deepseek-v4-pro", "provider": "codegraff"},
     lambda e: e.get("type") == "model" and e.get("ok") and e.get("provider") == "codegraff" and e.get("model") == "deepseek-v4-pro",
     "set_model provider/model -> model ack"),
    ({"type": "set_model", "model": "claude-opus-4-8", "provider": "anthropic"},
     lambda e: e.get("type") == "error" and "key" in e.get("message", "").lower(),
     "set_model provider/model keyless -> error"),
    ({"type": "set_model", "provider": "", "model": "", "name": ""},
     lambda e: e.get("type") == "error" and "non-empty" in e.get("message", ""),
     "set_model empty -> error"),
    ({"type": "compact"},
     lambda e: e.get("type") == "compact" and e.get("ok") and e.get("chars") == 0,
     "compact (empty history) -> compact ack"),
    ({"type": "set_effort", "level": "high"},
     lambda e: e.get("type") == "effort" and e.get("ok") and e.get("level") == "high",
     "set_effort high -> effort ack"),
    ({"type": "set_effort", "level": "medium"},
     lambda e: e.get("type") == "effort" and e.get("level") == "medium",
     "set_effort medium -> effort ack"),
    ({"type": "set_effort", "level": "sideways"},
     lambda e: e.get("type") == "error" and "low" in e.get("message", ""),
     "set_effort invalid -> error"),
    ({"type": "set_fast", "on": True},
     lambda e: e.get("type") == "fast" and e.get("ok") and e.get("on") is True,
     "set_fast on -> fast ack"),
    ({"type": "set_fast", "on": False},
     lambda e: e.get("type") == "fast" and e.get("on") is False,
     "set_fast off -> fast ack"),
]
CONTROL_TYPES = {"model", "compact", "mode", "agent", "effort", "fast", "error"}

def run():
    env = dict(os.environ)
    env["CODEGRAFF_API_KEY"] = "dummy-key-for-test"   # lets the session start + switch within codegraff
    env["GRAFF_NO_TELEMETRY"] = "1"
    env["HOME"] = tempfile.mkdtemp()                   # isolate: no codex auth, no real keys
    for k in list(env):
        if k.endswith("_API_KEY") and k != "CODEGRAFF_API_KEY":
            del env[k]
    stdin = "".join(json.dumps(c[0]) + "\n" for c in CASES)
    try:
        p = subprocess.run([BIN, "--json"], input=stdin, text=True,
                           capture_output=True, timeout=60, env=env)
        out = p.stdout
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "ignore") if isinstance(e.stdout, bytes) else (e.stdout or "")

    acks = []
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") in CONTROL_TYPES:
            acks.append(ev)

    passed = failed = 0
    for i, (req, pred, desc) in enumerate(CASES):
        ev = acks[i] if i < len(acks) else None
        ok = ev is not None and pred(ev)
        print(f"  {'PASS' if ok else 'FAIL'}  {desc}")
        if not ok:
            print(f"        got: {json.dumps(ev) if ev else '(no event)'}")
            failed += 1
        else:
            passed += 1
    print(f"\n  {passed}/{len(CASES)} passed")
    return failed == 0

if __name__ == "__main__":
    print(f"graff --json live-control protocol test ({BIN})\n")
    sys.exit(0 if run() else 1)
