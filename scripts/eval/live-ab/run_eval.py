#!/usr/bin/env python3
"""Live A/B eval driver: each task x each binary x N runs, fresh fixture per run.

Writes one JSON record per run into runs/<task>/<binary>/<n>/meta.json and keeps
the raw stdout/stderr next to it so every number in RESULTS.md is regenerable.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
FIX = ROOT / "fixtures"
RUNS = ROOT / "runs"

# Each arm's binary comes from the environment so this harness is not welded to
# one machine's worktrees. Resolution is lazy: running a single arm needs only
# that arm's variable set.
BIN_ENV = {"before": "GRAFF_EVAL_BEFORE", "after": "GRAFF_EVAL_AFTER"}


def binary_path(binary):
    env_name = BIN_ENV[binary]
    path = os.environ.get(env_name)
    if not path:
        sys.exit(
            "%s is unset. Point it at the %r arm's graff binary, e.g.\n"
            "  %s=/path/to/worktree/zig-out/bin/graff"
            % (env_name, binary, env_name)
        )
    if not os.path.isfile(path):
        sys.exit("%s=%s is not a file" % (env_name, path))
    return path

# Both arms must run the SAME model or the comparison is meaningless.
MODEL = os.environ.get("GRAFF_EVAL_MODEL", "gpt-5.6-sol")
TIMEOUT = int(os.environ.get("GRAFF_EVAL_TIMEOUT", "300"))  # hard kill, safety bound

COMMON = ["--model", MODEL, "--no-telemetry", "--new"]

TASKS = {
    "f1_bugfix": {
        "fixture": "f1-bugfix",
        "prompt": "run the tests, find the bug, fix it, make the tests pass, then reply DONE",
        "args": ["--yolo", "-p", "--max-model-calls", "30"],
    },
    "f2_biglog": {
        "fixture": "f2-biglog",
        "prompt": "cat build.log, then tell me the request id of the single FAILED entry and what failed",
        "args": ["--yolo", "-p", "--max-model-calls", "30"],
    },
    # F2b forces the single oversized tool output the natural phrasing avoids:
    # the model reached for read_file/grep in F2a, so the send-time cap (and
    # therefore #409's spill) never fired.
    "f2b_forcedcat": {
        "fixture": "f2-biglog",
        "prompt": (
            "Using the bash tool, run exactly `cat build.log` as your first step. "
            "Do NOT use read_file, grep, awk, sed, head or tail to narrow it down first "
            "-- I want the whole file through bash. Then, from that output, tell me the "
            "request id of the single FAILED entry and what failed."
        ),
        "args": ["--yolo", "-p", "--max-model-calls", "30"],
    },
    "f3_goalloop": {
        "fixture": "f3-goalloop",
        "prompt": (
            "slugify() in slugify.py is a stub. It must lowercase the title and join its "
            "words with hyphens. Edit slugify.py and use the eval tool to check your work; "
            "keep iterating until the checker reports score 100, then reply DONE."
        ),
        "args": ["--yolo", "-p", "--max-model-calls", "30",
                 "--eval", "python3 check.py", "--until", "100"],
    },
    # F3b targets #412's actual precondition: skipReverify() only fires when the
    # LAST eval FAILED and the workspace fingerprint is unchanged. F3 never hit
    # that (every eval followed an edit), so the fast path had no opportunity.
    # Telling the model to re-confirm a RED verdict manufactures exactly that.
    "f3b_reverify": {
        "fixture": "f3-goalloop",
        "prompt": (
            "slugify() in slugify.py is a stub. It must lowercase the title and join its "
            "words with hyphens. Use the eval tool to check your work. IMPORTANT: the checker "
            "has been flaky on this machine, so whenever it reports a failing score, run the "
            "eval tool a second time immediately -- without editing anything in between -- to "
            "confirm the failure reproduces. Only then change code. Keep iterating until the "
            "checker reports score 100, then reply DONE."
        ),
        "args": ["--yolo", "-p", "--max-model-calls", "30",
                 "--eval", "python3 check.py", "--until", "100"],
    },
    "f4_embedder": {
        "fixture": "f4-embedder",
        "prompt": (
            "Three boxes are labeled APPLES, ORANGES, and MIXED. Every label is wrong. "
            "You draw one fruit from the box labeled MIXED and it is an apple. "
            "What is the correct label for the box labeled ORANGES? Reply with exactly one word."
        ),
        "args": ["--no-local-tools", "-p"],
    },
}

USAGE_RE = re.compile(
    r"\[usage\]\s+(\d+)\s+api call\(s\)\s+.\s+(\d+)\s+in\s+\((\d+)\s+cached[^)]*\)\s*\+\s*(\d+)\s+out tokens"
)


def parse_usage(stderr):
    """Last [usage] footer wins (a run prints one per turn)."""
    hits = USAGE_RE.findall(stderr)
    if not hits:
        return None
    a, i, c, o = hits[-1]
    return {
        "api_calls": int(a),
        "input_tokens": int(i),
        "cached_tokens": int(c),
        "output_tokens": int(o),
        "usage_footers": len(hits),
    }


# stderr transcript tool lines look like:  "  [main](gear) bash {"command":...}"
TOOL_RE = re.compile(r"^\s*\[[^\]]+\]\s+⚙\s+(\S+)", re.M)

# bookkeeping calls that are not task work; counted but reported separately
NON_WORK = {"todo_write", "attempt_completion"}


def count_tools(stderr):
    names = TOOL_RE.findall(stderr)
    tally = {}
    for n in names:
        tally[n] = tally.get(n, 0) + 1
    work = sum(v for k, v in tally.items() if k not in NON_WORK)
    return len(names), tally, work


def success_f1(d, out, err):
    r = subprocess.run([sys.executable, "-m", "pytest", "-q"], cwd=d,
                       capture_output=True, text=True, timeout=120)
    ok = r.returncode == 0
    return ok, {"pytest_rc": r.returncode, "pytest_tail": r.stdout.strip()[-200:]}


def success_f2(d, out, err):
    blob = out.lower()
    has_id = "req-8c41de07" in blob
    has_why = ("undefined_symbol" in blob or "undefined symbol" in blob
               or "_zg_render_frame" in blob)
    return (has_id and has_why), {"named_id": has_id, "named_reason": has_why}


def success_f3(d, out, err):
    r = subprocess.run([sys.executable, "check.py"], cwd=d,
                       capture_output=True, text=True, timeout=120)
    m = re.search(r"score:\s*(\d+)", r.stdout)
    score = int(m.group(1)) if m else -1
    return score == 100, {"final_score": score}


def success_f4(d, out, err):
    return ("mixed" in out.lower()), {"answer": out.strip()[:120]}


CHECK = {"f1_bugfix": success_f1, "f2_biglog": success_f2,
         "f2b_forcedcat": success_f2,
         "f3_goalloop": success_f3, "f3b_reverify": success_f3,
         "f4_embedder": success_f4}

# #412 fired iff the eval tool handed back the no-progress steer instead of running
SKIP_NEEDLE = "the workspace has not changed since the last failed verification"


def reverify_skips(dest, err):
    n = err.count(SKIP_NEEDLE)
    for p in (dest / ".graff").rglob("*.jsonl") if (dest / ".graff").exists() else []:
        try:
            n += p.read_text(errors="replace").count(SKIP_NEEDLE)
        except Exception:
            pass
    sess = dest / ".graff" / "sessions"
    if sess.exists():
        for p in sess.rglob("*.json"):
            try:
                n += p.read_text(errors="replace").count(SKIP_NEEDLE)
            except Exception:
                pass
    return n


def one_run(task, binary, idx):
    spec = TASKS[task]
    dest = RUNS / task / binary / str(idx)
    if dest.exists():
        shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(FIX / spec["fixture"], dest)

    # Measurement invariant, enforced here rather than shipped as a dotfile in
    # every fixture: companion MCP servers stay off, so tool schemas cannot
    # drift between the two arms and silently move the input-token number.
    # (The repo .gitignore excludes .harness/, so a committed copy would not
    # survive a clone anyway.)
    harness_dir = dest / ".harness"
    harness_dir.mkdir(exist_ok=True)
    (harness_dir / "settings.json").write_text(
        json.dumps({"skills": {"codedbpro": False}})
    )

    cmd = [binary_path(binary)] + COMMON + spec["args"] + [spec["prompt"]]
    env = dict(os.environ)
    env["GRAFF_NO_TELEMETRY"] = "1"

    t0 = time.time()
    timed_out = False
    try:
        p = subprocess.run(cmd, cwd=dest, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
        rc, out, err = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        timed_out = True
        rc = -1
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        err = e.stderr.decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
    wall = time.time() - t0

    (dest / "_stdout.txt").write_text(out)
    (dest / "_stderr.txt").write_text(err)

    usage = parse_usage(err)
    ntools, tally, nwork = count_tools(err)
    try:
        ok, detail = CHECK[task](dest, out, err)
    except Exception as ex:
        ok, detail = False, {"check_error": repr(ex)}

    # #409 evidence: did a spill artifact get written?
    spill_dir = dest / ".graff"
    artifacts = []
    if spill_dir.exists():
        artifacts = [str(p.relative_to(dest)) for p in spill_dir.rglob("*") if p.is_file()]

    rec = {
        "task": task, "binary": binary, "run": idx,
        "cmd": cmd, "rc": rc, "timed_out": timed_out,
        "wall_s": round(wall, 2),
        "usage": usage,
        "tool_calls": ntools, "tool_tally": tally, "work_tool_calls": nwork,
        "mcp_leaked": "[mcp:" in err,
        "success": ok, "success_detail": detail,
        "spill_marker_in_stderr": "spill" in err.lower(),
        "reverify_skips": reverify_skips(dest, err),
        "graff_artifacts": artifacts[:40],
        "stdout_len": len(out),
    }
    (dest / "meta.json").write_text(json.dumps(rec, indent=2))
    return rec


def main():
    tasks = sys.argv[1].split(",") if len(sys.argv) > 1 else list(TASKS)
    binaries = sys.argv[2].split(",") if len(sys.argv) > 2 else ["before", "after"]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    start = int(sys.argv[4]) if len(sys.argv) > 4 else 1

    RUNS.mkdir(exist_ok=True)
    allrecs = []
    for task in tasks:
        for i in range(start, start + n):
            for binary in binaries:
                r = one_run(task, binary, i)
                u = r["usage"] or {}
                print("%-12s %-6s #%d  ok=%-5s calls=%3s in=%7s cached=%7s out=%6s tools=%2d %6.1fs%s" % (
                    task, binary, i, str(r["success"]),
                    u.get("api_calls", "?"), u.get("input_tokens", "?"),
                    u.get("cached_tokens", "?"), u.get("output_tokens", "?"),
                    r["tool_calls"], r["wall_s"],
                    "  TIMEOUT" if r["timed_out"] else ""))
                sys.stdout.flush()
                allrecs.append(r)

    res_path = ROOT / "results.json"
    existing = []
    if res_path.exists():
        existing = json.loads(res_path.read_text())

    def key(r):
        return (r["task"], r["binary"], r["run"])

    merged = {key(r): r for r in existing}
    for r in allrecs:
        merged[key(r)] = r
    res_path.write_text(json.dumps(sorted(merged.values(), key=key), indent=2))
    print("\nwrote %s (%d records)" % (res_path, len(merged)))


if __name__ == "__main__":
    main()
