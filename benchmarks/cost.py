#!/usr/bin/env python3
"""Cost per task: graff vs Claude Code vs Codex on the shared tasks.

Each tool reports cost differently, so we normalize to USD:
  * Claude Code : total_cost_usd from `claude -p --output-format json`
  * Codex       : computed from its reported tokens at gpt-5.5 gateway prices
  * graff       : turn.cost_usd from `graff --model <m> --json` (gateway-metered)

We benchmark graff on cheap models that the gateway prices (deepseek-v4-pro,
glm-5.2). graff cannot self-meter the gateway `gpt-5.5` alias (not in its local
price table, so it returns $0), which is why it is omitted here. The cost story
is model freedom, not the harness: on the SAME model token usage is comparable.

Prereqs: graff, claude, codex on PATH and authenticated.
Run:     python3 benchmarks/cost.py
"""
import subprocess, json, time, os, statistics
from tasks import TASKS
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# codegraff gateway prices, USD per 1M tokens: (input, output, cached_input)
# https://codegraff.com/docs/models
PRICES = {"gpt-5.5": (5.00, 30.00, 0.50)}
GRAFF_MODELS = ["deepseek-v4-pro", "glm-5.2"]

def sh(cmd, stdin="", timeout=360):
    t = time.time()
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=timeout)
        return p.stdout, round(time.time() - t)
    except subprocess.TimeoutExpired:
        return "", round(time.time() - t)

def claude(task):
    out, w = sh(["claude", "-p", TASKS[task], "--output-format", "json"])
    try: d = json.loads(out)
    except Exception: d = {}
    m = (list((d.get("modelUsage") or {}).keys()) or ["?"])[0]
    return ("Claude Code", m, d.get("total_cost_usd"), w)

def codex(task):
    # codex exec reads stdin; empty stdin (the default here) gives EOF so it uses
    # the positional prompt instead of hanging.
    out, w = sh(["codex", "exec", "-s", "read-only", "--json", TASKS[task]])
    usage = None
    for l in out.splitlines():
        try: e = json.loads(l)
        except Exception: continue
        if e.get("type") == "turn.completed": usage = e.get("usage")
    u = usage or {}
    inp, cached = u.get("input_tokens", 0), u.get("cached_input_tokens", 0)
    outp = u.get("output_tokens", 0) + u.get("reasoning_output_tokens", 0)
    pi, po, pc = PRICES["gpt-5.5"]
    cost = ((inp - cached) * pi + cached * pc + outp * po) / 1e6 if inp else None
    return ("Codex", "gpt-5.5", cost, w)

def graff(task, model):
    req = json.dumps({"type": "user", "text": TASKS[task]}) + "\n"
    out, w = sh(["graff", "--model", model, "--json"], stdin=req)
    cost = None
    for l in out.splitlines():
        try: e = json.loads(l)
        except Exception: continue
        if e.get("type") == "turn": cost = e.get("cost_usd")
    return ("graff", model, cost, w)

rows = []
for task in TASKS:
    print(f"=== {task} ===", flush=True)
    for fn in (claude, codex):
        tool, m, cost, w = fn(task); rows.append((tool, m, cost))
        print(f"  {tool:12s} {m:18s} ${(cost if cost is not None else float('nan')):.4f}  {w}s", flush=True)
    for gm in GRAFF_MODELS:
        tool, m, cost, w = graff(task, gm); rows.append((tool, m, cost))
        print(f"  {tool:12s} {m:18s} ${(cost if cost is not None else float('nan')):.4f}  {w}s", flush=True)

print("\n=== average USD/task ===")
for tool, m in [("Claude Code", None), ("Codex", "gpt-5.5"), ("graff", "deepseek-v4-pro"), ("graff", "glm-5.2")]:
    cs = [c for (t, mm, c) in rows if t == tool and (m is None or mm == m) and c is not None]
    if cs: print(f"  {tool} / {m or '?'}: ${statistics.mean(cs):.4f}")
