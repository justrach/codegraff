#!/usr/bin/env python3
"""graff-evals: a self-contained eval environment for coding harnesses.

Every task is a JSON file under tasks/ that declares its fixture files, the
prompt, and a deterministic shell check. The runner materializes a sandbox,
drives any configured harness (harnesses.json) with any model, captures wall
time / first-output latency / token usage / peak RSS / CPU, verifies the
outcome, and writes JSONL results plus a summary table.

  ./run.py --harness graff --model grok-4.6              # full suite (core + rlm + swe)
  ./run.py --suite rlm --harness graff-dev-old,graff-dev # scatter-gather A/B
  ./run.py --suite swe --harness graff-dev-old,graff-dev -j 12  # DeepSWE-shaped A/B, parallel
  ./run.py --suite swe --harness graff-dev,pi-xai --model grok-4.6 -j 6  # same SuperGrok seat
  ./run.py --suite mcp --harness graff-dev-old-nolean,graff-dev-rlm-struct,graff-dev-nolean
  ./run.py --harness grok --task fix-fib --reps 3        # one task, 3 reps
  ./run.py --interactive                                 # pick + watch live
"""
import argparse, json, os, re, resource, shutil, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
TASKS_DIR = os.path.join(ROOT, "tasks")
RESULTS_DIR = os.path.join(ROOT, "results")
SANDBOX_DIR = os.path.join(ROOT, ".sandboxes")

GRAFF_USAGE_RE = re.compile(
    r"\[usage\] (\d+) api call\(s\) · (\d+) in \((\d+) cached(?:, \d+ cache writes)?\) \+ (\d+) out tokens")


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
    files_dir = task.get("files_dir")
    if files_dir:
        src = files_dir if os.path.isabs(files_dir) else os.path.join(ROOT, files_dir)
        if os.path.isdir(src):
            for dirpath, dirnames, filenames in os.walk(src):
                dirnames[:] = [d for d in dirnames if d != "__pycache__"]
                rel = os.path.relpath(dirpath, src)
                dest_dir = sandbox if rel == "." else os.path.join(sandbox, rel)
                os.makedirs(dest_dir, exist_ok=True)
                for name in filenames:
                    if name.endswith(".pyc") or name == ".DS_Store":
                        continue
                    shutil.copy2(os.path.join(dirpath, name), os.path.join(dest_dir, name))
    for rel, content in task.get("files", {}).items():
        path = os.path.join(sandbox, rel)
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
    for cmd in task.get("setup", []):
        subprocess.run(["/bin/sh", "-c", cmd], cwd=sandbox, capture_output=True, timeout=60)


def build_cmd(harness, task, model, sandbox="."):
    subst = {"prompt": task["prompt"], "model": model, "repo": REPO, "cwd": sandbox}
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
    if harness["answer"] == "opencode-json":
        answer, calls, tin, tout, cached = "", 0, 0, 0, 0
        for line in stdout.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            typ = ev.get("type")
            part = ev.get("part") or {}
            if typ == "text":
                t = part.get("text") or ev.get("text") or ""
                if t:
                    answer = t
            if typ == "step_finish":
                calls += 1
                tok = part.get("tokens") or ev.get("tokens") or {}
                tin += tok.get("input") or tok.get("inputTokens") or 0
                tout += tok.get("output") or tok.get("outputTokens") or 0
                cache = tok.get("cache")
                if isinstance(cache, dict):
                    cached += cache.get("read") or 0
                else:
                    cached += tok.get("cacheRead") or tok.get("cache_read") or 0
        usage = {"calls": calls, "in": tin, "cached": cached, "out": tout}
    if harness.get("usage") == "graff-stderr":
        m = GRAFF_USAGE_RE.search(stderr)
        if m:
            usage = {"calls": int(m.group(1)), "in": int(m.group(2)),
                     "cached": int(m.group(3)), "out": int(m.group(4))}
        cost_m = re.search(r"\$([0-9.]+)", stderr)
        if cost_m:
            usage["cost_usd"] = float(cost_m.group(1))
        sub_m = re.search(r"(\d+) subscription call\(s\)", stderr)
        if sub_m:
            usage["sub_calls"] = int(sub_m.group(1))
    return answer, usage


def _status_kb(pid, key):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith(key):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return 0
    return 0


def _children(pid):
    try:
        with open(f"/proc/{pid}/task/{pid}/children") as f:
            return [int(x) for x in f.read().split()]
    except (OSError, ValueError):
        return []


