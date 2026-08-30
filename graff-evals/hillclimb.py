#!/usr/bin/env python3
"""Autoresearch-style hillclimb for graff vs grok-build.

Propose a harness change, run the same tasks, keep only a measured win
on wall / first-token latency / tool calls / tokens / list-price USD.
Never keep grok-build's heap or a 4-tool catalog (ADR 0024).

    ./hillclimb.py self-test
    ./hillclimb.py score results/run-….jsonl
    ./hillclimb.py decide --champion results/a.jsonl --candidate results/b.jsonl
    ./hillclimb.py iterate --suite core --task exact-reply,fix-fib,file-ops
"""
from __future__ import annotations

import argparse, json, os, subprocess, sys, time

from list_price import attach, self_test as price_self_test

ROOT = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(ROOT, "hillclimb")
CANDIDATES_PATH = os.path.join(LOG_DIR, "candidates.json")
LOG_PATH = os.path.join(LOG_DIR, "log.jsonl")
OURS_DEFAULT = "graff-dev"
THEIRS_DEFAULT = "grok"
AXES = ("wall_s", "first_out_s", "tok_calls", "list_tokens", "list_usd")
# Refuse a "win" that is just grok-build's 165M process (ADR 0024).
HEAP_OURS_KB = 20 * 1024
HEAP_THEIRS_KB = 80 * 1024


def load_jsonl(path: str) -> list[dict]:
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            attach(rec)
            rows.append(rec)
    return rows


def bucket(records: list[dict]) -> dict[str, dict]:
    by: dict[str, dict] = {}
    for r in records:
        b = by.setdefault(r.get("harness") or "?", {
            "n": 0, "ok": 0, "wall_s": 0.0, "first_out_s": 0.0, "first_n": 0,
            "tok_calls": 0, "list_tokens": 0, "list_ordinary": 0, "list_cached": 0,
            "list_out": 0, "list_usd": 0.0, "usd_n": 0, "rss_peak_kb": 0, "tasks": [],
        })
        b["n"] += 1
        b["ok"] += bool(r.get("outcome_ok"))
        b["wall_s"] += r.get("wall_s") or 0
        if r.get("first_out_s") is not None:
            b["first_out_s"] += r["first_out_s"]
            b["first_n"] += 1
        b["tok_calls"] += r.get("tok_calls") or 0
        b["list_tokens"] += r.get("list_tokens") or 0
        b["list_ordinary"] += r.get("list_ordinary") or 0
        b["list_cached"] += r.get("list_cached") or 0
        b["list_out"] += r.get("list_out") or 0
        usd = r.get("list_usd")
        if usd is None:
            usd = r.get("tok_cost_usd")
        if usd is not None:
            b["list_usd"] += usd
            b["usd_n"] += 1
        b["rss_peak_kb"] = max(b["rss_peak_kb"], r.get("rss_peak_kb") or 0)
        b["tasks"].append(r.get("task"))
    for b in by.values():
        b["first_out_s"] = (b["first_out_s"] / b["first_n"]) if b["first_n"] else 0.0
        b["list_usd"] = round(b["list_usd"], 6)
        b["pass"] = f"{b['ok']}/{b['n']}"
    return by


def table(by: dict[str, dict]) -> str:
    hdr = f"{'harness':<22} {'pass':>7} {'wall':>8} {'first':>7} {'calls':>6} {'tokens':>9} {'in':>8} {'cached':>8} {'out':>7} {'list$':>9} {'rss':>8}"
    lines = [hdr]
    for h, b in by.items():
        rss = f"{b['rss_peak_kb'] / 1024:.1f}M" if b["rss_peak_kb"] else "—"
        lines.append(
            f"{h:<22} {b['pass']:>7} {b['wall_s']:>7.1f}s {b['first_out_s']:>6.1f}s "
            f"{b['tok_calls']:>6} {b['list_tokens']:>9} {b['list_ordinary']:>8} "
            f"{b['list_cached']:>8} {b['list_out']:>7} ${b['list_usd']:<8.4f} {rss:>8}"
        )
    return "\n".join(lines)


def _delta(cand: float, champ: float) -> tuple[float, str]:
    if champ == 0 and cand == 0:
        return 0.0, "wash"
    if champ == 0:
        return 1.0, "up"
    rel = (cand - champ) / champ
    if abs(rel) < 0.02:
        return rel, "wash"
    return rel, ("win" if rel < 0 else "loss")


