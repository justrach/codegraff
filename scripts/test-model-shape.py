#!/usr/bin/env python3
"""Live proof that a Sol root routes delegated work to Terra."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from codex_ws_mock import CodexMock, RecordedRequest


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
ROOT_MODEL = "gpt-5.6-sol"
CHILD_MODEL = "gpt-5.6-terra"
CHILD_REPORT = "TERRA_WORKER_REPORT"
FINAL_REPORT = "SOL_SYNTHESIS_OK"


def message_item(text: str, item_id: str) -> dict:
    return {
        "type": "message",
        "id": item_id,
        "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }


def response_events(item: dict, response_id: str) -> list[dict]:
    return [
        {"type": "response.output_item.done", "item": item},
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": 100,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": 10,
                    "total_tokens": 110,
                },
            },
        },
    ]


def events(request: RecordedRequest) -> list[dict]:
    model = request.body.get("model")
    if model == CHILD_MODEL:
        return response_events(
            message_item(CHILD_REPORT, "msg_terra_worker"),
            "resp_terra_worker",
        )
    if request.ordinal == 1:
        return response_events(
            {
                "type": "function_call",
                "id": "fc_shape_worker",
                "call_id": "call_shape_worker",
                "name": "subagent",
                "arguments": json.dumps({
                    "description": "terra worker",
                    "prompt": "Return the worker report exactly.",
                }),
                "status": "completed",
            },
            "resp_sol_delegate",
        )
    return response_events(
        message_item(FINAL_REPORT, "msg_sol_synthesis"),
        "resp_sol_synthesis",
    )


def main() -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-model-shape-") as tmp:
            root = Path(tmp)
            codex_home = root / "codex-home"
            codex_home.mkdir()
            (codex_home / "auth.json").write_text(json.dumps({
                "tokens": {
                    "access_token": "model-shape-mock",
                    "account_id": "acct-model-shape",
                },
            }), encoding="utf-8")
            (root / ".codegraff-codex-models.json").write_text(json.dumps({
                "client_version": "0.153.0",
                "fetched_at_ms": int(time.time() * 1000),
                "models": [
                    {"name": ROOT_MODEL, "context": 372000},
                    {"name": CHILD_MODEL, "context": 372000},
                ],
            }), encoding="utf-8")
            harness_dir = root / ".harness"
            harness_dir.mkdir()
            (harness_dir / "settings.json").write_text(json.dumps({
                "ai_title": False,
                "skills": {"codedbpro": False},
            }), encoding="utf-8")

            env = os.environ.copy()
            for name in tuple(env):
                if name.startswith("GRAFF_") or name.startswith("CODEX_"):
                    env.pop(name)
            env.update({
                "HOME": tmp,
                "CODEX_HOME": str(codex_home),
                "GRAFF_CODEX_URL": (
                    f"http://127.0.0.1:{port}/backend-api/codex/responses"
                ),
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_BEHAVIOR_TRACE": "off",
                "PATH": "/usr/bin:/bin",
            })
            completed = subprocess.run(
                [
                    GRAFF,
                    "--model", ROOT_MODEL,
                    "--subagent-model", "5.6-terra",
                    "--no-resume",
                    "--no-telemetry",
                    "-p", "Delegate once, then synthesize.",
                ],
                cwd=tmp,
                env=env,
                text=True,
                capture_output=True,
                timeout=20,
                check=False,
            )
            if completed.returncode != 0 or FINAL_REPORT not in completed.stdout:
                raise AssertionError(
                    f"shape run failed ({completed.returncode}): "
                    f"stdout={completed.stdout!r} stderr={completed.stderr!r}"
                )

            requests = mock.recorded_requests()
            models = [request.body.get("model") for request in requests]
            if models != [ROOT_MODEL, CHILD_MODEL, ROOT_MODEL]:
                raise AssertionError(f"wrong root/worker request shape: {models!r}")
            final_input = requests[-1].body.get("input")
            encoded = json.dumps(final_input, separators=(",", ":"))
            if CHILD_REPORT not in encoded:
                raise AssertionError("Sol synthesis did not receive the Terra report")

            trajectory_files = list(root.glob(".graff/trajectories/*.jsonl"))
            if len(trajectory_files) != 1:
                raise AssertionError(f"expected one trajectory: {trajectory_files!r}")
            records = [
                json.loads(line)
                for line in trajectory_files[0].read_text(encoding="utf-8").splitlines()
            ]
            children = [row for row in records if row.get("kind") == "subagent"]
            if len(children) != 1:
                raise AssertionError(f"missing child trajectory node: {children!r}")
            if (
                children[0].get("provider") != "codex"
                or children[0].get("model") != CHILD_MODEL
            ):
                raise AssertionError(f"child model evidence is wrong: {children[0]!r}")
    finally:
        mock.stop()

    print("ok    Sol root -> Terra subagent -> Sol synthesis, with model evidence")


if __name__ == "__main__":
    main()