def _walk_pids(pid):
    seen, stack = set(), [pid]
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        yield p
        stack.extend(_children(p))


def tree_rss_kb(pid):
    return sum(_status_kb(p, "VmRSS:") for p in _walk_pids(pid))


def tree_cpu_s(pid):
    ticks = os.sysconf("SC_CLK_TCK") or 100
    total = 0.0
    for p in _walk_pids(pid):
        try:
            with open(f"/proc/{p}/stat") as f:
                st = f.read()
            fields = st[st.rfind(")") + 2:].split()
            total += (int(fields[11]) + int(fields[12])) / ticks
        except (OSError, ValueError, IndexError):
            pass
    return total


def dir_bytes(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def _rusage_children():
    u = resource.getrusage(resource.RUSAGE_CHILDREN)
    return u.ru_utime, u.ru_stime, u.ru_maxrss


def _fmt_mib(kb):
    if not kb:
        return "—"
    return f"{kb / 1024:.1f}M"


def one_run(hname, harness, task, model, rep, live=False):
    sandbox = os.path.join(SANDBOX_DIR, f"{hname}-{task['id']}-r{rep}")
    materialize(task, sandbox)
    cmd = build_cmd(harness, task, model, sandbox)
    timeout = task.get("timeout_s", 240)
    t0 = time.monotonic()
    first_out = None
    stdout_parts, stderr_parts = [], []
    rss_peak = 0
    cpu_sample = 0.0
    ru0 = _rusage_children()
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
            rss_peak = max(rss_peak, tree_rss_kb(p.pid))
            cpu_sample = max(cpu_sample, tree_cpu_s(p.pid))
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
        rss_peak = max(rss_peak, tree_rss_kb(p.pid))
    except FileNotFoundError:
        return {"harness": hname, "task": task["id"], "suite": task.get("suite", "core"),
                "rep": rep, "error": f"harness binary not found: {cmd[0]}", "outcome_ok": False}
    ru1 = _rusage_children()
    stdout, stderr = "".join(stdout_parts), "".join(stderr_parts)
    wall = round(time.monotonic() - t0, 2)
    answer, usage = parse_answer_and_usage(harness, stdout, stderr)
    with open(os.path.join(sandbox, ".eval-answer.txt"), "w") as f:
        f.write(answer)
    check_env = dict(os.environ, ANSWER_FILE=".eval-answer.txt", TASK_ROOT=ROOT)
    check = subprocess.run(["/bin/sh", "-c", task["check"]], cwd=sandbox,
                           capture_output=True, text=True, timeout=60, env=check_env)
    rec = {"harness": hname, "task": task["id"], "suite": task.get("suite", "core"),
           "category": task.get("category", ""), "model": model, "rep": rep,
           "wall_s": wall, "first_out_s": first_out, "exit": rc, "timed_out": timed_out,
           "outcome_ok": check.returncode == 0, "answer_head": answer[:120],
           "rss_peak_kb": rss_peak, "rss_child_hwm_kb": ru1[2],
           "cpu_user_s": round(max(0.0, ru1[0] - ru0[0]), 3),
           "cpu_sys_s": round(max(0.0, ru1[1] - ru0[1]), 3),
           "cpu_sample_s": round(cpu_sample, 3),
           "sandbox_bytes": dir_bytes(sandbox)}
    rec.update({f"tok_{k}": v for k, v in usage.items()})
    if check.returncode != 0 and (check.stderr.strip() or check.stdout.strip()):
        rec["check_note"] = (check.stderr.strip() or check.stdout.strip())[:200]
    if not rec.get("outcome_ok") and stderr.strip():
        rec["stderr_tail"] = stderr.strip()[-400:]
    return rec


def _bucket(records):
    by = {}
    for r in records:
        b = by.setdefault(r["harness"], {
            "n": 0, "ok": 0, "wall": 0.0, "first": 0.0, "first_n": 0,
            "tin": 0, "tout": 0, "calls": 0, "rss": 0, "cpu": 0.0,
            "usd": 0.0, "usd_n": 0,
        })
        b["n"] += 1
        b["ok"] += bool(r.get("outcome_ok"))
        b["wall"] += r.get("wall_s", 0) or 0
        if r.get("first_out_s") is not None:
            b["first"] += r["first_out_s"]
            b["first_n"] += 1
        b["tin"] += r.get("tok_in") or 0
        b["tout"] += r.get("tok_out") or 0
        b["calls"] += r.get("tok_calls") or 0
        if r.get("tok_cost_usd") is not None:
            b["usd"] += r["tok_cost_usd"]
            b["usd_n"] += 1
        b["rss"] = max(b["rss"], r.get("rss_peak_kb") or 0)
        cpu = r.get("cpu_sample_s")
        if not cpu:
            cpu = (r.get("cpu_user_s") or 0) + (r.get("cpu_sys_s") or 0)
        b["cpu"] += cpu
    return by


def _print_table(title, by):
    print(f"\n{title}")
    print(f"{'harness':<16} {'pass':>7} {'wall':>8} {'first':>7} {'rss':>8} {'cpu':>7} {'in_tok':>9} {'out_tok':>8} {'calls':>6} {'usd':>8}")
    for h, b in by.items():
        first = (b["first"] / b["first_n"]) if b["first_n"] else 0.0
        usd = f"${b['usd']:.4f}" if b["usd_n"] else "—"
        print(f"{h:<16} {b['ok']}/{b['n']:<5} {b['wall']:>7.1f}s {first:>6.1f}s "
              f"{_fmt_mib(b['rss']):>8} {b['cpu']:>6.1f}s {b['tin']:>9} {b['tout']:>8} {b['calls']:>6} {usd:>8}")


def summarize(records):
    _print_table("all", _bucket(records))
    suites = sorted({r.get("suite") or "core" for r in records})
    if len(suites) > 1:
        for s in suites:
            _print_table(f"suite {s}", _bucket([r for r in records if (r.get("suite") or "core") == s]))


def _line(rec):
    cpu = rec.get("cpu_sample_s") or ((rec.get("cpu_user_s") or 0) + (rec.get("cpu_sys_s") or 0))
    ok = "✓" if rec.get("outcome_ok") else "✗"
    return (f"{ok} {rec.get('harness', '?'):<16} {rec.get('task', '?'):<18} "
            f"r{rec.get('rep', '?')} {rec.get('wall_s', '?')}s "
            f"first={rec.get('first_out_s', '—')}s rss={_fmt_mib(rec.get('rss_peak_kb'))} "
            f"cpu={cpu:.1f}s in={rec.get('tok_in', '?')} out={rec.get('tok_out', '?')}")


def interactive(tasks, harnesses):
    tlist = list(tasks.values())
    print("tasks:")
    for i, t in enumerate(tlist):
        print(f"  [{i}] {t['id']:<18} {t.get('suite', 'core'):<5} {t.get('category', '')}")
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
    ap.add_argument("--suite", default="all", help="core, rlm, swe, mcp, comma-mix, or all (core+rlm+swe; mcp is opt-in)")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--jobs", "-j", type=int, default=1,
                    help="parallel task×harness runs (default 1; each has its own sandbox)")
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
    suites = {s.strip() for s in args.suite.split(",") if s.strip()}
    if "all" in suites:
        suites.update({"core", "rlm", "swe"})
        suites.discard("all")
    picked = {}
    for tid, t in tasks.items():
        if args.task and tid not in args.task:
            continue
        suite = t.get("suite", "core")
        if suite not in suites:
            continue
        picked[tid] = t
    work = []
    for hname in args.harness.split(","):
        harness = harnesses[hname]
        model = args.model or harness.get("default_model", "")
        for task in picked.values():
            missing = [c for c in task.get("requires", []) if c not in harness.get("capabilities", [])]
            if missing:
                print(f"skip {task['id']} on {hname}: needs {missing}", flush=True)
                continue
            for rep in range(1, args.reps + 1):
                work.append((hname, harness, task, model, rep))
    jobs = max(1, args.jobs)
    print(f"{len(work)} runs · {jobs} worker{'s' if jobs != 1 else ''} · {out_path}", flush=True)
    records = []
    lock = threading.Lock()
    with open(out_path, "w") as f:
        def finish(rec):
            with lock:
                records.append(rec)
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                f.flush()
                print(_line(rec), flush=True)

        if jobs == 1:
            for item in work:
                finish(one_run(*item))
        else:
            with ThreadPoolExecutor(max_workers=jobs) as pool:
                futs = [pool.submit(one_run, *item) for item in work]
                for fut in as_completed(futs):
                    finish(fut.result())
    summarize(records)
    print(f"\nresults: {out_path}")


if __name__ == "__main__":
    main()
