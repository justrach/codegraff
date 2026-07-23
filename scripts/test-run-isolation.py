#!/usr/bin/env python3
"""Prove simultaneous graff processes write isolated, correlated JSONL."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest, turn_events


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def records(path: str) -> list[dict]:
    with open(path, "rb") as fh:
        raw = fh.read()
    if not raw or b"\x00" in raw:
        raise AssertionError(f"empty/corrupt JSONL: {path}")
    parsed = []
    for number, line in enumerate(raw.splitlines(), 1):
        try:
            parsed.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise AssertionError(f"{path}:{number}: invalid JSON: {exc}") from exc
    return parsed


def validate_run_file(path: str) -> tuple[tuple[str, int, str], list[dict]]:
    run_id = os.path.basename(path).removesuffix(".jsonl")
    rows = records(path)
    identity = (run_id, rows[0].get("pid"), rows[0].get("session_id"))
    if not isinstance(identity[1], int) or not isinstance(identity[2], str):
        raise AssertionError(f"missing PID/session identity: {path}")
    if len(identity[2]) != 32 or any(c not in "0123456789abcdef" for c in identity[2]):
        raise AssertionError(f"malformed session id in {path}: {identity[2]!r}")
    for row in rows:
        current = (row.get("run_id"), row.get("pid"), row.get("session_id"))
        if current != identity:
            raise AssertionError(f"mixed identity in {path}: {current!r} != {identity!r}")
    return identity, rows


def response_events(item: dict, response_id: str) -> list[dict]:
    return [
        {"type": "response.output_item.done", "item": item},
        turn_events(response_id)[1],
    ]


def events(request: RecordedRequest) -> list[dict]:
    """Make every process execute one real tool before its final response."""
    inputs = request.body.get("input", [])
    if any(
        isinstance(item, dict) and item.get("type") == "function_call_output"
        for item in inputs
    ):
        return turn_events(f"resp_isolation_done_{request.ordinal}")
    return response_events(
        {
            "type": "function_call",
            "id": f"fc_isolation_{request.ordinal}",
            "call_id": f"call_isolation_{request.ordinal}",
            "name": "read_file",
            "arguments": json.dumps({"path": "fixture.txt"}),
            "status": "completed",
        },
        f"resp_isolation_tool_{request.ordinal}",
    )


def main() -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-run-isolation-") as tmp:
            with open(os.path.join(tmp, "fixture.txt"), "w", encoding="utf-8") as fh:
                fh.write("concurrent trace fixture\n")
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "run-isolation-mock",
                            "account_id": "acct-run-isolation",
                        }
                    },
                    fh,
                )
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
                json.dump({"skills": {"codedbpro": False}}, fh)

            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("GRAFF_") and not key.startswith("CODEX_")
            }
            env.update(
                {
                    "HOME": tmp,
                    "CODEX_HOME": codex_home,
                    "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                    # Both concurrent processes exercise the WS -> SSE fallback
                    # path named in #272 while their tool events overlap.
                    "GRAFF_WS_FORCE_FAIL_COUNT": "2",
                    "GRAFF_FLEET": "off",
                    "GRAFF_NO_TELEMETRY": "1",
                }
            )
            processes = [
                subprocess.Popen(
                    [
                        GRAFF,
                        "--model",
                        "codex",
                        "--no-telemetry",
                        "--no-resume",
                        "-p",
                        f"reply to simultaneous run {index}",
                    ],
                    cwd=tmp,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for index in range(2)
            ]
            expected_pids = {process.pid for process in processes}
            for process in processes:
                stdout, stderr = process.communicate(timeout=15)
                if process.returncode != 0:
                    raise AssertionError(
                        f"graff pid {process.pid} exited {process.returncode}\n"
                        f"stdout:\n{stdout}\nstderr:\n{stderr}"
                    )

            trace_dir = os.path.join(tmp, ".graff", "traces")
            trajectory_dir = os.path.join(tmp, ".graff", "trajectories")
            traces = sorted(os.path.join(trace_dir, name) for name in os.listdir(trace_dir))
            trajectories = sorted(
                os.path.join(trajectory_dir, name) for name in os.listdir(trajectory_dir)
            )
            if len(traces) != 2 or len(trajectories) != 2:
                raise AssertionError(
                    f"expected two trace + trajectory files, got {traces!r}, {trajectories!r}"
                )

            trace_runs = dict(validate_run_file(path) for path in traces)
            trajectory_runs = dict(validate_run_file(path) for path in trajectories)
            if trace_runs.keys() != trajectory_runs.keys():
                raise AssertionError(
                    "trace/trajectory correlation mismatch: "
                    f"{trace_runs.keys()!r} != {trajectory_runs.keys()!r}"
                )
            if {pid for _run_id, pid, _session_id in trace_runs} != expected_pids:
                raise AssertionError(
                    "record PIDs do not match child processes: "
                    f"{trace_runs.keys()!r}, {expected_pids!r}"
                )
            for identity, rows in trace_runs.items():
                if not any(row.get("ev") == "tool" for row in rows):
                    raise AssertionError(f"missing tool event in trace {identity!r}")
                times = [row["t"] for row in rows if isinstance(row.get("t"), int)]
                if times != sorted(times):
                    raise AssertionError(f"timestamp rollback within trace {identity!r}")
            if os.path.exists(os.path.join(tmp, "harness.trace.jsonl")):
                raise AssertionError("current run recreated retired harness.trace.jsonl")
            if mock.ws_turns != 0 or mock.sse_turns != 4:
                raise AssertionError(
                    f"expected four SSE tool/final turns after forced fallback, "
                    f"got ws={mock.ws_turns} sse={mock.sse_turns}"
                )
    finally:
        mock.stop()

    print(
        "ok    concurrent tool runs survived WS->SSE fallback with isolated, "
        "valid, monotonic JSONL"
    )


if __name__ == "__main__":
    main()