def decide(champ: dict, cand: dict, theirs: dict | None = None, candidate_id: str = "") -> dict:
    """Keep only if pass holds and a majority of axes improve. Cite numbers."""
    reasons = []
    if cand["ok"] < champ["ok"]:
        return {"keep": False, "why": "pass rate dropped", "axes": {}, "champ": champ, "cand": cand}
    if cand["rss_peak_kb"] >= HEAP_THEIRS_KB and champ["rss_peak_kb"] <= HEAP_OURS_KB:
        return {"keep": False, "why": "heap steal (ADR 0024: refuse grok-build RSS)", "axes": {}, "champ": champ, "cand": cand}
    if "4-tool" in (candidate_id or "") or "four-tool" in (candidate_id or ""):
        return {"keep": False, "why": "4-tool catalog is forbidden (ADR 0024)", "axes": {}, "champ": champ, "cand": cand}

    axes = {}
    wins = 0
    for name in AXES:
        rel, verdict = _delta(cand[name], champ[name])
        axes[name] = {"champ": champ[name], "cand": cand[name], "rel": round(rel, 4), "verdict": verdict}
        if verdict == "win":
            wins += 1
        reasons.append(f"{name}: {champ[name]} → {cand[name]} ({verdict}, {rel:+.1%})")

    # Majority of the five named axes, and list-price USD must not get worse
    # unless we also gained a pass.
    keep = cand["ok"] >= champ["ok"] and wins >= 3 and axes["list_usd"]["verdict"] != "loss"
    if axes["list_usd"]["verdict"] == "loss" and cand["ok"] > champ["ok"]:
        keep = wins >= 3
    why = ("keep: " if keep else "drop: ") + "; ".join(reasons)
    out = {"keep": keep, "why": why, "axes": axes, "wins": wins, "champ": {
        k: champ[k] for k in ("pass", "wall_s", "first_out_s", "tok_calls", "list_tokens", "list_usd", "rss_peak_kb")
    }, "cand": {k: cand[k] for k in ("pass", "wall_s", "first_out_s", "tok_calls", "list_tokens", "list_usd", "rss_peak_kb")}}
    if theirs:
        out["theirs"] = {k: theirs[k] for k in ("pass", "wall_s", "first_out_s", "tok_calls", "list_tokens", "list_usd", "rss_peak_kb")}
    return out


