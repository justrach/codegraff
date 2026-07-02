#!/usr/bin/env python3
"""Probe gateway.codegraff.com reasoning-budget controls for issue #89.

Reads the API key from env CG_API_KEY (never hardcode it). Fires the same
matrix of reasoning knobs the issue describes, plus the *requested* budget
controls, and reports HTTP status + reasoning-token count + latency for each
so we can tell empirically whether the gateway now honors a bounded budget.

  CG_API_KEY=cg_sk_... python3 scripts/probe-reasoning-89.py
"""
import os, sys, json, time, urllib.request, urllib.error

KEY = os.environ.get("CG_API_KEY")
if not KEY:
    sys.exit("set CG_API_KEY (the cg_sk_... gateway key)")
URL = os.environ.get("CG_URL", "https://gateway.codegraff.com/v1/chat/completions")
MODEL = os.environ.get("CG_MODEL", "deepseek-v4-pro")
# Gateway sits behind Cloudflare bot-fight, which 1010-blocks the default
# Python-urllib signature; send a recognized client UA like the harness does.
UA = os.environ.get("CG_UA", "claude-code/1.0.0")

# Multi-constraint logic prompt — reliably induces hidden reasoning tokens.
PROMPT = (
    "Three friends - Ada, Ben, Cy - each have a different pet (cat, dog, fish) "
    "and live in a different city (NYC, LA, SF). Ada does not have the cat. "
    "The dog owner lives in LA. Ben lives in SF. Cy does not have the fish. "
    "Who has which pet and lives where? Answer in one short line."
)


def reasoning_tokens(usage):
    if not usage:
        return None
    d = usage.get("completion_tokens_details") or {}
    if "reasoning_tokens" in d:
        return d.get("reasoning_tokens")
    return usage.get("reasoning_tokens")


def call(label, extra):
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": 2048,
        "stream": False,
    }
    body.update(extra)
    req = urllib.request.Request(
        URL,
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {KEY}",
            "Content-Type": "application/json",
            "User-Agent": UA,
        },
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            j = json.load(r)
        dt = time.time() - t0
        u = j.get("usage", {}) or {}
        rt = reasoning_tokens(u)
        print(f"[200] {label:34} {dt:6.1f}s  reasoning={rt}  completion={u.get('completion_tokens')}  total={u.get('total_tokens')}")
        return {"label": label, "status": 200, "latency": round(dt, 2),
                "reasoning_tokens": rt, "completion_tokens": u.get("completion_tokens")}
    except urllib.error.HTTPError as e:
        dt = time.time() - t0
        err = e.read().decode()[:400]
        print(f"[{e.code}] {label:34} {dt:6.1f}s  {err}")
        return {"label": label, "status": e.code, "latency": round(dt, 2), "error": err}
    except Exception as e:
        print(f"[ERR] {label:34} {e}")
        return {"label": label, "error": str(e)}


CASES = [
    ("baseline (no knob)",            {}),
    ("thinking.disabled",             {"thinking": {"type": "disabled"}}),
    ("reasoning_effort=minimal",      {"reasoning_effort": "minimal"}),
    ("reasoning_effort=low",          {"reasoning_effort": "low"}),
    ("reasoning_effort=medium",       {"reasoning_effort": "medium"}),
    ("reasoning_effort=high",         {"reasoning_effort": "high"}),
    ("reasoning.effort=low",          {"reasoning": {"effort": "low"}}),
    ("reasoning.max_tokens=256",      {"reasoning": {"max_tokens": 256}}),
    ("reasoning.budget_tokens=256",   {"reasoning": {"budget_tokens": 256}}),
    ("thinking.budget_tokens=256",    {"thinking": {"type": "enabled", "budget_tokens": 256}}),
]

if __name__ == "__main__":
    print(f"# {MODEL} @ {URL}  (UA={UA})\n")
    results = [call(l, e) for l, e in CASES]
    print("\n" + json.dumps(results, indent=2))
