#!/usr/bin/env python3
"""graff-evals: a self-contained eval environment for coding harnesses.

Every task is a JSON file under tasks/ that declares its fixture files, the
prompt, and a deterministic shell check. The runner materializes a sandbox,
drives any configured harness (harnesses.json) with any model, captures wall
time / first-output latency / token usage, verifies the outcome, and writes
JSONL results plus a summary table.

  ./run.py --harness graff --model grok-4.6              # full suite
  ./run.py --harness grok --task fix-fib --reps 3        # one task, 3 reps
  ./run.py --harness graff,grok --model grok-4.6         # side by side
  ./run.py --interactive                                 # pick + watch live
"""
import argparse, json, os, re, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
TASKS_DIR = os.path.join(ROOT, "tasks")
RESULTS_DIR = os.path.join(ROOT, "results")
SANDBOX_DIR = os.path.join(ROOT, ".sandboxes")

# Current footer: `[usage] N api call(s) · IN in (CACHED cached, W cache writes) + OUT tokens · $X`
# Older footers omitted writes and the dollar tail. Both must parse.
GRAFF_USAGE_RE = re.compile(
    r"\[usage\] (\d+) api call\(s\) · (\d+) in \((\d+) cached(?:, (\d+) cache writes)?\) \+ (\d+) out tokens"
)


def load_tasks():
    tasks = {}
    for name in sorted(os.listdir(TASKS_DIR)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(TASKS_DIR, name)) as f:
            t = json.load(f)
        tasks[t["id"]] = t
    return tasks


def load_harnesses():
    with open(os.path.join(ROOT, "harnesses.json")) as f:
        return json.load(f)


def materialize(task, sandbox):
    if os.path.exists(sandbox):
        shutil.rmtree(sandbox)
    os.makedirs(sandbox)
    for rel, content in task.get("files", {}).items():
        path = os.path.join(sandbox, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
    for cmd in task.get("setup", []):
        subprocess.run(["/bin/sh", "-c", cmd], cwd=sandbox, capture_output=True, timeout=60)


def build_cmd(harness, task, model):
    subst = {"prompt": task["prompt"], "model": model, "repo": REPO}
    cmd = [part.format(**subst) for part in harness["cmd"]]
    if "output-schema" in task.get("requires", []):
        schema = json.dumps(task["schema"], separators=(",", ":"))
        cmd += [part.format(schema=schema, **subst) for part in harness.get("schema_args", [])]
    return cmd


def parse_answer_and_usage(harness, stdout, stderr):
    answer, usage = stdout.strip(), {}
    if harness["answer"] == "grok-stream":
        answer = ""
        for line in stdout.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "result":
                answer = ev.get("result") or ""
                u = ev.get("usage", {})
                usage = {"calls": ev.get("num_turns"), "in": u.get("input_tokens"),
                         "cached": u.get("cache_read_input_tokens"),
                         "out": u.get("output_tokens"), "api_ms": ev.get("duration_api_ms")}
    if harness["answer"] == "pi-json":
        answer, calls, tin, tread, twrite, tout, cost = "", 0, 0, 0, 0, 0, 0.0
        for line in stdout.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = ev.get("message", {})
            if ev.get("type") == "message_end" and msg.get("role") == "assistant":
                u = msg.get("usage", {})
                calls += 1
                tin += u.get("input", 0)
                tread += u.get("cacheRead", 0)
                twrite += u.get("cacheWrite", 0)
                tout += u.get("output", 0)
                cost += u.get("cost", {}).get("total", 0.0)
                answer = "".join(c.get("text", "") for c in msg.get("content", [])
                                 if c.get("type") == "text") or answer
        usage = {"calls": calls, "in": tin + tread + twrite, "cached": tread,
                 "out": tout, "cost_usd": round(cost, 6)}
    if harness.get("usage") == "graff-stderr":
        usage.update(parse_graff_usage(stderr))
    return answer, usage


def parse_graff_usage(stderr):
    m = GRAFF_USAGE_RE.search(stderr)
    if not m:
        return {}
    writes = int(m.group(4) or 0)
    return {"calls": int(m.group(1)), "in": int(m.group(2)),
            "cached": int(m.group(3)), "writes": writes, "out": int(m.group(5))}


def one_run(hname, harness, task, model, rep, live=False):
    sandbox = os.path.join(SANDBOX_DIR, f"{hname}-{task['id']}-r{rep}")
    materialize(task, sandbox)
    cmd = build_cmd(harness, task, model)
    timeout = task.get("timeout_s", 240)
    t0 = time.monotonic()
    first_out = None
    stdout_parts, stderr_parts = [], []
    try:
        p = subprocess.Popen(cmd, cwd=sandbox, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True,
                             env=dict(os.environ, **harness.get("env", {})))
        import selectors
        sel = selectors.DefaultSelector()
        sel.register(p.stdout, selectors.EVENT_READ, "out")
        sel.register(p.stderr, selectors.EVENT_READ, "err")
        open_streams = 2
        while open_streams and time.monotonic() - t0 < timeout:
            for key, _ in sel.select(timeout=0.5):
                chunk = key.fileobj.readline()
                if not chunk:
                    sel.unregister(key.fileobj)
                    open_streams -= 1
                    continue
                if first_out is None:
                    first_out = round(time.monotonic() - t0, 2)
                (stdout_parts if key.data == "out" else stderr_parts).append(chunk)
                if live:
                    sys.stdout.write(chunk if key.data == "out" else f"\x1b[2m{chunk}\x1b[0m")
                    sys.stdout.flush()
        timed_out = p.poll() is None
        if timed_out:
            p.kill()
        p.wait(timeout=10)
        rc = p.returncode
    except FileNotFoundError:
        return {"harness": hname, "task": task["id"], "rep": rep,
                "error": f"harness binary not found: {cmd[0]}", "outcome_ok": False}
    stdout, stderr = "".join(stdout_parts), "".join(stderr_parts)
    wall = round(time.monotonic() - t0, 2)
    answer, usage = parse_answer_and_usage(harness, stdout, stderr)
    with open(os.path.join(sandbox, ".eval-answer.txt"), "w") as f:
        f.write(answer)
    check = subprocess.run(["/bin/sh", "-c", task["check"]], cwd=sandbox,
                           capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, ANSWER_FILE=".eval-answer.txt"))
    rec = {"harness": hname, "task": task["id"], "category": task.get("category", ""),
           "model": model, "rep": rep, "wall_s": wall, "first_out_s": first_out,
           "exit": rc, "timed_out": timed_out, "outcome_ok": check.returncode == 0,
           "answer_head": answer[:120]}
    rec.update({f"tok_{k}": v for k, v in usage.items()})
    if check.returncode != 0 and check.stderr.strip():
        rec["check_note"] = check.stderr.strip()[:200]
    return rec


