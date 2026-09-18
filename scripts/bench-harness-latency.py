#!/usr/bin/env python3
"""Opt-in offline JSON harness latency probe; see docs/harness-latency.md."""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import platform
import queue
import statistics
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from mock_model import LoopbackHTTPServer

clock = time.perf_counter_ns


class Model:
    """Records measurements only; does not retain request content or headers."""
    def __init__(self, tool_steps=0):
        self.calls = []
        self.lock = threading.Lock()
        self.tool_steps = tool_steps

    def start(self):
        model = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                payload = b'{"data":[{"id":"lmstudio"}]}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_POST(self):
                arrived = clock()
                length = int(self.headers["Content-Length"])
                body = json.loads(self.rfile.read(length))
                record = {"received_ns": arrived, "request_bytes": length,
                          "messages": len(body.get("messages", []))}
                with model.lock:
                    step = len(model.calls) % (model.tool_steps + 1)
                    model.calls.append(record)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                chunks = [
                    {"choices": [{"index": 0, "delta": {"role": "assistant", "content": "Acknowledged."}, "finish_reason": None}]},
                    {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                     "usage": {"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12}},
                ]
                if step < model.tool_steps:
                    chunks[0]["choices"][0]["delta"] = {"tool_calls": [{
                        "index": 0, "id": f"fixture_{len(model.calls)}", "type": "function",
                        "function": {"name": "read_file", "arguments": '{"path":"fixture.txt"}'}}]}
                    chunks[1]["choices"][0]["finish_reason"] = "tool_calls"
                payload = b"".join(b"data: " + json.dumps(c).encode() + b"\n\n" for c in chunks)
                # Timestamp before write: an upper bound including local send/flush,
                # not a claim to observe when the client's final byte arrived.
                with model.lock:
                    record["response_write_ns"] = clock()
                self.wfile.write(payload + b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True

        # lmstudio's built-in endpoint is fixed. Fail if occupied; never reuse it.
        self.server = LoopbackHTTPServer(("127.0.0.1", 1234), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def read_events(pipe, events):
    for line in pipe:
        observed = clock()
        try:
            events.put((observed, json.loads(line)))
        except ValueError:
            continue
    events.put((clock(), {"type": "eof"}))


def wait_event(events, kind, timeout):
    deadline = time.monotonic() + timeout
    tools = []
    while True:
        timestamp, event = events.get(timeout=max(0, deadline - time.monotonic()))
        if event.get("type") == "eof":
            raise RuntimeError(f"harness exited before {kind}")
        if event.get("type") == "tool_result":
            tools.append(event)
        if event.get("type") == kind:
            return timestamp, event, tools


def run_session(binary, model, turns, payload_bytes, timeout, payload_kind):
    rows = []
    pattern = 'def example():\n    return {"path": "a\\\\b", "ok": True}\n' if payload_kind == "code" else "x"
    payload = (pattern * (payload_bytes // len(pattern) + 1))[:payload_bytes]
    with tempfile.TemporaryDirectory(prefix="graff-latency-") as workspace:
        Path(workspace, "fixture.txt").write_text("Synthetic benchmark evidence.\n")
        # A clean child environment prevents inherited provider/config overrides.
        env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "SYSTEMROOT") if key in os.environ}
        env.update(HOME=workspace, LMSTUDIO_API_KEY="local", GRAFF_NO_TELEMETRY="1",
                   GRAFF_FLEET="off", GRAFF_NO_SMOLIFY="1", GRAFF_LEARN_AUTO="off",
                   GRAFF_CONTEXT="2000000", NO_COLOR="1")
        events = queue.Queue()
        with tempfile.TemporaryFile(mode="w+") as errors:
            started = clock()
            process = subprocess.Popen([str(binary), "--json", "--yolo", "--model", "lmstudio"],
                cwd=workspace, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=errors, text=True, bufsize=1)
            reader = threading.Thread(target=read_events, args=(process.stdout, events), daemon=True)
            reader.start()
            try:
                for turn in range(1, turns + 1):
                    with model.lock:
                        before = len(model.calls)
                    sent = clock()
                    instruction = "Read fixture.txt, then acknowledge." if model.tool_steps else "Acknowledge only; no tools."
                    prompt = f"Synthetic latency fixture {turn}. {instruction} Data: " + payload
                    process.stdin.write(json.dumps({"type": "user", "text": prompt}) + "\n")
                    process.stdin.flush()
                    completed, event, tools = wait_event(events, "turn", timeout)
                    with model.lock:
                        calls = [dict(c) for c in model.calls[before:]]
                    if len(calls) != model.tool_steps + 1 or event.get("text", "").strip() != "Acknowledged.":
                        raise RuntimeError(f"fixture drift at turn {turn}: unexpected request count or final reply ({len(calls)} requests)")
                    if len(tools) != model.tool_steps or any(t.get("name") != "read_file" or
                            t.get("is_error") or "Synthetic benchmark evidence." not in t.get("text", "") for t in tools):
                        raise RuntimeError(f"fixture tool execution failed at turn {turn}")
                    call = calls[-1]
                    if "response_write_ns" not in call:
                        raise RuntimeError("turn event preceded response write")
                    rows.append({"turn": turn, "request_bytes": call["request_bytes"],
                        "messages": call["messages"],
                        "prompt_to_request_ms": (calls[0]["received_ns"] - sent) / 1e6,
                        "response_to_turn_ms": (completed - call["response_write_ns"]) / 1e6,
                        "tool_roundtrip_ms": [(b["received_ns"] - a["response_write_ns"]) / 1e6
                                              for a, b in zip(calls, calls[1:])],
                        "prompt_to_turn_ms": (completed - sent) / 1e6})
                process.stdin.close()
                process.wait(timeout=timeout)
                if process.returncode:
                    raise RuntimeError(f"harness exited {process.returncode}")
                exited = clock()
                shutdown_ms = (exited - completed) / 1e6
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                reader.join(timeout=2)
                process.stdout.close()
                if not process.stdin.closed:
                    process.stdin.close()
    return {"samples": rows, "shutdown_ms": shutdown_ms, "session_ms": (exited - started) / 1e6}


def summarize(values):
    values = sorted(values)
    return {"n": len(values), "median": statistics.median(values),
            "p95": values[max(0, math.ceil(len(values) * .95) - 1)], "max": max(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", type=Path, default=Path(__file__).resolve().parents[1] / "zig-out/bin/graff")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--turns", type=int, default=100)
    parser.add_argument("--payload-bytes", type=int, default=4096)
    parser.add_argument("--payload-kind", choices=("text", "code"), default="text",
                        help="plain ASCII or code with quotes, backslashes, and newlines")
    parser.add_argument("--tool-steps", type=int, default=0, help="read_file steps before each final reply")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if min(args.repeats, args.turns, args.payload_bytes, args.timeout) <= 0:
        parser.error("counts, payload size, and timeout must be positive")
    if not 0 <= args.tool_steps <= 3:
        parser.error("tool-steps must be between 0 and 3")
    binary = args.graff.resolve(strict=True)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    model = Model(args.tool_steps)
    model.start()
    try:
        runs = []
        for repeat in range(args.repeats):
            runs.append(run_session(binary, model, args.turns, args.payload_bytes, args.timeout, args.payload_kind))
            print(f"Completed session {repeat + 1}/{args.repeats}", file=sys.stderr, flush=True)
    finally:
        model.stop()
    if hashlib.sha256(binary.read_bytes()).hexdigest() != digest:
        raise RuntimeError("binary changed during measurement; rerun with a stable copy")
    summary = {}
    # Compare identical history positions across independent sessions, not a mix
    # of different workloads masquerading as repeated samples.
    for turn in sorted({1, min(10, args.turns), min(50, args.turns), args.turns}):
        samples = [run["samples"][turn - 1] for run in runs]
        summary[str(turn)] = {key: summarize([s[key] for s in samples]) for key in
            ("prompt_to_request_ms", "response_to_turn_ms", "prompt_to_turn_ms", "request_bytes")}
    report = {"schema_version": 1, "binary_sha256": digest,
        "platform": platform.system(), "machine": platform.machine(),
        "python": platform.python_version(), "turns": args.turns,
        "payload_bytes": args.payload_bytes, "repeats": args.repeats,
        "payload_kind": args.payload_kind,
        "tool_steps": args.tool_steps,
        "summary_by_turn": summary, "runs": runs}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, queue.Empty, subprocess.TimeoutExpired) as exc:
        sys.exit(f"latency probe failed: {exc}")
