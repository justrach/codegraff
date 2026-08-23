#!/usr/bin/env python3
"""Session dashboard for graff harness runs: .graff/ -> self-contained HTML.

Answers "why does it look dead?" — the question every silent stall provokes.
Reads the run traces (.graff/traces/*.jsonl), trajectories (absolute start
time), and session state (.graff/sessions/) and renders one HTML file:

  - per-run status: ALIVE / STALLED / ENDED-ON-ERROR / IDLE / DONE
  - STALLED = last event is a tool result with no follow-up api event, i.e.
    the turn loop stopped right after a successful tool call — the exact
    signature of the degenerate-empty-completion bug (content: null).
  - per-run timeline sparkline of api/tool events, context-token trend,
    api latency, retry/error counts.

No dependencies, no server: python3 scripts/graff-dashboard.py [ROOT ...]
writes dashboard.html (default: first root's cwd) and prints the path.
"""

import html
import json
import os
import sys
import time

STALL_NOTE = (
    "last event is a tool result with no follow-up model call — "
    "the turn loop stopped here"
)


def read_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except OSError:
        pass
    return out


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ProcessLookupError, PermissionError):
        return False


def load_run(root, run_id):
    trace_path = os.path.join(root, ".graff", "traces", run_id + ".jsonl")
    events = read_jsonl(trace_path)
    traj = read_jsonl(os.path.join(root, ".graff", "trajectories", run_id + ".jsonl"))
    start_unix_ms = None
    for e in traj:
        if isinstance(e.get("unix_ms"), int):
            start_unix_ms = e["unix_ms"]
            break
    return {
        "run_id": run_id,
        "pid": next((e.get("pid") for e in events if e.get("pid")), None),
        "events": events,
        "start_unix_ms": start_unix_ms,
        "trace_mtime": os.path.getmtime(trace_path) if os.path.exists(trace_path) else None,
    }


def analyze(run, now_s):
    evs = [e for e in run["events"] if e.get("ev") in ("api", "tool")]
    apis = [e for e in evs if e["ev"] == "api"]
    tools = [e for e in evs if e["ev"] == "tool"]
    errors = [e for e in evs if e.get("is_error")]
    retries = [e for e in run["events"] if e.get("ev") == "retry"]

    model = next((e.get("model") for e in reversed(apis) if e.get("model")), "?")
    last = max(evs, key=lambda e: e.get("t", 0)) if evs else None
    last_t = last.get("t", 0) if last else 0
    span_ms = max((e.get("t", 0) for e in run["events"]), default=0)

    # absolute wall-clock of last activity: prefer trajectory start, else trace mtime - span
    if run["start_unix_ms"]:
        last_unix_s = run["start_unix_ms"] / 1000.0 + last_t / 1000.0
    elif run["trace_mtime"]:
        last_unix_s = run["trace_mtime"] - (span_ms - last_t) / 1000.0
    else:
        last_unix_s = None
    idle_s = max(0.0, now_s - last_unix_s) if last_unix_s else None

    alive = pid_alive(run["pid"])
    if last is None:
        status, note = "EMPTY", "no api/tool events recorded"
    elif errors and errors[-1].get("t", 0) >= (apis[-1].get("t", 0) if apis else 0):
        status, note = "ERROR", "last model call failed (is_error)"
    elif last["ev"] == "tool":
        if alive:
            # A live process whose last event is an un-answered tool result is
            # either mid-request (fine; wait for the api row on completion) or
            # wedged. Long idle tips it to stalled.
            if idle_s is not None and idle_s > 300:
                status, note = "STALLED", STALL_NOTE
            else:
                status, note = "RUNNING", "awaiting next model call"
        else:
            status, note = "STALLED", STALL_NOTE + "; process gone"
    elif alive:
        status = "RUNNING" if (idle_s or 0) < 300 else "IDLE"
        note = "" if status == "RUNNING" else f"idle {fmt_dur(idle_s)}"
    else:
        status, note = "DONE", ""

    ctx = next((e.get("context_tokens") for e in reversed(apis) if e.get("context_tokens")), None)
    return {
        "run_id": run["run_id"], "pid": run["pid"],
        "model": model, "status": status, "note": note, "idle_s": idle_s,
        "alive": alive, "api_calls": len(apis), "tool_calls": len(tools),
        "errors": len(errors), "retries": len(retries), "ctx": ctx,
        "last_event": f"{last['ev']}:{last.get('name', last.get('agent', ''))}" if last else "-",
        "last_t": last_t, "span_s": span_ms / 1000.0,
        "apis": [(e.get("t", 0), e.get("ms", 0)) for e in apis],
        "tools_t": [e.get("t", 0) for e in tools],
        "ctx_series": [(e.get("t", 0), e.get("context_tokens")) for e in apis if e.get("context_tokens")],
    }


def fmt_dur(s):
    if s is None:
        return "-"
    s = int(s)
    if s < 90:
        return f"{s}s"
    if s < 5400:
        return f"{s // 60}m{s % 60:02d}s"
    return f"{s // 3600}h{(s % 3600) // 60:02d}m"


