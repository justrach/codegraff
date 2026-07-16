#!/usr/bin/env python3
"""Prove simultaneous graff processes write isolated, correlated JSONL."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

from codex_ws_mock import CodexMock


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


def validate_run_file(path: str) -> tuple[str, int, str]:
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
    return identity


def main() -> None:
    mock = CodexMock()
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-run-isolation-") as tmp:
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
                    "GRAFF_CODEX_WS": "off",
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

            trace_ids = {validate_run_file(path) for path in traces}
            trajectory_ids = {validate_run_file(path) for path in trajectories}
            if trace_ids != trajectory_ids:
                raise AssertionError(
                    f"trace/trajectory correlation mismatch: {trace_ids!r} != {trajectory_ids!r}"
                )
            if {pid for _run_id, pid, _session_id in trace_ids} != expected_pids:
                raise AssertionError(
                    f"record PIDs do not match child processes: {trace_ids!r}, {expected_pids!r}"
                )
    finally:
        mock.stop()

    print("ok    two simultaneous runs produced isolated, fully correlated JSONL")


if __name__ == "__main__":
    main()
