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

GRAFF_USAGE_RE = re.compile(
    r"\[usage\] (\d+) api call\(s\) · (\d+) in \((\d+) cached\) \+ (\d+) out tokens")


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
        m = GRAFF_USAGE_RE.search(stderr)
        if m:
            usage = {"calls": int(m.group(1)), "in": int(m.group(2)),
                     "cached": int(m.group(3)), "out": int(m.group(4))}
    return answer, usage


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


def summarize(records):
    by = {}
    for r in records:
        b = by.setdefault(r["harness"], {"n": 0, "ok": 0, "wall": 0.0, "tin": 0, "tout": 0})
        b["n"] += 1
        b["ok"] += bool(r.get("outcome_ok"))
        b["wall"] += r.get("wall_s", 0) or 0
        b["tin"] += r.get("tok_in") or 0
        b["tout"] += r.get("tok_out") or 0
    print(f"\n{'harness':<12} {'pass':>7} {'wall':>8} {'in_tok':>9} {'out_tok':>8}")
    for h, b in by.items():
        print(f"{h:<12} {b['ok']}/{b['n']:<5} {b['wall']:>7.1f}s {b['tin']:>9} {b['tout']:>8}")


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
    ap.add_argument("--interactive", action="store_true", help="pick a task+harness, watch it live")
    args = ap.parse_args()

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
    with open(out_path, "w") as f:
        for hname in args.harness.split(","):
            harness = harnesses[hname]
            model = args.model or harness.get("default_model", "")
            for task in picked.values():
                missing = [c for c in task.get("requires", []) if c not in harness.get("capabilities", [])]
                if missing:
                    print(f"skip {task['id']} on {hname}: needs {missing}", flush=True)
                    continue
                for rep in range(1, args.reps + 1):
                    rec = one_run(hname, harness, task, model, rep)
                    records.append(rec)
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                    f.flush()
                    ok = "✓" if rec.get("outcome_ok") else "✗"
                    print(f"{ok} {hname:<12} {task['id']:<18} r{rep} {rec.get('wall_s', '?')}s "
                          f"in={rec.get('tok_in', '?')} out={rec.get('tok_out', '?')}", flush=True)
    summarize(records)
    print(f"\nresults: {out_path}")


if __name__ == "__main__":
    main()
