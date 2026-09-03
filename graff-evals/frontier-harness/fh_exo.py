#!/usr/bin/env python3
"""TB-21 runner for exo on grok-4.6 (same images + tests as fh_run.py)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
from fh_run import (  # noqa: E402
    ROOT,
    TB,
    attach_metrics,
    docker_cp,
    run,
    suite_maxima,
    tb_tasks,
    toml_env,
    workdir,
)

EXO = os.environ.get("EXO_BIN", os.path.expanduser("~/exo/target/release/exo"))
MODEL = os.environ.get("FH_EXO_MODEL", "grok-46-oauth")
OUT_DEFAULT = Path(__file__).resolve().parent / "exo-results.jsonl"


def exo(args, timeout=None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    oauth = Path("/tmp/fh-xai-oauth.env")
    if oauth.exists():
        for line in oauth.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    return subprocess.run([EXO, *args], capture_output=True, text=True, timeout=timeout, env=env, cwd=os.path.expanduser("~/exo"))


def parse_calls(events: list) -> int:
    ids = set()
    tools = 0
    for e in events:
        data = e.get("data") or {}
        rid = data.get("response_id")
        if rid:
            ids.add(rid)
        if data.get("type") == "tool_requested":
            tools += 1
    return max(len(ids), tools + 1 if tools else 0)


def verify_in(cn: str, name: str, wd: str, env: dict) -> tuple[bool, str]:
    run(["docker", "exec", "-u", "0", cn, "mkdir", "-p", "/tests"], timeout=30)
    docker_cp(f"{TB}/{name}/tests/.", f"{cn}:/tests/")
    run(
        ["docker", "exec", "-u", "0", cn, "sh", "-c",
         "export DEBIAN_FRONTEND=noninteractive; "
         "apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-pytest python3-venv ca-certificates; "
         "python3 -m pip install -q --break-system-packages pytest GitPython || true"],
        timeout=300,
    )
    v = run(
        ["docker", "exec", "-u", "0", "-w", wd,
         *[x for kv in env.items() for x in ("-e", f"{kv[0]}={kv[1]}")],
         cn, "sh", "-c", "python3 -m pytest /tests -q --tb=line; rc=$?; echo VEXIT:$rc"],
        timeout=900,
    )
    blob = (v.stdout or "") + (v.stderr or "")
    return "VEXIT:0" in blob, blob[-240:].strip()


def find_exo_container(image: str) -> str | None:
    r = run(["docker", "ps", "--filter", f"ancestor={image}", "--format", "{{.ID}} {{.Names}}"], timeout=30)
    for line in (r.stdout or "").splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith("exo-"):
            return parts[0]
    return None


def run_task(name: str) -> dict:
    toml = open(f"{ROOT}/tasks/{name}/task.toml").read()
    image = re.search(r'^docker_image\s*=\s*"([^"]*)"', toml, re.M).group(1)
    agent_timeout = float(re.search(r"\[agent\]\s*.*?timeout_sec\s*=\s*([\d.]+)", toml, re.S).group(1))
    env = toml_env(toml, "environment")
    instruction = open(f"{ROOT}/tasks/{name}/instruction.md").read()
    slug = f"fhx-{name[:20]}-{os.getpid()}"
    rec = {"task": name, "harness": "exo", "model": "grok-4.6", "image": image}
    t0 = time.time()
    try:
        c = exo(["agent", "create", name, "--slug", slug, "--model", MODEL,
                 "--sandbox-image", image, "--provider", "docker",
                 "--networking", "enabled", "--sandbox-scope", "conversation"], timeout=60)
        if c.returncode != 0:
            rec.update(pass_=False, error="agent-create: " + (c.stderr or c.stdout)[-200:])
            return rec
        exo(["conversation", "create", slug, "run", "--slug", "run"], timeout=30)
        s = exo(["conversation", "send", slug, "run", instruction], timeout=agent_timeout + 120)
        rec["wall_s"] = round(time.time() - t0, 1)
        rec["agent_exit"] = s.returncode
        rec["agent_tail"] = ((s.stdout or "") + (s.stderr or ""))[-500:]
        ev = exo(["conversation", "events", slug, "run", "--limit", "500"], timeout=30)
        try:
            events = json.loads(ev.stdout or "{}").get("events") or []
        except json.JSONDecodeError:
            events = []
        rec["calls"] = parse_calls(events)
        cn = find_exo_container(image)
        if not cn:
            rec.update(pass_=False, error="no exo container")
            return rec
        # certs for later tool calls aren't needed post-hoc; verify only
        wd = workdir(cn)
        ok, tail = verify_in(cn, name, wd, env)
        rec["pass_"] = ok
        rec["verify_tail"] = tail
        attach_metrics(rec)
    except subprocess.TimeoutExpired:
        rec["pass_"] = False
        rec["error"] = f"timeout {agent_timeout}s"
        rec["wall_s"] = round(time.time() - t0, 1)
    except Exception as e:
        rec["pass_"] = False
        rec["error"] = repr(e)[:240]
        rec["wall_s"] = round(time.time() - t0, 1)
    finally:
        exo(["agent", "delete", slug], timeout=60)
        run(["docker", "ps", "-q", "--filter", f"name=exo-"], timeout=30)
    return rec


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks", default="")
    ap.add_argument("-j", type=int, default=1)
    ap.add_argument("--out", default=str(OUT_DEFAULT))
    ap.add_argument("--fresh", action="store_true")
    a = ap.parse_args()
    if not os.path.isfile(EXO):
        sys.exit(f"missing exo at {EXO}")
    tasks = a.tasks.split(",") if a.tasks else tb_tasks()
    done = set()
    if os.path.exists(a.out) and not a.fresh:
        for line in open(a.out):
            try:
                done.add(json.loads(line)["task"])
            except Exception:
                pass
    elif a.fresh and os.path.exists(a.out):
        os.remove(a.out)
    todo = [t for t in tasks if t not in done]
    print(f"{len(todo)} exo tasks ({len(done)} done) → {a.out}", flush=True)
    with open(a.out, "a") as out:
        with ThreadPoolExecutor(max_workers=max(1, a.j)) as ex:
            for rec in ex.map(run_task, todo):
                out.write(json.dumps(rec) + "\n")
                out.flush()
                print(
                    f"{'PASS' if rec.get('pass_') else 'FAIL'} {rec['task']:32} "
                    f"wall={rec.get('wall_s')}s calls={rec.get('calls')} "
                    f"{rec.get('error') or rec.get('verify_tail', '')}",
                    flush=True,
                )
    recs = [json.loads(l) for l in open(a.out) if l.strip()]
    mx = suite_maxima(recs)
    print(f"\nmaxima  pass={mx['pass']}/{mx['n']}  calls_max={mx['calls_max']}  wall_max={mx['wall_max']}s", flush=True)
    Path(a.out).with_suffix(".maxima.json").write_text(json.dumps(mx, indent=2) + "\n")


if __name__ == "__main__":
    main()