def _hit(tin, cached):
    return (100.0 * cached / tin) if tin else 0.0


def summarize(records):
    print(f"\n{'task':<18} {'harness':<14} {'ok':>3} {'calls':>5} {'wall':>7} {'ttft':>6} "
          f"{'in':>8} {'cached':>8} {'write':>7} {'out':>6} {'hit':>5}")
    for r in records:
        tin = r.get("tok_in") or 0
        cached = r.get("tok_cached") or 0
        print(f"{r.get('task', '?'):<18} {r.get('harness', '?'):<14} "
              f"{'✓' if r.get('outcome_ok') else '✗':>3} "
              f"{r.get('tok_calls') or 0:>5} {r.get('wall_s') or 0:>6.1f}s "
              f"{r.get('first_out_s') or 0:>5.1f}s {tin:>8} {cached:>8} "
              f"{r.get('tok_writes') or 0:>7} {r.get('tok_out') or 0:>6} "
              f"{_hit(tin, cached):>4.0f}%")

    by = {}
    for r in records:
        b = by.setdefault(r["harness"], {
            "n": 0, "ok": 0, "wall": 0.0, "ttft": 0.0, "calls": 0,
            "tin": 0, "cached": 0, "writes": 0, "tout": 0,
        })
        b["n"] += 1
        b["ok"] += bool(r.get("outcome_ok"))
        b["wall"] += r.get("wall_s") or 0
        b["ttft"] += r.get("first_out_s") or 0
        b["calls"] += r.get("tok_calls") or 0
        b["tin"] += r.get("tok_in") or 0
        b["cached"] += r.get("tok_cached") or 0
        b["writes"] += r.get("tok_writes") or 0
        b["tout"] += r.get("tok_out") or 0
    print(f"\n{'harness':<14} {'pass':>7} {'calls':>6} {'wall':>8} {'ttft':>7} "
          f"{'in_tok':>9} {'cached':>8} {'writes':>7} {'out':>7} {'hit':>5}")
    for h, b in by.items():
        print(f"{h:<14} {b['ok']}/{b['n']:<5} {b['calls']:>6} {b['wall']:>7.1f}s "
              f"{b['ttft']:>6.1f}s {b['tin']:>9} {b['cached']:>8} {b['writes']:>7} "
              f"{b['tout']:>7} {_hit(b['tin'], b['cached']):>4.0f}%")


