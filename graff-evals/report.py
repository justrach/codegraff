"""Result tables for graff-evals.

Lite averages every rep. Live does not: headline is pass @ n=3
(task pass = ≥2/3 reps); list$ and tokens are passing reps only;
failed tasks contribute $0. Wall is a hang detector, not a rank key.
"""
from __future__ import annotations


def fmt_mib(kb):
    if not kb:
        return "—"
    return f"{kb / 1024:.1f}M"


def task_pass(ok, n, suite="core"):
    """Whether one task's reps count as a pass for ranking."""
    if n <= 0:
        return False
    if suite == "live" and n >= 3:
        return ok >= 2
    return ok == n


def _usage_usd(r):
    if r.get("list_usd") is not None:
        return r["list_usd"]
    if r.get("tok_cost_usd") is not None:
        return r["tok_cost_usd"]
    return None


def bucket(records, suite=None):
    """Aggregate records. When suite=='live', cost/tokens come from passes only."""
    live = suite == "live"
    by = {}
    for r in records:
        b = by.setdefault(r["harness"], {
            "n": 0, "ok": 0, "wall": 0.0, "first": 0.0, "first_n": 0,
            "tin": 0, "tcached": 0, "tout": 0, "calls": 0, "rss": 0, "cpu": 0.0,
            "usd": 0.0, "usd_n": 0, "pass_n": 0,
            "tasks": {}, "missing_usage_calls": 0,
        })
        b["n"] += 1
        passed = bool(r.get("outcome_ok"))
        b["ok"] += passed
        tid = r.get("task") or "?"
        t = b["tasks"].setdefault(tid, {"n": 0, "ok": 0})
        t["n"] += 1
        t["ok"] += passed
        b["wall"] += r.get("wall_s", 0) or 0
        if r.get("first_out_s") is not None:
            b["first"] += r["first_out_s"]
            b["first_n"] += 1
        cost_ok = passed if live else True
        if cost_ok:
            if r.get("tok_missing_usage_calls") or r.get("tok_usage_complete") is False:
                b["missing_usage_calls"] += r.get("tok_missing_usage_calls") or 1
                b["tin"] += max((r.get("tok_known_in") or 0) - (r.get("tok_known_cached") or 0), 0)
                b["tcached"] += r.get("tok_known_cached") or 0
                b["tout"] += r.get("tok_known_out") or 0
            b["tin"] += r.get("list_ordinary") if r.get("list_ordinary") is not None else (r.get("tok_in") or 0)
            b["tcached"] += r.get("list_cached") if r.get("list_cached") is not None else (r.get("tok_cached") or 0)
            b["tout"] += r.get("tok_out") or 0
            b["calls"] += r.get("tok_calls") or 0
            usd = _usage_usd(r)
            if usd is not None:
                b["usd"] += usd
                b["usd_n"] += 1
            b["pass_n"] += 1
        b["rss"] = max(b["rss"], r.get("rss_peak_kb") or 0)
        cpu = r.get("cpu_sample_s")
        if not cpu:
            cpu = (r.get("cpu_user_s") or 0) + (r.get("cpu_sys_s") or 0)
        b["cpu"] += cpu
    for b in by.values():
        if b["missing_usage_calls"]:
            for key in ("tin", "tcached", "tout", "usd"):
                b["known_" + key] = b[key]
                b[key] = None
    if live:
        for b in by.values():
            b["task_n"] = len(b["tasks"])
            b["task_ok"] = sum(1 for t in b["tasks"].values() if task_pass(t["ok"], t["n"], "live"))
    return by


def print_table(title, by, suite=None):
    live = suite == "live"
    print(f"\n{title}")
    if live:
        print(f"{'harness':<16} {'pass':>7} {'tasks':>8} {'wall':>8} {'rss':>8} {'in':>8} {'out':>8} {'calls':>6} {'list$':>8}")
    else:
        print(f"{'harness':<16} {'pass':>7} {'wall':>8} {'first':>7} {'rss':>8} {'cpu':>7} {'in':>8} {'cached':>8} {'out':>8} {'calls':>6} {'list$':>8}")
    for h, b in by.items():
        usd = f"${b['usd']:.4f}" if b["usd_n"] and b['usd'] is not None else "—"
        tin, tcached, tout = (b[k] if b[k] is not None else "unknown" for k in ("tin", "tcached", "tout"))
        if live:
            tasks = f"{b.get('task_ok', 0)}/{b.get('task_n', 0)}"
            print(f"{h:<16} {b['ok']}/{b['n']:<5} {tasks:>8} {b['wall']:>7.1f}s "
                  f"{fmt_mib(b['rss']):>8} {tin:>8} {tout:>8} {b['calls']:>6} {usd:>8}")
        else:
            first = (b["first"] / b["first_n"]) if b["first_n"] else 0.0
            print(f"{h:<16} {b['ok']}/{b['n']:<5} {b['wall']:>7.1f}s {first:>6.1f}s "
                  f"{fmt_mib(b['rss']):>8} {b['cpu']:>6.1f}s {tin:>8} {tcached:>8} {tout:>8} {b['calls']:>6} {usd:>8}")
        if b.get("missing_usage_calls"):
            print(f"  totals incomplete: {b['missing_usage_calls']} call(s) missing usage; "
                  f"known token subtotals in={b['known_tin']} cached={b['known_tcached']} out={b['known_tout']}")


def summarize(records):
    suites = sorted({r.get("suite") or "core" for r in records})
    live_only = suites == ["live"]
    print_table("all", bucket(records, suite="live" if live_only else None),
                suite="live" if live_only else None)
    if len(suites) > 1:
        for s in suites:
            print_table(f"suite {s}", bucket([r for r in records if (r.get("suite") or "core") == s], suite=s),
                        suite=s)


def line(rec):
    cpu = rec.get("cpu_sample_s") or ((rec.get("cpu_user_s") or 0) + (rec.get("cpu_sys_s") or 0))
    ok = "✓" if rec.get("outcome_ok") else "✗"
    incomplete = rec.get("tok_missing_usage_calls") or rec.get("tok_usage_complete") is False
    if incomplete:
        rec = dict(rec, list_ordinary="unknown", list_cached="unknown", tok_out="unknown", list_usd="unknown")
    return (f"{ok} {rec.get('harness', '?'):<16} {rec.get('task', '?'):<18} "
            f"r{rec.get('rep', '?')} {rec.get('wall_s', '?')}s "
            f"first={rec.get('first_out_s', '—')}s rss={fmt_mib(rec.get('rss_peak_kb'))} "
            f"cpu={cpu:.1f}s in={rec.get('list_ordinary', rec.get('tok_in', '?'))} "
            f"cached={rec.get('list_cached', rec.get('tok_cached', '—'))} "
            f"out={rec.get('tok_out', '?')} list=${rec.get('list_usd', '—')}"
            + (f" totals incomplete: {rec.get('tok_missing_usage_calls', '?')} call(s) missing usage" if incomplete else ""))
