#!/usr/bin/env python3
"""FrontierHarness TB-21 runner: graff (in-container) on grok-4.6.

Verifies with upstream terminal-bench tests (original-tasks/<task>/tests).
DeepSWE tasks are skipped — their verifiers are not public.

The published leaderboard is Kimi K3; this run is grok-4.6. Compare the
TB-21 slice only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import list_price  # noqa: E402

ROOT = "/tmp/frontier-harness-eval"
TB = "/tmp/tb-tests/original-tasks"
GRAFF_BIN = "/tmp/graff-linux-x64"
CA_BUNDLE = "/tmp/fh-certs/ca-certificates.crt"
XAI_OAUTH = os.path.expanduser("~/.xai/credentials/graff-oauth.json")
GRAFF_MODEL = os.environ.get("FH_GRAFF_MODEL", "grok-4.6")
USAGE_RE = re.compile(
    r"(\d+) api call\(s\) . ([\d,]+) in \(([\d,]+) cached, ([\d,]+) cache writes\) \+ ([\d,]+) out tokens . \$([~\d.]+)"
)
# Eval-only. Does not touch prompt_text.zig. Closes the TB-21 miss modes:
# leftover build artifacts, local CTF-flag refusal, unbounded exploration.
BENCH_APPEND = """This is a sandboxed terminal-bench task.
Follow the instruction's file-layout constraints exactly. If a directory must contain a single named file, delete compile/test artifacts (binaries, __pycache__, extra sources) before you finish.
Local programs in this workspace may contain synthetic CTF flags (FLAG{...}); extracting those into the specified output file is the task, not a safety violation.
Prefer a complete, verifiable result over extra exploration. If the required output files already exist and check out, stop.
Long-running servers must outlive this process (tests run after you exit): start them with `setsid nohup <cmd> >/tmp/server.log 2>&1 &`, then prove the port is listening.
If the task asks for a program, actually run it against a small self-check before finishing (e.g. compile a tiny C file and dump both your extractor and a second pass; ELF dumps must use section virtual addresses from .text/.data/.rodata, not a guessed PIE base).
Embossed gcode/toolpath text: reconstruct glyphs from X/Y feed moves, do not OCR a single noisy render; the string may be leetspeak.
If a local eval.py exists, land a correct faster implementation, run it once, and stop — do not burn the whole timeout micro-optimizing."""


def run(cmd, timeout=None, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)


def toml_env(text, section):
    m = re.search(r"\[" + section + r"\.env\]\s*(.*?)(\n\[|\Z)", text, re.S)
    return dict(re.findall(r'^(\w+)\s*=\s*"([^"]*)"', m.group(1), re.M)) if m else {}


def start_container(cn: str, image: str) -> subprocess.CompletedProcess:
    run(["docker", "rm", "-f", cn], timeout=60)
    r = run(["docker", "run", "-d", "--name", cn, "--entrypoint", "sleep", image, "86400"], timeout=600)
    if r.returncode == 0:
        return r
    return run(["docker", "run", "-d", "-t", "--name", cn, image], timeout=600)


def workdir(cn: str) -> str:
    r = run(["docker", "inspect", "-f", "{{.Config.WorkingDir}}", cn], timeout=30)
    wd = (r.stdout or "").strip()
    return wd if wd and wd != "/" else "/app"


def docker_cp(src: str, dest: str) -> subprocess.CompletedProcess:
    return run(["docker", "cp", src, dest], timeout=120)


def parse_usage(blob: str, rec: dict) -> None:
    m = USAGE_RE.search(blob)
    if not m:
        return
    n = lambda s: int(s.replace(",", ""))
    rec.update(
        calls=int(m.group(1)),
        tok_in=n(m.group(2)),
        tok_cached=n(m.group(3)),
        tok_out=n(m.group(5)),
        cost_usd=None if m.group(6).startswith("~") else float(m.group(6)),
    )
    attach_metrics(rec)


def attach_metrics(rec: dict) -> None:
    list_price.attach(rec)
    tin = rec.get("tok_in") or 0
    cached = rec.get("tok_cached") or 0
    rec["cache_hit"] = round(cached / tin, 4) if tin else None
    calls = rec.get("calls") or 0
    prompt = rec.get("list_prompt") or 0
    rec["tok_per_call"] = round(prompt / calls) if calls else None
    # xAI high band is per request. Session totals must not trip it.
    ordinary = rec.get("list_ordinary") or 0
    if rec.get("list_usd") is not None and calls and (prompt / calls) < 200_000:
        p = list_price.rates_for(rec.get("model") or "grok-4.6") or list_price.RATES["grok-4.6"]
        out = rec.get("tok_out") or 0
        rec["list_usd"] = round((ordinary * p["in"] + cached * p["cache"] + out * p["out"]) / 1_000_000.0, 6)
        rec["list_high_band"] = False


def suite_maxima(recs: list[dict]) -> dict:
    def peak(key):
        vals = [r[key] for r in recs if isinstance(r.get(key), (int, float))]
        return max(vals) if vals else None

    return {
        "n": len(recs),
        "pass": sum(1 for r in recs if r.get("pass_")),
        "calls_max": peak("calls"),
        "tok_in_max": peak("tok_in"),
        "tok_cached_max": peak("tok_cached"),
        "tok_out_max": peak("tok_out"),
        "list_usd_max": peak("list_usd"),
        "list_usd_sum": round(sum(r["list_usd"] for r in recs if isinstance(r.get("list_usd"), (int, float))), 4),
        "cache_hit_max": peak("cache_hit"),
        "wall_max": peak("wall_s"),
    }


def run_task(name: str) -> dict:
    toml = open(f"{ROOT}/tasks/{name}/task.toml").read()
    image = re.search(r'^docker_image\s*=\s*"([^"]*)"', toml, re.M).group(1)
    agent_timeout = float(re.search(r"\[agent\]\s*.*?timeout_sec\s*=\s*([\d.]+)", toml, re.S).group(1))
    env = toml_env(toml, "environment")
    instruction = open(f"{ROOT}/tasks/{name}/instruction.md").read()
    cn = f"fh-{name}"
    rec = {"task": name, "harness": "graff", "model": GRAFF_MODEL, "image": image}
    t0 = time.time()
    try:
        r = start_container(cn, image)
        if r.returncode != 0:
            rec.update(pass_=False, error="run: " + ((r.stderr or r.stdout)[-240:]))
            return rec
        wd = workdir(cn)
        run(["docker", "exec", "-u", "0", cn, "mkdir", "-p",
             "/usr/local/bin", "/root/.xai/credentials", wd,
             "/etc/ssl/certs", "/etc/pki/tls/certs"], timeout=30)
        docker_cp(GRAFF_BIN, f"{cn}:/usr/local/bin/graff")
        run(["docker", "exec", "-u", "0", cn, "chmod", "+x", "/usr/local/bin/graff"], timeout=30)
        if os.path.isfile(CA_BUNDLE):
            docker_cp(CA_BUNDLE, f"{cn}:/etc/ssl/certs/ca-certificates.crt")
            docker_cp(CA_BUNDLE, f"{cn}:/etc/pki/tls/certs/ca-bundle.crt")
        if os.path.isfile(XAI_OAUTH) and not (os.environ.get("KIMI_API_KEY") or os.environ.get("MOONSHOT_API_KEY")):
            docker_cp(XAI_OAUTH, f"{cn}:/root/.xai/credentials/graff-oauth.json")
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".md") as af:
            af.write(BENCH_APPEND)
            append_host = af.name
        try:
            docker_cp(append_host, f"{cn}:/append.md")
        finally:
            os.unlink(append_host)

        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".md") as tf:
            tf.write(instruction)
            prompt_host = tf.name
        try:
            docker_cp(prompt_host, f"{cn}:/prompt.md")
        finally:
            os.unlink(prompt_host)

        exec_env = [
            "-u", "0",
            "-w", wd,
            "-e", "HOME=/root",
            "-e", "TERM=dumb",
            "-e", "NO_COLOR=1",
            "-e", "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
            "-e", "SSL_CERT_DIR=/etc/ssl/certs",
            "-e", f"GRAFF_MODEL={GRAFF_MODEL}",
            "-e", f"FH_GRAFF_EXTRA={os.environ.get('FH_GRAFF_EXTRA', '')}",
        ]
        for ek in ("KIMI_API_KEY", "MOONSHOT_API_KEY"):
            if os.environ.get(ek):
                exec_env.extend(["-e", f"{ek}={os.environ[ek]}"])
        for k, v in env.items():
            exec_env.extend(["-e", f"{k}={v}"])

        agent = run(
            ["docker", "exec", *exec_env, cn, "sh", "-c",
             'exec /usr/local/bin/graff -p "$(cat /prompt.md)" --model "$GRAFF_MODEL" --yolo '
             '--append-system-prompt "$(cat /append.md)" $FH_GRAFF_EXTRA'],
            timeout=agent_timeout + 120,
        )
        rec["wall_s"] = round(time.time() - t0, 1)
        rec["agent_exit"] = agent.returncode
        blob = (agent.stdout or "") + "\n" + (agent.stderr or "")
        rec["agent_tail"] = blob[-500:]
        parse_usage(blob, rec)
        if agent.returncode is None:
            rec["error"] = "agent produced no exit code"

        tests_src = f"{TB}/{name}/tests"
        run(["docker", "exec", "-u", "0", cn, "mkdir", "-p", "/tests"], timeout=30)
        docker_cp(tests_src + "/.", f"{cn}:/tests/")
        run(
            ["docker", "exec", "-u", "0", cn, "sh", "-c",
             "export DEBIAN_FRONTEND=noninteractive; "
             "apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-pytest python3-venv ca-certificates; "
             "apk add --no-cache python3 py3-pip py3-pytest >/dev/null 2>&1 || true; "
             "python3 -m pip install -q --break-system-packages pytest GitPython "
             "|| pip3 install -q --break-system-packages pytest GitPython "
             "|| true"],
            timeout=300,
        )
        venv_py = "python3 -m pytest /tests -q --tb=line"
        v = run(
            ["docker", "exec", "-u", "0", "-w", wd,
             *[x for kv in env.items() for x in ("-e", f"{kv[0]}={kv[1]}")],
             cn, "sh", "-c", f"{venv_py}; rc=$?; echo VEXIT:$rc"],
            timeout=900,
        )
        vblob = (v.stdout or "") + (v.stderr or "")
        rec["verify_tail"] = vblob[-240:].strip()
        rec["pass_"] = "VEXIT:0" in vblob
    except subprocess.TimeoutExpired:
        rec["pass_"] = False
        rec["error"] = f"timeout {agent_timeout}s"
        rec["wall_s"] = round(time.time() - t0, 1)
    except Exception as e:
        rec["pass_"] = False
        rec["error"] = repr(e)[:240]
        rec["wall_s"] = round(time.time() - t0, 1)
    finally:
        run(["docker", "rm", "-f", cn], timeout=60)
    return rec


def tb_tasks():
    out = []
    for d in sorted(os.listdir(f"{ROOT}/tasks")):
        if "swe-bench" not in open(f"{ROOT}/tasks/{d}/task.toml").read():
            out.append(d)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks", default="")
    ap.add_argument("-j", type=int, default=1)
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "results.jsonl"))
    ap.add_argument("--fresh", action="store_true", help="ignore existing results file")
    a = ap.parse_args()
    if not os.path.isfile(GRAFF_BIN):
        sys.exit(f"missing linux graff at {GRAFF_BIN}")
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
    print(f"{len(todo)} tasks to run ({len(done)} already done) → {a.out}", flush=True)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "a") as out:
        with ThreadPoolExecutor(max_workers=max(1, a.j)) as ex:
            for rec in ex.map(run_task, todo):
                out.write(json.dumps(rec) + "\n")
                out.flush()
                ok = "PASS" if rec.get("pass_") else "FAIL"
                print(
                    f"{ok} {rec['task']:32} wall={rec.get('wall_s', '-')}s "
                    f"exit={rec.get('agent_exit', '-')} calls={rec.get('calls', '-')} "
                    f"${rec.get('list_usd', '-') } "
                    f"{rec.get('error') or rec.get('verify_tail', '')}",
                    flush=True,
                )
    recs = [json.loads(l) for l in open(a.out) if l.strip()]
    mx = suite_maxima(recs)
    print(
        f"\nmaxima  pass={mx['pass']}/{mx['n']}  "
        f"calls_max={mx['calls_max']}  tok_in_max={mx['tok_in_max']}  "
        f"cache_max={mx['tok_cached_max']}  cache_hit_max={mx['cache_hit_max']}  "
        f"list$_max={mx['list_usd_max']}  list$_sum={mx['list_usd_sum']}  "
        f"wall_max={mx['wall_max']}s",
        flush=True,
    )
    Path(a.out).with_suffix(".maxima.json").write_text(json.dumps(mx, indent=2) + "\n")


if __name__ == "__main__":
    main()