def append_log(entry: dict) -> None:
    os.makedirs(LOG_DIR, exist_ok=True)
    entry = dict(entry)
    entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(LOG_PATH, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def run_eval(harnesses: str, model: str, suite: str, tasks: list[str] | None, reps: int, jobs: int) -> str:
    cmd = [sys.executable, os.path.join(ROOT, "run.py"),
           "--harness", harnesses, "--model", model, "--suite", suite,
           "--reps", str(reps), "-j", str(jobs)]
    if tasks:
        for t in tasks:
            cmd += ["--task", t]
    print("+", " ".join(cmd), flush=True)
    proc = subprocess.run(cmd, cwd=ROOT)
    if proc.returncode != 0:
        raise SystemExit(f"run.py exited {proc.returncode}")
    results = os.path.join(ROOT, "results")
    files = sorted(n for n in os.listdir(results) if n.startswith("run-") and n.endswith(".jsonl"))
    if not files:
        raise SystemExit("run.py produced no results/run-*.jsonl")
    return os.path.join(results, files[-1])


def cmd_score(args) -> None:
    rows = load_jsonl(args.jsonl)
    by = bucket(rows)
    print(table(by))
    if args.json:
        print(json.dumps(by, indent=2))


def cmd_decide(args) -> None:
    champ_src = load_jsonl(args.champion)
    cand_src = champ_src if args.same_file else load_jsonl(args.candidate)
    cand_name = args.cand_harness or args.ours
    champ_rows = [r for r in champ_src if r.get("harness") == args.ours]
    cand_rows = [r for r in cand_src if r.get("harness") == cand_name]
    theirs_rows = [r for r in cand_src if r.get("harness") == args.theirs]
    if not theirs_rows:
        theirs_rows = [r for r in champ_src if r.get("harness") == args.theirs]
    if not champ_rows or not cand_rows:
        raise SystemExit(f"need rows for {args.ours} and {cand_name}")
    by_c, by_k = bucket(champ_rows), bucket(cand_rows)
    champ, cand = by_c[args.ours], by_k[cand_name]
    theirs = bucket(theirs_rows)[args.theirs] if theirs_rows else None
    print("champion\n" + table(by_c))
    print("\ncandidate\n" + table(by_k))
    if theirs:
        print("\ntheirs\n" + table({args.theirs: theirs}))
    d = decide(champ, cand, theirs, candidate_id=args.candidate_id)
    print("\n" + ("KEEP" if d["keep"] else "DROP"))
    print(d["why"])
    append_log({"kind": "decide", "candidate_id": args.candidate_id, **{k: d[k] for k in d if k != "axes"}, "axes": d["axes"]})
    if args.json:
        print(json.dumps(d, indent=2))


def cmd_iterate(args) -> None:
    with open(CANDIDATES_PATH) as f:
        cands = json.load(f)["candidates"]
    if args.only:
        want = {s.strip() for s in args.only.split(",") if s.strip()}
        cands = [c for c in cands if c["id"] in want]
    else:
        cands = [c for c in cands if not c.get("kept")]
    tasks = [t.strip() for t in (args.task or "").split(",") if t.strip()] or None
    harnesses = [args.ours]
    if args.theirs:
        harnesses.append(args.theirs)
    harnesses += [c["harness"] for c in cands]
    path = run_eval(",".join(harnesses), args.model, args.suite, tasks, args.reps, args.jobs)
    rows = load_jsonl(path)
    by = bucket(rows)
    print("\n" + table(by))
    blocked = []
    if args.theirs and args.theirs not in by:
        blocked.append(f"{args.theirs} produced no rows")
    elif args.theirs:
        theirs_err = [r for r in rows if r.get("harness") == args.theirs and r.get("error")]
        if theirs_err:
            blocked.append(theirs_err[0].get("error") or "theirs error")
    champ = by.get(args.ours)
    if not champ:
        raise SystemExit(f"champion {args.ours} missing from {path}")
    for c in cands:
        cand = by.get(c["harness"])
        if not cand:
            print(f"DROP {c['id']}: no rows")
            append_log({"kind": "iterate", "candidate_id": c["id"], "keep": False, "why": "no rows", "results": path})
            continue
        d = decide(champ, cand, by.get(args.theirs), candidate_id=c["id"])
        print(f"\n{c['id']}: {'KEEP' if d['keep'] else 'DROP'}")
        print(d["why"])
        append_log({"kind": "iterate", "candidate_id": c["id"], "results": path, "blocked": blocked, **d})
    if blocked:
        print("\nblocked-honest:", "; ".join(blocked))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("self-test")
    p.set_defaults(fn=lambda _: (price_self_test(), _decide_self_test(), print("hillclimb self-test ok")))

    p = sub.add_parser("score")
    p.add_argument("jsonl")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_score)

    p = sub.add_parser("decide")
    p.add_argument("--champion", required=True)
    p.add_argument("--candidate", default=None)
    p.add_argument("--same-file", action="store_true")
    p.add_argument("--ours", default=OURS_DEFAULT)
    p.add_argument("--cand-harness", default=None)
    p.add_argument("--theirs", default=THEIRS_DEFAULT)
    p.add_argument("--candidate-id", default="")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_decide)

    p = sub.add_parser("iterate")
    p.add_argument("--ours", default=OURS_DEFAULT)
    p.add_argument("--theirs", default=THEIRS_DEFAULT)
    p.add_argument("--model", default="grok-4.6")
    p.add_argument("--suite", default="core")
    p.add_argument("--task", default="")
    p.add_argument("--reps", type=int, default=1)
    p.add_argument("--jobs", "-j", type=int, default=1)
    p.add_argument("--only", default="")
    p.set_defaults(fn=cmd_iterate)

    args = ap.parse_args()
    if args.cmd == "decide" and not args.candidate and not args.same_file:
        ap.error("decide needs --candidate or --same-file")
    if args.cmd == "decide" and args.same_file:
        args.candidate = args.champion
    args.fn(args)


def _decide_self_test() -> None:
    champ = {"ok": 3, "n": 3, "pass": "3/3", "wall_s": 30.0, "first_out_s": 2.0,
             "tok_calls": 10, "list_tokens": 20_000, "list_usd": 0.05, "rss_peak_kb": 9000}
    better = dict(champ, wall_s=20.0, tok_calls=6, list_tokens=12_000, list_usd=0.03, first_out_s=1.5)
    d = decide(champ, better)
    assert d["keep"], d
    worse = dict(champ, ok=2, wall_s=10.0, list_usd=0.01)
    d = decide(champ, worse)
    assert not d["keep"]
    heap = dict(better, rss_peak_kb=170_000)
    d = decide(champ, heap)
    assert not d["keep"]
    catalog = decide(champ, better, candidate_id="four-tool-copy")
    assert not catalog["keep"]


if __name__ == "__main__":
    main()