def esc(x):
    return html.escape(str(x))


def sparkline(run, width=320, height=40):
    span = max(run["span_s"] * 1000.0, 1.0)
    parts = []
    max_ms = max((ms for _, ms in run["apis"]), default=1) or 1
    max_ctx = max((c for _, c in run["ctx_series"]), default=1) or 1
    for t, ms in run["apis"]:
        x, h = t / span * width, 4 + (ms / max_ms) * (height - 10)
        parts.append(f'<rect x="{x:.1f}" y="{height - h:.1f}" width="2" height="{h:.1f}" fill="#059669"><title>api {int(t/1000)}s · {ms}ms</title></rect>')
    for t in run["tools_t"]:
        parts.append(f'<rect x="{t / span * width:.1f}" y="{height - 3}" width="2" height="3" fill="#6b7280"><title>tool {int(t/1000)}s</title></rect>')
    if len(run["ctx_series"]) > 1:
        pts = " ".join(f"{t / span * width:.1f},{height - (c / max_ctx) * (height - 12):.1f}" for t, c in run["ctx_series"])
        parts.append(f'<polyline points="{pts}" fill="none" stroke="#9ca3af" stroke-width="1" opacity="0.7"/>')
    return f'<svg width="{width}" height="{height}" class="spark">{"".join(parts)}</svg>'


BADGE = {"RUNNING": "#059669", "DONE": "#6b7280", "STALLED": "#dc2626",
         "ERROR": "#b91c1c", "IDLE": "#d97706", "EMPTY": "#6b7280"}


def render(runs, out_path):
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    rows = []
    order = {"STALLED": 0, "ERROR": 1, "IDLE": 2, "RUNNING": 3, "EMPTY": 4, "DONE": 5}
    for name, r in sorted(runs, key=lambda kv: (order.get(kv[1]["status"], 9), -(kv[1]["last_t"]))):
        color = BADGE.get(r["status"], "#6b7280")
        idle = f' · idle {esc(fmt_dur(r["idle_s"]))}' if r["status"] in ("STALLED", "IDLE") else ""
        rows.append(f"""<tr>
<td><span class="badge" style="background:{color}">{r['status']}</span></td>
<td>{esc(name)}<div class="sub">{r['run_id']} · pid {r['pid'] or '?'} · {'alive' if r['alive'] else 'gone'}</div></td>
<td>{esc(r['model'])}</td>
<td>{r['api_calls']} / {r['tool_calls']}</td>
<td>{r['errors'] + r['retries'] or ''}</td>
<td>{(str(r['ctx'] // 1000) + 'k') if r['ctx'] else '-'}</td>
<td>{sparkline(r)}</td>
<td>{esc(r['note'])}{idle}</td>
</tr>""")
    stalled = sum(1 for _, r in runs if r["status"] == "STALLED")
    doc = f"""<!doctype html><html><head><meta charset="utf-8"><title>graff sessions</title>
<style>
body{{font-family:-apple-system,'Geist Mono',monospace;background:#0b0f0e;color:#d1d5db;margin:2rem}}
h1{{font-size:1.1rem;color:#059669}} table{{border-collapse:collapse;width:100%}}
td,th{{padding:.45rem .6rem;border-bottom:1px solid #1f2937;text-align:left;font-size:.85rem;vertical-align:top}}
th{{color:#9ca3af;font-weight:600}} .badge{{color:#fff;padding:.15rem .5rem;border-radius:.75rem;font-size:.72rem}}
.sub{{color:#6b7280;font-size:.72rem}} .spark{{display:block}} .warn{{color:#f87171;font-size:.8rem;margin:.5rem 0}}
</style></head><body>
<h1>graff sessions</h1><div class="sub">generated {now} · {len(runs)} runs · {stalled} stalled</div>
{'<p class="warn">⚠ stalled runs: the turn loop stopped after a tool result and never re-called the model.</p>' if stalled else ''}
<table><tr><th>status</th><th>session</th><th>model</th><th>api/tools</th><th>err/retry</th><th>ctx</th><th>timeline</th><th>note</th></tr>
{''.join(rows)}</table></body></html>"""
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(doc)


def main():
    roots = sys.argv[1:] or ["."]
    now_s = time.time()
    runs = []
    for root in roots:
        tdir = os.path.join(root, ".graff", "traces")
        if not os.path.isdir(tdir):
            continue
        for fn in sorted(os.listdir(tdir)):
            if fn.endswith(".jsonl"):
                run = load_run(root, fn[:-6])
                if run["events"]:
                    runs.append((os.path.basename(root.rstrip("/")), analyze(run, now_s)))
    out = os.path.join(roots[0], "dashboard.html")
    render(runs, out)
    print(f"{len(runs)} runs -> {out}")
    for name, r in runs:
        print(f"  [{r['status']:>7}] {name}: {r['run_id']} {r['note']}")


if __name__ == "__main__":
    main()
