#!/usr/bin/env python3
"""Grade collected DeepSWE patches with datacurve-ai/deep-swe tests (not hidden).

Usage: python3 grade_swe.py [grok-4.6|kimi-k3]
Applies model.patch in a pristine copy of the task image, runs tests/test.sh,
reads /logs/verifier/reward.json. Does not re-run the agent.

Requires a clone of https://github.com/datacurve-ai/deep-swe at /tmp/deep-swe
and the frontier-harness-eval tasks at /tmp/frontier-harness-eval.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = "/tmp/frontier-harness-eval"
DEEP = "/tmp/deep-swe/tasks"
HERE = Path(__file__).resolve().parent
MODEL = sys.argv[1] if len(sys.argv) > 1 else "grok-4.6"
PATCHES = HERE / "patches" / MODEL
OUTP = HERE / f"swe-grades-{MODEL.replace('.', '-')}.jsonl"


def run(cmd, timeout=None):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def image_for(name: str) -> str:
    t = open(f"{ROOT}/tasks/{name}/task.toml").read()
    return re.search(r'^docker_image\s*=\s*"([^"]*)"', t, re.M).group(1)


def grade_one(name: str) -> dict:
    rec = {"task": name, "model": MODEL}
    patch = PATCHES / f"{name}.patch"
    if not patch.exists():
        rec.update(pass_=False, error="no patch")
        return rec
    img = image_for(name)
    cn = f"grade-{MODEL[:8]}-{name[:40]}"
    tests = f"{DEEP}/{name}/tests"
    try:
        run(["docker", "rm", "-f", cn], timeout=60)
        r = run(["docker", "run", "-d", "--name", cn, "--entrypoint", "sleep", img, "86400"], timeout=600)
        if r.returncode != 0:
            rec.update(pass_=False, error="run: " + (r.stderr or "")[-200:])
            return rec
        run(["docker", "exec", "-u", "0", cn, "mkdir", "-p", "/tests", "/logs/artifacts", "/logs/verifier"], timeout=30)
        run(["docker", "cp", str(tests) + "/.", f"{cn}:/tests/"], timeout=120)
        run(["docker", "cp", str(patch), f"{cn}:/logs/artifacts/model.patch"], timeout=120)
        run(["docker", "exec", "-u", "0", cn, "chmod", "+x", "/tests/test.sh"], timeout=30)
        prep = run(["docker", "exec", "-u", "0", "-w", "/app", cn, "python3", "/tests/grader.py", "prepare"], timeout=180)
        rec["prepare_tail"] = ((prep.stdout or "") + (prep.stderr or ""))[-300:]
        v = run(["docker", "exec", "-u", "0", "-w", "/app", cn, "bash", "/tests/test.sh"], timeout=1800)
        rec["verify_rc"] = v.returncode
        rec["verify_tail"] = ((v.stdout or "") + (v.stderr or ""))[-400:]
        out = run(["docker", "exec", "-u", "0", cn, "cat", "/logs/verifier/reward.json"], timeout=30)
        if out.returncode == 0 and (out.stdout or "").strip().startswith("{"):
            reward = json.loads(out.stdout)
            rec["reward"] = reward
            rec["pass_"] = reward.get("reward") == 1
            rec["f2p"] = reward.get("f2p")
            rec["p2p"] = reward.get("p2p")
            rec["partial"] = reward.get("partial")
        else:
            rec["pass_"] = False
            rec["error"] = "no reward.json"
    except subprocess.TimeoutExpired:
        rec.update(pass_=False, error="timeout")
    except Exception as e:
        rec.update(pass_=False, error=repr(e)[:200])
    finally:
        run(["docker", "rm", "-f", cn], timeout=60)
    return rec


def main():
    names = sorted(p.stem for p in PATCHES.glob("*.patch"))
    if not names:
        sys.exit(f"no patches under {PATCHES}")
    print(f"grading {len(names)} patches  [{MODEL}]", flush=True)
    recs = []
    with open(OUTP, "w") as out:
        with ThreadPoolExecutor(max_workers=2) as ex:
            for rec in ex.map(grade_one, names):
                recs.append(rec)
                out.write(json.dumps(rec) + "\n")
                out.flush()
                ok = "PASS" if rec.get("pass_") else "FAIL"
                print(f"{ok} {rec['task']:42} f2p={rec.get('f2p')} p2p={rec.get('p2p')} {rec.get('error') or ''}", flush=True)
    print(f"\ngraded {sum(1 for r in recs if r.get('pass_'))}/{len(recs)} pass", flush=True)


if __name__ == "__main__":
    main()