def interactive(tasks, harnesses):
    tlist = list(tasks.values())
    print("tasks:")
    for i, t in enumerate(tlist):
        print(f"  [{i}] {t['id']:<18} {t.get('category', '')}")
    ti = int(input("task #: ").strip() or "0")
    hnames = list(harnesses)
    for i, h in enumerate(hnames):
        print(f"  [{i}] {h}")
    hi = int(input("harness #: ").strip() or "0")
    hname = hnames[hi]
    harness = harnesses[hname]
    model = input(f"model [{harness.get('default_model', '')}]: ").strip() or harness.get("default_model", "")
    task = tlist[ti]
    print(f"\n── {task['id']} on {hname} ({model}) — live output ──\n")
    rec = one_run(hname, harness, task, model, rep=1, live=True)
    print("\n── verdict ──")
    print(json.dumps(rec, indent=2, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--harness", default="graff", help="comma-separated harness names (see harnesses.json)")
    ap.add_argument("--model", default=None, help="model id (default: per-harness default_model)")
    ap.add_argument("--task", action="append", help="task id filter (repeatable)")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=1,
                    help="run this many tasks at once (suite wall clock; default 1)")
    ap.add_argument("--interactive", action="store_true", help="pick a task+harness, watch it live")
    ap.add_argument("--self-test", action="store_true", help="parse the usage footer shapes and exit")
    args = ap.parse_args()

    if args.self_test:
        return 0 if self_test() else 2

    tasks = load_tasks()
    harnesses = load_harnesses()
    if args.interactive:
        interactive(tasks, harnesses)
        return

    os.makedirs(RESULTS_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out_path = os.path.join(RESULTS_DIR, f"run-{stamp}.jsonl")
    picked = {tid: t for tid, t in tasks.items() if not args.task or tid in args.task}
    records = []
    jobs = []
    for hname in args.harness.split(","):
        harness = harnesses[hname]
        model = args.model or harness.get("default_model", "")
        for task in picked.values():
            missing = [c for c in task.get("requires", []) if c not in harness.get("capabilities", [])]
            if missing:
                print(f"skip {task['id']} on {hname}: needs {missing}", flush=True)
                continue
            for rep in range(1, args.reps + 1):
                jobs.append((hname, harness, task, model, rep))

    def emit(rec, fh, lock=None):
        line = json.dumps(rec, ensure_ascii=False) + "\n"
        if lock:
            with lock:
                fh.write(line)
                fh.flush()
                records.append(rec)
        else:
            fh.write(line)
            fh.flush()
            records.append(rec)
        ok = "✓" if rec.get("outcome_ok") else "✗"
        tin, cached = rec.get("tok_in") or 0, rec.get("tok_cached") or 0
        print(f"{ok} {rec.get('harness', '?'):<12} {rec.get('task', '?'):<18} "
              f"r{rec.get('rep', '?')} {rec.get('wall_s', '?')}s "
              f"calls={rec.get('tok_calls', '?')} in={tin} cached={cached} "
              f"hit={_hit(tin, cached):.0f}% out={rec.get('tok_out', '?')}", flush=True)

    with open(out_path, "w") as f:
        if args.jobs <= 1:
            for job in jobs:
                emit(one_run(*job), f)
        else:
            from concurrent.futures import ThreadPoolExecutor, as_completed
            import threading
            lock = threading.Lock()
            with ThreadPoolExecutor(max_workers=args.jobs) as pool:
                futs = {pool.submit(one_run, *job): job for job in jobs}
                for fut in as_completed(futs):
                    emit(fut.result(), f, lock)
    summarize(records)
    print(f"\nresults: {out_path}")


def self_test():
    old = parse_graff_usage("[usage] 3 api call(s) · 14000 in (8000 cached) + 200 out tokens\n")
    new = parse_graff_usage(
        "[usage] 3 api call(s) · 14000 in (8000 cached, 4000 cache writes) + 200 out tokens · $0.0123\n")
    ok = (old == {"calls": 3, "in": 14000, "cached": 8000, "writes": 0, "out": 200}
          and new == {"calls": 3, "in": 14000, "cached": 8000, "writes": 4000, "out": 200}
          and parse_graff_usage("no footer") == {})
    print("ok    usage footer (old + writes+$)" if ok else "FAIL usage footer")
    return ok


if __name__ == "__main__":
    raise SystemExit(main() or 0)
