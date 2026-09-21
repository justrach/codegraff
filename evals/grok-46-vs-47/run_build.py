#!/usr/bin/env python3
"""Single-turn Grok Build runs of three codegraff PRs at high effort.

Uses the local `grok` CLI (Grok Build), not the public HTTPS API.
Token cost in the CLI receipt is the public list rate: $2 / 1M input,
$0.50 / 1M cached input, $6 / 1M output. Reasoning tokens are inside output.
"""

import json
import subprocess
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROMPTS = ROOT / "prompts"
OUT = ROOT / "runs"
OUT.mkdir(exist_ok=True)

MODELS = ("grok-4.6", "grok-4.7")
PRS = ("1149", "1096", "1035")
SYSTEM = (
    "You write unified diffs. Do not use tools. Do not search. "
    "Output one unified diff and nothing else."
)


def run_one(model: str, pr: str) -> None:
    session = str(uuid.uuid4())
    dest = OUT / f"{model}-{pr}.json"
    meta_path = OUT / f"{model}-{pr}.meta.json"
    prompt = PROMPTS / f"{pr}.txt"
    cmd = [
        "grok",
        "--prompt-file",
        str(prompt),
        "-m",
        model,
        "--reasoning-effort",
        "high",
        "--output-format",
        "json",
        "--max-turns",
        "1",
        "--no-plan",
        "--no-subagents",
        "--disable-web-search",
        "--permission-mode",
        "plan",
        "--verbatim",
        "--session-id",
        session,
        "--system-prompt-override",
        SYSTEM,
        "--disallowed-tools",
        "bash,edit,write,read,grep,webfetch",
    ]
    started = time.perf_counter()
    wall_start = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    proc = subprocess.run(
        cmd,
        cwd="/tmp",
        capture_output=True,
        text=True,
        timeout=900,
    )
    elapsed = time.perf_counter() - started
    payload = {
        "model_flag": model,
        "pr": pr,
        "session_id": session,
        "wall_s": round(elapsed, 3),
        "started_at": wall_start,
        "exit_code": proc.returncode,
        "stderr": proc.stderr[-4000:],
    }
    try:
        payload["response"] = json.loads(proc.stdout)
    except json.JSONDecodeError:
        payload["stdout_raw"] = proc.stdout[-20000:]
    dest.write_text(json.dumps(payload, indent=2) + "\n")
    usage = (payload.get("response") or {}).get("usage") or {}
    meta_path.write_text(
        json.dumps(
            {
                "model_flag": model,
                "pr": pr,
                "session_id": session,
                "wall_s": payload["wall_s"],
                "exit_code": proc.returncode,
                "usage": usage,
                "modelUsage": (payload.get("response") or {}).get("modelUsage"),
                "total_cost_usd": (payload.get("response") or {}).get("total_cost_usd"),
                "stopReason": (payload.get("response") or {}).get("stopReason"),
            },
            indent=2,
        )
        + "\n"
    )
    print(
        f"{model} pr={pr} exit={proc.returncode} wall={payload['wall_s']}s "
        f"in={usage.get('input_tokens')} out={usage.get('output_tokens')} "
        f"reason={usage.get('reasoning_tokens')} cost={payload.get('response', {}).get('total_cost_usd') if isinstance(payload.get('response'), dict) else None}",
        flush=True,
    )


def main() -> None:
    # Head-to-head: both models see the same prompt in the same window.
    from concurrent.futures import ThreadPoolExecutor

    for pr in PRS:
        print(f"== pair {pr} ==", flush=True)
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda model: run_one(model, pr), MODELS))


if __name__ == "__main__":
    main()
