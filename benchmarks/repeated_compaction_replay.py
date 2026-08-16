#!/usr/bin/env python3
"""Repeated live A/B over one canonical Responses tool trajectory.

The server arm loads the frozen history into the experimental Codegraff binary,
lets automatic compaction replace it with the complete `/responses/compact`
output, then sends the continuation probe. The local arm loads the same history,
invokes Codegraff's JSON compact control, and sends the identical probe. The
legacy latest-item function remains below to preserve the before methodology;
trial order alternates to reduce time bias.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from typing import Any
import urllib.error
import urllib.request
import uuid

DEFAULT_FIXTURE = Path(
    "/tmp/compact_bench/runs/none1/.graff/sessions/"
    "auditing-zig-constants-and-recording-answers.session.json"
)
DEFAULT_AUTH = Path.home() / ".codex" / "auth.json"
CODEX_BASE = "https://chatgpt.com/backend-api/codex"
EXPECTED = {
    1: "61701",
    2: "89665",
    3: "43973",
    4: "26089",
    5: '"ember-986"',
    6: "89289",
    7: '"welkin-815"',
    8: '"kindle-443"',
    9: '"hollow-765"',
    10: "23041",
}
QUESTIONS = [
    (1, "OBSIDIAN_ALPHA"),
    (2, "LANTERN_ALPHA"),
    (3, "COPSE_BETA"),
    (4, "NUMEN_BETA"),
    (5, "EMBER_GAMMA"),
    (6, "QUORUM_GAMMA"),
    (7, "WELKIN_DELTA"),
    (8, "KINDLE_DELTA"),
    (9, "HOLLOW_EPSILO"),
    (10, "MARROW_EPSILO"),
]
SYSTEM = (
    "You are a deterministic continuation scorer. Never call tools or inspect "
    "the filesystem. Answer only from retained conversation state and follow "
    "the requested output format exactly."
)
PROBE = (
    "Using only the retained conversation state, answer these constants again. "
    "Do not call tools. Reply with EXACTLY ten lines and no other text:\n"
    + "\n".join(f"Q{n}: exact value of {name}" for n, name in QUESTIONS)
)
ACK = "Reply with only ACK."


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--auth", type=Path, default=DEFAULT_AUTH)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--model", default="gpt-5.6-sol")
    parser.add_argument("--compact-pct", type=int, default=6)
    parser.add_argument("--context-window", type=int, default=272_000)
    parser.add_argument("--timeout", type=int, default=420)
    return parser.parse_args()


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def strings(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)


def output_text(stdout: str) -> str:
    found: list[str] = []
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        for text in strings(event):
            if "Q1:" in text or "Q10:" in text:
                found.append(text)
    return "\n".join(found)


def score(text: str) -> tuple[int, dict[str, str]]:
    got = {}
    for match in re.finditer(r"(?m)^Q(10|[1-9]):\s*([^\r\n]+)", text):
        got[match.group(1)] = match.group(2).strip()
    correct = sum(got.get(str(n)) == expected for n, expected in EXPECTED.items())
    return correct, got


def usage_metrics(usage: dict[str, Any] | None) -> dict[str, int]:
    usage = usage or {}
    details = usage.get("input_tokens_details") or {}
    return {
        "input_tokens": int(usage.get("input_tokens", 0)),
        "cache_read_tokens": int(details.get("cached_tokens", 0)),
        "output_tokens": int(usage.get("output_tokens", 0)),
        "total_tokens": int(usage.get("total_tokens", 0)),
    }


def add_metrics(left: dict[str, int], right: dict[str, int]) -> dict[str, int]:
    return {key: left.get(key, 0) + right.get(key, 0) for key in left | right}


def load_auth(path: Path) -> tuple[str, str]:
    auth = json.loads(path.read_text())
    tokens = auth.get("tokens", auth)
    token = tokens.get("access_token")
    account = tokens.get("account_id") or auth.get("account_id")
    if not token or not account:
        raise SystemExit(f"Codex auth lacks access_token/account_id: {path}")
    return token, account


def run_stream(
    args: argparse.Namespace,
    body: dict[str, Any],
) -> tuple[list[dict[str, Any]], str, dict[str, Any] | None, dict[str, int]]:
    token, account = load_auth(args.auth)
    payload = json.dumps(body, separators=(",", ":")).encode()
    attempts = errors = response_bytes = 0
    started = time.monotonic()
    for retry in range(3):
        attempts += 1
        request = urllib.request.Request(
            CODEX_BASE + "/responses",
            data=payload,
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "chatgpt-account-id": account,
                "OpenAI-Beta": "responses=experimental",
                "originator": "codex_cli_rs",
                "session_id": str(uuid.uuid4()),
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            },
        )
        items: list[dict[str, Any]] = []
        text: list[str] = []
        usage = None
        try:
            with urllib.request.urlopen(request, timeout=args.timeout) as response:
                for raw in response:
                    response_bytes += len(raw)
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        event = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    event_type = event.get("type", "")
                    if event_type == "response.output_item.done":
                        items.append(event.get("item", {}))
                    elif event_type == "response.output_text.delta":
                        text.append(event.get("delta", ""))
                    elif event_type in ("response.completed", "response.incomplete"):
                        result = event.get("response", {})
                        usage = result.get("usage")
                        known = {item.get("id") for item in items}
                        for item in result.get("output", []):
                            if item.get("id") not in known:
                                items.append(item)
            return items, "".join(text), usage, {
                "http_attempts": attempts,
                "http_errors": errors,
                "request_bytes": len(payload) * attempts,
                "response_bytes": response_bytes,
                "api_ms": round((time.monotonic() - started) * 1000),
            }
        except urllib.error.HTTPError as error:
            errors += 1
            if error.code not in (429, 500, 502, 503, 504) or retry == 2:
                raise
            time.sleep(2 ** retry)
    raise RuntimeError("unreachable")


def trace_metrics(trial_dir: Path) -> dict[str, int]:
    events = []
    for trace in (trial_dir / ".graff" / "traces").glob("*.jsonl"):
        for line in trace.read_text(errors="replace").splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("ev") == "api":
                events.append(event)
    return {
        "api_calls": len(events),
        "api_errors": sum(bool(event.get("is_error")) for event in events),
        "api_ms": sum(int(event.get("ms", 0)) for event in events),
        "request_bytes": sum(int(event.get("req_bytes", 0)) for event in events),
        "response_bytes": sum(int(event.get("resp_bytes", 0)) for event in events),
        "context_tokens": sum(int(event.get("context_tokens", 0)) for event in events),
        "cache_read_tokens": sum(int(event.get("cache_read_tokens", 0)) for event in events),
    }


def run_latest_item_server(args: argparse.Namespace, trial: int, fixture: dict[str, Any]) -> dict[str, Any]:
    trial_dir = args.out / f"trial-{trial}" / "server"
    trial_dir.mkdir(parents=True)
    messages = fixture["messages"]
    threshold = args.context_window // 100 * args.compact_pct
    started = time.monotonic()
    items1, ack, usage1, wire1 = run_stream(
        args,
        {
            "model": args.model,
            "store": False,
            "stream": True,
            "instructions": SYSTEM,
            "input": messages + [{"type": "message", "role": "user", "content": ACK}],
            "context_management": [{"type": "compaction", "compact_threshold": threshold}],
        },
    )
    compacted = [
        item for item in items1
        if item.get("type") in ("compaction", "compaction_summary")
    ]
    if not compacted:
        raise RuntimeError(f"server trial {trial} returned no compaction item")
    latest = compacted[-1]
    items2, answer, usage2, wire2 = run_stream(
        args,
        {
            "model": args.model,
            "store": False,
            "stream": True,
            "instructions": SYSTEM,
            "input": [
                latest,
                {"type": "message", "role": "user", "content": PROBE},
            ],
            "context_management": [{"type": "compaction", "compact_threshold": threshold}],
        },
    )
    wall_ms = round((time.monotonic() - started) * 1000)
    correct, got = score(answer)
    usage = add_metrics(usage_metrics(usage1), usage_metrics(usage2))
    wire = add_metrics(wire1, wire2)
    (trial_dir / "answer.txt").write_text(answer)
    metrics = {
        "trial": trial,
        "arm": "server",
        "returncode": 0,
        "timed_out": False,
        "wall_ms": wall_ms,
        "correct": correct,
        "of": len(EXPECTED),
        "answers": got,
        "ack": ack,
        "api_calls": 2,
        "api_errors": wire["http_errors"],
        "context_tokens": usage["input_tokens"],
        "cache_read_tokens": usage["cache_read_tokens"],
        "output_tokens": usage["output_tokens"],
        "request_bytes": wire["request_bytes"],
        "response_bytes": wire["response_bytes"],
        "api_ms": wire["api_ms"],
        "session_bytes": len(canonical([latest])),
        "message_count": 1,
        "compaction_items": len(compacted),
        "function_calls": 0,
        "function_outputs": 0,
        "phase1_item_types": [item.get("type") for item in items1],
        "phase2_item_types": [item.get("type") for item in items2],
    }
    (trial_dir / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    return metrics


def run_server(args: argparse.Namespace, trial: int, fixture: dict[str, Any]) -> dict[str, Any]:
    del fixture  # the binary reads the byte-identical copied session
    trial_dir = args.out / f"trial-{trial}" / "server"
    sessions = trial_dir / ".graff" / "sessions"
    sessions.mkdir(parents=True)
    session_path = sessions / "frozen.session.json"
    shutil.copy2(args.fixture, session_path)
    session = json.loads(session_path.read_text())
    session["context_tokens"] = 0
    session["context_local_tokens"] = 0
    session_path.write_text(json.dumps(session, separators=(",", ":")))

    stdin = json.dumps({"type": "user", "text": PROBE}) + "\n"
    env = {
        **os.environ,
        "GRAFF_SERVER_COMPACT": "1",
        "GRAFF_COMPACT_PCT": str(args.compact_pct),
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_FLEET": "off",
    }
    command = [
        str(args.binary.resolve()),
        "--json",
        "--resume",
        "frozen",
        "--model",
        args.model,
        "--no-telemetry",
        "--system-prompt",
        SYSTEM,
        "--max-model-calls",
        "8",
    ]
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=trial_dir,
            env=env,
            input=stdin,
            text=True,
            capture_output=True,
            timeout=args.timeout,
        )
        timed_out = False
    except subprocess.TimeoutExpired as error:
        completed = subprocess.CompletedProcess(
            command,
            -1,
            stdout=error.stdout or "",
            stderr=error.stderr or "",
        )
        timed_out = True
    wall_ms = round((time.monotonic() - started) * 1000)
    (trial_dir / "stdout.jsonl").write_text(completed.stdout)
    (trial_dir / "stderr.txt").write_text(completed.stderr)
    answer = output_text(completed.stdout)
    (trial_dir / "answer.txt").write_text(answer)
    correct, got = score(answer)
    data = json.loads(session_path.read_text())
    types = [message.get("type", message.get("role", "unknown")) for message in data["messages"]]
    trace = trace_metrics(trial_dir)
    turn_event: dict[str, Any] = {}
    for line in completed.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "turn":
            turn_event = event
    if turn_event:
        trace["api_calls"] = int(turn_event.get("api_calls", trace["api_calls"]))
        trace["context_tokens"] = int(turn_event.get("input_tokens", trace["context_tokens"]))
        trace["cache_read_tokens"] = int(turn_event.get("cache_read_tokens", trace["cache_read_tokens"]))
    compact_items = types.count("compaction") + types.count("compaction_summary")
    metrics = {
        "trial": trial,
        "arm": "server",
        "mechanism": "binary /responses/compact full-output replacement",
        "returncode": completed.returncode,
        "timed_out": timed_out,
        "wall_ms": wall_ms,
        "correct": correct,
        "of": len(EXPECTED),
        "answers": got,
        **trace,
        "untraced_compact_api_calls": 1 if compact_items else 0,
        "output_tokens": int(turn_event.get("output_tokens", 0)),
        "session_bytes": session_path.stat().st_size,
        "message_count": len(types),
        "compaction_items": compact_items,
        "server_compaction_observed": compact_items > 0,
        "function_calls": types.count("function_call"),
        "function_outputs": types.count("function_call_output"),
        "message_types": types,
    }
    (trial_dir / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    return metrics


def run_local(args: argparse.Namespace, trial: int) -> dict[str, Any]:
    trial_dir = args.out / f"trial-{trial}" / "local"
    sessions = trial_dir / ".graff" / "sessions"
    sessions.mkdir(parents=True)
    session_path = sessions / "frozen.session.json"
    shutil.copy2(args.fixture, session_path)
    session = json.loads(session_path.read_text())
    session["context_tokens"] = 0
    session["context_local_tokens"] = 0
    session_path.write_text(json.dumps(session, separators=(",", ":")))

    stdin = "".join(
        json.dumps(control) + "\n"
        for control in (
            {"type": "compact"},
            {"type": "user", "text": PROBE},
        )
    )
    env = {
        **os.environ,
        "GRAFF_SERVER_COMPACT": "0",
        "GRAFF_COMPACT_PCT": "100",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_FLEET": "off",
    }
    command = [
        str(args.binary.resolve()),
        "--json",
        "--resume",
        "frozen",
        "--model",
        args.model,
        "--no-telemetry",
        "--system-prompt",
        SYSTEM,
        "--max-model-calls",
        "8",
    ]
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=trial_dir,
            env=env,
            input=stdin,
            text=True,
            capture_output=True,
            timeout=args.timeout,
        )
        timed_out = False
    except subprocess.TimeoutExpired as error:
        completed = subprocess.CompletedProcess(
            command,
            -1,
            stdout=error.stdout or "",
            stderr=error.stderr or "",
        )
        timed_out = True
    wall_ms = round((time.monotonic() - started) * 1000)
    (trial_dir / "stdout.jsonl").write_text(completed.stdout)
    (trial_dir / "stderr.txt").write_text(completed.stderr)
    answer = output_text(completed.stdout)
    (trial_dir / "answer.txt").write_text(answer)
    correct, got = score(answer)
    data = json.loads(session_path.read_text())
    types = [message.get("type", message.get("role", "unknown")) for message in data["messages"]]
    compact_events = []
    turn_event: dict[str, Any] = {}
    for line in completed.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "compact" and event.get("ok"):
            compact_events.append(event)
        elif event.get("type") == "turn":
            turn_event = event
    trace = trace_metrics(trial_dir)
    if turn_event:
        trace["api_calls"] = int(turn_event.get("api_calls", trace["api_calls"]))
        trace["context_tokens"] = int(turn_event.get("input_tokens", trace["context_tokens"]))
        trace["cache_read_tokens"] = int(turn_event.get("cache_read_tokens", trace["cache_read_tokens"]))
    metrics = {
        "trial": trial,
        "arm": "local",
        "returncode": completed.returncode,
        "timed_out": timed_out,
        "wall_ms": wall_ms,
        "correct": correct,
        "of": len(EXPECTED),
        "answers": got,
        **trace,
        "output_tokens": int(turn_event.get("output_tokens", 0)),
        "session_bytes": session_path.stat().st_size,
        "message_count": len(types),
        "compaction_items": 0,
        "local_compact_events": len(compact_events),
        "local_summary_chars": sum(int(event.get("chars", 0)) for event in compact_events),
        "function_calls": types.count("function_call"),
        "function_outputs": types.count("function_call_output"),
        "message_types": types,
    }
    (trial_dir / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    return metrics


def validate_fixture(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    raw = path.read_bytes()
    data = json.loads(raw)
    messages = data.get("messages", [])
    kinds = [message.get("type", message.get("role", "unknown")) for message in messages]
    call_ids = {message.get("call_id") for message in messages if message.get("type") == "function_call"}
    output_ids = {message.get("call_id") for message in messages if message.get("type") == "function_call_output"}
    if not messages or call_ids != output_ids:
        raise SystemExit("fixture must have non-empty history and exactly paired tool calls/results")
    manifest = {
        "fixture": str(path.resolve()),
        "fixture_sha256": hashlib.sha256(raw).hexdigest(),
        "message_sha256": hashlib.sha256(canonical(messages)).hexdigest(),
        "fixture_bytes": len(raw),
        "fixture_messages": len(messages),
        "fixture_function_calls": kinds.count("function_call"),
        "fixture_function_outputs": kinds.count("function_call_output"),
        "fixture_context_tokens": data.get("context_tokens"),
    }
    return data, manifest


def main() -> None:
    args = parse_args()
    args.binary = args.binary.resolve()
    args.fixture = args.fixture.resolve()
    args.auth = args.auth.expanduser().resolve()
    args.out = args.out.resolve()
    if args.trials < 1 or not 1 <= args.compact_pct <= 100:
        raise SystemExit("--trials must be positive and --compact-pct must be 1..100")
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        raise SystemExit(f"binary is not executable: {args.binary}")
    if not args.fixture.is_file() or not args.auth.is_file():
        raise SystemExit("fixture and Codex auth file must exist")
    args.out.mkdir(parents=True, exist_ok=True)
    fixture, fixture_manifest = validate_fixture(args.fixture)
    manifest = {
        **fixture_manifest,
        "binary": str(args.binary),
        "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "model": args.model,
        "compact_pct": args.compact_pct,
        "context_window": args.context_window,
        "compact_threshold": args.context_window // 100 * args.compact_pct,
        "trials": args.trials,
        "probe": PROBE,
        "expected": EXPECTED,
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    results = []
    for trial in range(1, args.trials + 1):
        order = ("server", "local") if trial % 2 else ("local", "server")
        for arm in order:
            result = (
                run_server(args, trial, fixture)
                if arm == "server"
                else run_local(args, trial)
            )
            results.append(result)
            print(
                f"trial={trial} arm={arm} score={result['correct']}/{result['of']} "
                f"calls={result['api_calls']} context={result['context_tokens']} "
                f"cached={result['cache_read_tokens']} wall={result['wall_ms']}ms "
                f"compactions={result.get('compaction_items', 0) + result.get('local_compact_events', 0)}",
                flush=True,
            )
    (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"wrote {args.out / 'results.json'}")


if __name__ == "__main__":
    main()
