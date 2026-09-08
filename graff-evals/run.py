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
  ./run.py --suite inhouse --harness graff-dev,grok,opencode  # distilled PR fixtures
  ./run.py --suite live --harness graff-dev --reps 3      # gated live PRs (no SPEC.md)
  ./run.py --harness grok --task fix-fib --reps 3        # one task, 3 reps
  ./run.py --interactive                                 # pick + watch live
"""
import argparse, json, os, re, resource, shutil, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed

from list_price import attach as attach_list_price
import report as eval_report

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
TASKS_DIR = os.path.join(ROOT, "tasks")
RESULTS_DIR = os.path.join(ROOT, "results")
SANDBOX_DIR = os.path.join(ROOT, ".sandboxes")

GRAFF_USAGE_RE = re.compile(
    r"\[usage\] (\d+) api call\(s\) · (\d+) in \((\d+) cached(?:, (\d+) cache writes)?\) \+ (\d+) out tokens")


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
    setup_timeout = int(task.get("setup_timeout_s", 60))
    for cmd in task.get("setup", []):
        subprocess.run(["/bin/sh", "-c", cmd], cwd=sandbox, capture_output=True, timeout=setup_timeout)


def _resolve_model(harness, model):
    mapped = (harness.get("model_map") or {}).get(model, model)
    prefix = harness.get("model_prefix")
    if prefix and mapped and "/" not in mapped:
        return f"{prefix}/{mapped}"
    return mapped


def build_cmd(harness, task, model, sandbox=""):
    subst = {"prompt": task["prompt"], "model": _resolve_model(harness, model), "repo": REPO, "sandbox": sandbox}
    cmd = [part.format(**subst) for part in harness["cmd"]]
    if "output-schema" in task.get("requires", []):
        schema = json.dumps(task["schema"], separators=(",", ":"))
        cmd += [part.format(schema=schema, **subst) for part in harness.get("schema_args", [])]
    stdin = harness.get("stdin")
    if stdin is not None:
        stdin = stdin.format(**subst)
    return cmd, stdin


def learn_pin_info(sandbox):
    """Hardlink vs 127M copy: nlink>=2 and same inode as the live exe."""
    pin = os.path.join(sandbox, ".graff", "learn-kit", "graff-pinned")
    if not os.path.exists(pin):
        return None
    st = os.stat(pin)
    info = {"bytes": st.st_size, "nlink": st.st_nlink, "ino": st.st_ino}
    exe = os.path.join(REPO, "zig-out", "bin", "graff")
    if os.path.exists(exe):
        info["same_inode"] = os.stat(exe).st_ino == st.st_ino
    return info


def _parse_opencode_json(stdout):
    """OpenCode `run --format json` NDJSON: text / tool_use / step_finish."""
    answer, calls, tin, tread, twrite, tout, cost = "", 0, 0, 0, 0, 0, 0.0
    for line in stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = ev.get("type")
        part = ev.get("part") or {}
        if kind == "text":
            text = (part.get("text") or ev.get("text") or "").strip()
            if text:
                answer = text
        elif kind == "tool_use":
            calls += 1
        elif kind == "step_finish":
            tok = part.get("tokens") or {}
            cache = tok.get("cache") or {}
            tin += int(tok.get("input") or 0)
            tout += int(tok.get("output") or 0) + int(tok.get("reasoning") or 0)
            tread += int(cache.get("read") or 0)
            twrite += int(cache.get("write") or 0)
            cost += float(part.get("cost") or 0)
            if not calls:
                calls += 1
    usage = {"calls": calls, "in": tin + tread + twrite, "cached": tread,
             "out": tout, "writes": twrite, "cost_usd": round(cost, 6)}
    return answer, usage


def _parse_gemini_json(stdout):
    answer = ""
    usage = {}
    idx = stdout.find("{")
    if idx != -1:
        try:
            data = json.loads(stdout[idx:])
            answer = (data.get("response") or "").strip()
            stats = data.get("stats") or {}
            models = stats.get("models") or {}
            tin, tread, tout, requests = 0, 0, 0, 0
            for mdata in models.values():
                tok = mdata.get("tokens") or {}
                tin += int(tok.get("input") or 0)
                tread += int(tok.get("cached") or 0)
                tout += int(tok.get("candidates") or 0) + int(tok.get("thoughts") or 0)
                api = mdata.get("api") or {}
                requests += int(api.get("totalRequests") or 0)
            tools = stats.get("tools") or {}
            calls = int(tools.get("totalCalls") or 0)
            if not calls and requests > 0:
                calls = requests
            usage = {
                "calls": calls,
                "in": tin + tread,
                "cached": tread,
                "out": tout,
            }
        except json.JSONDecodeError:
            pass
    if not answer:
        answer = stdout.strip()
    return answer, usage


def parse_answer_and_usage(harness, stdout, stderr, sandbox=""):
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
                stu = u.get("server_tool_use") or {}
                tools = {}
                if stu.get("web_search_requests"):
                    tools["web_search"] = stu["web_search_requests"]
                if stu.get("x_search_requests"):
                    tools["x_search"] = stu["x_search_requests"]
                if stu.get("code_execution_requests"):
                    tools["code_execution"] = stu["code_execution_requests"]
                usage = {"calls": ev.get("num_turns"), "in": u.get("input_tokens"),
                         "cached": u.get("cache_read_input_tokens"),
                         "out": u.get("output_tokens"), "api_ms": ev.get("duration_api_ms"),
                         "writes": u.get("cache_creation_input_tokens") or 0}
                if tools:
                    usage["tools"] = tools
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
        answer, usage = _parse_opencode_json(stdout)
    if harness["answer"] == "gemini-json":
        answer, usage = _parse_gemini_json(stdout)
    if harness["answer"] == "muse" or harness.get("usage") == "muse":
        answer = stdout.strip()
        usage = {}
        # Sidecar written by graff-evals/muse.sh: .muse-usage.json + template-hashed model task log
        import glob, json as _json, os as _os, subprocess as _sp
        side = _os.path.join(sandbox, ".muse-usage.json")
        try:
            u = _json.load(open(side))
            usage = {"calls": 1, "in": int(u.get("input_tokens",0))
                     + int(u.get("cached_tokens",0)),
                     "cached": int(u.get("cached_tokens",0)),
                     "out": int(u.get("output_tokens",0) or 0) + int(u.get("reasoning_tokens",0) or 0),
                     "reasoning": int(u.get("reasoning_tokens",0) or 0)}
        except Exception:
            pass
        # Calls = model turns, counted from the stashed exec stream.
        # muse's tracer can't decode exec-stream payloads (schema drift), so count
        # tool results directly: each tool result implies a preceding model turn, so
        # turns = tool_results + 1 (final answer) is a hard LOWER bound — favorable
        # to muse on the calls axis.
        try:
            raw = _os.path.join(sandbox, ".muse-raw.jsonl")
            tools = 0
            with open(raw) as fh:
                for line in fh:
                    try:
                        if _json.loads(line).get("payload_type") == "tool.result":
                            tools += 1
                    except Exception:
                        pass
            if tools:
                usage["calls"] = tools + 1
        except Exception:
            pass
        if not usage.get("calls"):
            usage["calls"] = 1
    if harness.get("usage") == "graff-stderr":
        m = GRAFF_USAGE_RE.search(stderr)
        if m:
            usage = {"calls": int(m.group(1)), "in": int(m.group(2)),
                     "cached": int(m.group(3)), "writes": int(m.group(4) or 0),
                     "out": int(m.group(5))}
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


def one_run(hname, harness, task, model, rep, live=False):
    sandbox = os.path.join(SANDBOX_DIR, f"{hname}-{task['id']}-r{rep}")
    materialize(task, sandbox)
    cmd, stdin_body = build_cmd(harness, task, model, sandbox)
    timeout = task.get("timeout_s", 240)
    t0 = time.monotonic()
    first_out = None
    stdout_parts, stderr_parts = [], []
    rss_peak = 0
    cpu_sample = 0.0
    ru0 = _rusage_children()
    try:
        p = subprocess.Popen(cmd, cwd=sandbox, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, stdin=subprocess.PIPE if stdin_body is not None else None,
                             text=True, start_new_session=True,
                             env=dict(os.environ, **harness.get("env", {})))
        if stdin_body is not None and p.stdin is not None:
            try:
                p.stdin.write(stdin_body)
            except BrokenPipeError:
                pass
            p.stdin.close()
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
        # OpenCode's `run --format json` often closes the pipes while a local
        # server is still up. That is not a task timeout. Give writes a moment
        # to land, then reap the leftover group. A real timeout is pipes still
        # open when the budget ends.
        hit_budget = time.monotonic() - t0 >= timeout
        if p.poll() is None and not hit_budget:
            time.sleep(1.5)
            rss_peak = max(rss_peak, tree_rss_kb(p.pid))
            try:
                os.killpg(p.pid, 15)
            except OSError:
                p.terminate()
            try:
                p.wait(timeout=4)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, 9)
                except OSError:
                    p.kill()
                p.wait(timeout=5)
            timed_out = False
        elif p.poll() is None:
            timed_out = True
            try:
                os.killpg(p.pid, 9)
            except OSError:
                p.kill()
            p.wait(timeout=10)
        else:
            timed_out = False
        rc = p.returncode
        rss_peak = max(rss_peak, tree_rss_kb(p.pid))
    except FileNotFoundError:
        return {"harness": hname, "task": task["id"], "suite": task.get("suite", "core"),
                "rep": rep, "error": f"harness binary not found: {cmd[0]}", "outcome_ok": False}
    ru1 = _rusage_children()
    stdout, stderr = "".join(stdout_parts), "".join(stderr_parts)
    wall = round(time.monotonic() - t0, 2)
    answer, usage = parse_answer_and_usage(harness, stdout, stderr, sandbox)
    with open(os.path.join(sandbox, ".eval-answer.txt"), "w") as f:
        f.write(answer)
    check_env = dict(os.environ, ANSWER_FILE=".eval-answer.txt", TASK_ROOT=ROOT)
    check_timeout = int(task.get("check_timeout_s", 60))
    try:
        check = subprocess.run(["/bin/sh", "-c", task["check"]], cwd=sandbox,
                               capture_output=True, text=True, timeout=check_timeout, env=check_env)
        check_note = None
        if check.returncode != 0 and (check.stderr.strip() or check.stdout.strip()):
            check_note = (check.stderr.strip() or check.stdout.strip())[:200]
        check_ok = check.returncode == 0
    except subprocess.TimeoutExpired:
        check_note = f"check timed out after {check_timeout}s"
        check_ok = False
    rec = {"harness": hname, "task": task["id"], "suite": task.get("suite", "core"),
           "category": task.get("category", ""), "model": model, "rep": rep,
           "wall_s": wall, "first_out_s": first_out, "exit": rc, "timed_out": timed_out,
           "outcome_ok": check_ok, "answer_head": answer[:120],
           "rss_peak_kb": rss_peak, "rss_child_hwm_kb": ru1[2],
           "cpu_user_s": round(max(0.0, ru1[0] - ru0[0]), 3),
           "cpu_sys_s": round(max(0.0, ru1[1] - ru0[1]), 3),
           "cpu_sample_s": round(cpu_sample, 3),
           "sandbox_bytes": dir_bytes(sandbox)}
    rec.update({f"tok_{k}": v for k, v in usage.items()})
    pin = learn_pin_info(sandbox)
    if pin is not None:
        rec["learn_pin"] = pin
    attach_list_price(rec, inclusive=harness.get("usage") != "grok-stream")
    if check_note:
        rec["check_note"] = check_note
    return rec


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
    ap.add_argument("--suite", default="all",
                    help="core, rlm, swe, mcp, inhouse, live, comma-mix, or all (core+rlm+swe; mcp/inhouse/live are opt-in)")
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
                print(eval_report.line(rec), flush=True)

        if jobs == 1:
            for item in work:
                finish(one_run(*item))
        else:
            with ThreadPoolExecutor(max_workers=jobs) as pool:
                futs = [pool.submit(one_run, *item) for item in work]
                for fut in as_completed(futs):
                    finish(fut.result())
    eval_report.summarize(records)
    print(f"\nresults: {out_path}")


if __name__ == "__main__":
    main()
