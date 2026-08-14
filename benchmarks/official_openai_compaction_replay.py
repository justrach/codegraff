#!/usr/bin/env python3
"""Replay frozen tool history through the official OpenAI Platform compact path."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import time
from typing import Any
import urllib.error
import urllib.request

DEFAULT_FIXTURE = Path(
    "/tmp/compact_bench/runs/none1/.graff/sessions/"
    "auditing-zig-constants-and-recording-answers.session.json"
)
BASE = "https://api.openai.com/v1"
SYSTEM = (
    "You are a deterministic continuation scorer. Never call tools or inspect "
    "the filesystem. Answer only from retained conversation state and follow "
    "the requested output format exactly."
)
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
NAMES = (
    "OBSIDIAN_ALPHA", "LANTERN_ALPHA", "COPSE_BETA", "NUMEN_BETA",
    "EMBER_GAMMA", "QUORUM_GAMMA", "WELKIN_DELTA", "KINDLE_DELTA",
    "HOLLOW_EPSILO", "MARROW_EPSILO",
)
PROBE = (
    "Using only the retained conversation state, answer these constants again. "
    "Do not call tools. Reply with EXACTLY ten lines and no other text:\n"
    + "\n".join(f"Q{i}: exact value of {name}" for i, name in enumerate(NAMES, 1))
)


def args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--models", nargs="+", default=["gpt-5.6-sol", "gpt-5.6-luna"])
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=420)
    return parser.parse_args()


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def post(key: str, path: str, body: dict[str, Any], timeout: int) -> tuple[dict[str, Any], dict[str, int]]:
    payload = json.dumps(body, separators=(",", ":")).encode()
    request = urllib.request.Request(
        BASE + path,
        data=payload,
        method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return json.loads(raw), {
                "status": response.status,
                "ms": round((time.monotonic() - started) * 1000),
                "request_bytes": len(payload),
                "response_bytes": len(raw),
                "errors": 0,
            }
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            message = json.loads(raw).get("error", {}).get("message", "OpenAI API error")
        except json.JSONDecodeError:
            message = "non-JSON OpenAI API error"
        raise RuntimeError(f"HTTP {error.code}: {message}") from error


def response_text(response: dict[str, Any]) -> str:
    text = response.get("output_text")
    if isinstance(text, str):
        return text
    chunks = []
    for item in response.get("output", []):
        if item.get("type") != "message":
            continue
        for content in item.get("content", []):
            if content.get("type") == "output_text":
                chunks.append(content.get("text", ""))
    return "".join(chunks)


def score(text: str) -> tuple[int, dict[str, str]]:
    got = {
        match.group(1): match.group(2).strip()
        for match in re.finditer(r"(?m)^Q(10|[1-9]):\s*([^\r\n]+)", text)
    }
    return sum(got.get(str(i)) == value for i, value in EXPECTED.items()), got


def usage(response: dict[str, Any]) -> dict[str, int]:
    value = response.get("usage") or {}
    details = value.get("input_tokens_details") or {}
    return {
        "input_tokens": int(value.get("input_tokens", 0)),
        "cached_tokens": int(details.get("cached_tokens", 0)),
        "output_tokens": int(value.get("output_tokens", 0)),
        "total_tokens": int(value.get("total_tokens", 0)),
    }


def replayable_fixture(path: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    raw = path.read_bytes()
    data = json.loads(raw)
    original = data.get("messages", [])
    messages = [item for item in original if item.get("type") != "reasoning"]
    call_ids = {item.get("call_id") for item in messages if item.get("type") == "function_call"}
    output_ids = {item.get("call_id") for item in messages if item.get("type") == "function_call_output"}
    if not messages or call_ids != output_ids:
        raise SystemExit("fixture must retain exactly paired function calls and outputs")
    return messages, {
        "fixture": str(path.resolve()),
        "fixture_sha256": hashlib.sha256(raw).hexdigest(),
        "platform_input_sha256": hashlib.sha256(canonical(messages)).hexdigest(),
        "original_items": len(original),
        "platform_items": len(messages),
        "removed_backend_reasoning_items": len(original) - len(messages),
        "function_calls": sum(item.get("type") == "function_call" for item in messages),
        "function_outputs": sum(item.get("type") == "function_call_output" for item in messages),
    }


def run_trial(key: str, model: str, trial: int, messages: list[dict[str, Any]], timeout: int) -> dict[str, Any]:
    started = time.monotonic()
    compacted, compact_wire = post(key, "/responses/compact", {
        "model": model,
        "instructions": SYSTEM,
        "input": messages,
    }, timeout)
    output = compacted.get("output")
    if not isinstance(output, list) or not output:
        raise RuntimeError("compact response had no output array")
    probe = {"type": "message", "role": "user", "content": PROBE}
    response, response_wire = post(key, "/responses", {
        "model": model,
        "instructions": SYSTEM,
        "input": output + [probe],
        "store": False,
    }, timeout)
    text = response_text(response)
    correct, answers = score(text)
    metrics = {
        "model": model,
        "trial": trial,
        "correct": correct,
        "of": len(EXPECTED),
        "answers": answers,
        "wall_ms": round((time.monotonic() - started) * 1000),
        "api_errors": compact_wire["errors"] + response_wire["errors"],
        "compact_ms": compact_wire["ms"],
        "continuation_ms": response_wire["ms"],
        "request_bytes": compact_wire["request_bytes"] + response_wire["request_bytes"],
        "response_bytes": compact_wire["response_bytes"] + response_wire["response_bytes"],
        "compact_output_types": [item.get("type") for item in output],
        "compact_output_items": len(output),
        "compact_usage": usage(compacted),
        "continuation_usage": usage(response),
    }
    return metrics


def main() -> None:
    options = args()
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        raise SystemExit("OPENAI_API_KEY is required")
    if options.trials < 1:
        raise SystemExit("--trials must be positive")
    options.out.mkdir(parents=True, exist_ok=True)
    messages, fixture = replayable_fixture(options.fixture)
    manifest = {
        **fixture,
        "base_url": BASE,
        "models": options.models,
        "trials": options.trials,
        "probe": PROBE,
        "expected": EXPECTED,
    }
    (options.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    results = []
    for model in options.models:
        model_dir = options.out / model
        model_dir.mkdir(exist_ok=True)
        for trial in range(1, options.trials + 1):
            metrics = run_trial(key, model, trial, messages, options.timeout)
            results.append(metrics)
            (model_dir / f"trial-{trial}.json").write_text(json.dumps(metrics, indent=2) + "\n")
            print(
                f"model={model} trial={trial} score={metrics['correct']}/{metrics['of']} "
                f"compact_items={metrics['compact_output_items']} wall={metrics['wall_ms']}ms",
                flush=True,
            )
    (options.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    for model in options.models:
        rows = [row for row in results if row["model"] == model]
        print(
            f"summary model={model} perfect={sum(row['correct'] == row['of'] for row in rows)}/{len(rows)} "
            f"median_wall={statistics.median(row['wall_ms'] for row in rows):.0f}ms",
            flush=True,
        )


if __name__ == "__main__":
    main()
