#!/usr/bin/env python3
"""replay_judge.py — Step 1: the grounded, out-of-process evolution judge.

Runs a candidate system prompt (a DGM genome) against a held-out eval set of
tasks with DETERMINISTIC assertions — a shell command's exit code or a golden
substring in the final report — and emits a pass rate. No LLM grades anything
here; this is the primary fitness gradient the evolving agent cannot charm.

Custody model (mirrors the Step 0 score key):
  - The eval set lives OUTSIDE the editable tree, named by GRAFF_EVAL_SET_FILE.
  - Its sha256 is pinned in GRAFF_EVAL_SET_HASH (set by the trusted
    orchestrator's environment, which a cwd-confined variant cannot edit).
    Hash mismatch → exit 3, fail closed.
  - This script is copied outside the tree too (--pin does both) and invoked
    via GRAFF_REPLAY_JUDGE, so the running judge is not the in-tree copy a
    variant could rewrite. It is dependency-free on purpose: it speaks the
    `harness --json` line protocol directly instead of importing the SDK.

Each eval task runs in a fresh scratch directory (setup_files written first),
so file assertions are hermetic and a variant cannot precompute answers.

Usage:
    replay_judge.py --prompt-file PATH      # judge one genome, JSON to stdout
    replay_judge.py --pin [--eval-set PATH] # install eval set + self outside
                                            # the tree, print the env exports

Exit codes: 0 = eval completed (pass_rate in JSON, possibly 0.0);
            2 = eval set missing/unreadable; 3 = hash pin mismatch;
            4 = bad invocation. Drivers must treat nonzero as FAIL-CLOSED.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading

TASK_TIMEOUT = float(os.environ.get("GRAFF_EVAL_TASK_TIMEOUT", "180"))
HARNESS_BIN = os.environ.get("GRAFF_HARNESS_BIN") or (
    "graff" if shutil.which("graff") else "harness")  # CLI renamed; old name = compat symlink


def eval_set_path():
    return os.environ.get("GRAFF_EVAL_SET_FILE") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "dgm_eval_set.jsonl")


def load_eval_set():
    """Read the eval set, verify the hash pin (fail closed), return
    (tasks, full sha256 hex). The hex is what goes into the score record's
    signed eval_set_hash field."""
    path = eval_set_path()
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        print(f"replay_judge: cannot read eval set {path}: {e}", file=sys.stderr)
        sys.exit(2)
    digest = hashlib.sha256(raw).hexdigest()
    pin = os.environ.get("GRAFF_EVAL_SET_HASH", "")
    if pin and pin != digest:
        print(f"replay_judge: eval set hash mismatch — pinned {pin}, "
              f"got {digest}. Refusing to score (fail closed).", file=sys.stderr)
        sys.exit(3)
    if not pin:
        print("replay_judge: WARNING — GRAFF_EVAL_SET_HASH unset; eval set is "
              "unpinned (run --pin and export the printed vars)", file=sys.stderr)
    tasks = [json.loads(ln) for ln in raw.decode().splitlines() if ln.strip()]
    return tasks, digest


def run_variant(system_prompt, task_text, cwd):
    """One harness conversation under the candidate genome, confined to a
    scratch dir. Returns {"text", "tool_calls", "cost"}: the final assistant
    text ('' on timeout/error), how many tools it called, and the turn cost in
    USD. tool_calls/cost are the raw material for the efficiency gradient that
    discriminates genomes once they all pass (see dgm_loop.judge)."""
    argv = [HARNESS_BIN, "--json", "--yolo", "--system-prompt", system_prompt]
    model = os.environ.get("GRAFF_EVAL_MODEL")
    if model:
        argv += ["--model", model]
    env = dict(os.environ)
    env.setdefault("HARNESS_CLIENT", "replay-judge")
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, bufsize=1,
                            cwd=cwd, env=env)
    timer = threading.Timer(TASK_TIMEOUT, proc.kill)
    timer.start()
    final = ""
    tool_calls = 0
    cost = 0.0
    try:
        proc.stdin.write(json.dumps({"type": "user", "text": task_text}) + "\n")
        proc.stdin.flush()
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(ev, dict):
                continue  # the --json stream can carry bare scalars; skip them
            if ev.get("type") == "tool_call":
                tool_calls += 1
            if ev.get("type") == "turn":
                final = ev.get("text", "")
                cost = float(ev.get("cost_usd", 0.0) or 0.0)
                break
            if ev.get("type") == "error":
                break
    except (BrokenPipeError, OSError):
        pass
    finally:
        timer.cancel()
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    return {"text": final, "tool_calls": tool_calls, "cost": cost}


def check_task(task, report, cwd):
    """Deterministic, out-of-process assertion: exit code or golden substring."""
    chk = task.get("check", {})
    if "cmd" in chk:
        r = subprocess.run(["sh", "-c", chk["cmd"]], cwd=cwd,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return r.returncode == 0, f"exit={r.returncode}"
    if "substring" in chk:
        ok = chk["substring"] in report
        return ok, "substring " + ("found" if ok else "missing")
    return False, "no check defined"


def judge(system_prompt):
    tasks, digest = load_eval_set()
    results = []
    total_tool_calls = 0
    total_cost = 0.0
    for t in tasks:
        scratch = tempfile.mkdtemp(prefix="dgm-eval-")
        try:
            for name, content in (t.get("setup_files") or {}).items():
                with open(os.path.join(scratch, name), "w") as f:
                    f.write(content)
            run = run_variant(system_prompt, t["task"], scratch)
            passed, detail = check_task(t, run["text"], scratch)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        total_tool_calls += run["tool_calls"]
        total_cost += run["cost"]
        results.append({"id": t["id"], "passed": passed, "detail": detail,
                        "tool_calls": run["tool_calls"]})
        print(f"  [{t['id']}] {'PASS' if passed else 'FAIL'} ({detail}, "
              f"{run['tool_calls']} tool call(s))", file=sys.stderr)
    passed = sum(1 for r in results if r["passed"])
    # total_tool_calls / total_cost feed the saturated-top-band efficiency
    # gradient in dgm_loop.judge: once every task passes, economy is the
    # deterministic discriminator (no LLM grades the winner).
    return {"eval_set_hash": digest, "total": len(results), "passed": passed,
            "pass_rate": passed / len(results) if results else 0.0,
            "total_tool_calls": total_tool_calls,
            "total_cost": round(total_cost, 6),
            "results": results}


def pin(eval_src):
    """Install the eval set and this judge outside the editable tree and
    print the exports the orchestrator should set."""
    dest = os.path.join(os.path.expanduser("~"), ".simple-harness", "evals")
    os.makedirs(dest, exist_ok=True)
    eval_dst = os.path.join(dest, os.path.basename(eval_src))
    shutil.copyfile(eval_src, eval_dst)
    judge_dst = os.path.join(dest, "replay_judge.py")
    shutil.copyfile(os.path.abspath(__file__), judge_dst)
    with open(eval_dst, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    print(f"export GRAFF_EVAL_SET_FILE={eval_dst}")
    print(f"export GRAFF_EVAL_SET_HASH={digest}")
    print(f"export GRAFF_REPLAY_JUDGE={judge_dst}")


def main():
    args = sys.argv[1:]
    if args and args[0] == "--pin":
        src = args[args.index("--eval-set") + 1] if "--eval-set" in args \
            else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "dgm_eval_set.jsonl")
        pin(src)
        return
    if len(args) == 2 and args[0] == "--prompt-file":
        with open(args[1]) as f:
            prompt = f.read()
    elif not sys.stdin.isatty():
        prompt = sys.stdin.read()
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(4)
    if not prompt.strip():
        print("replay_judge: empty prompt", file=sys.stderr)
        sys.exit(4)
    print(json.dumps(judge(prompt)))


if __name__ == "__main__":
    main()
