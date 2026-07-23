#!/usr/bin/env python3
"""Prove review turns are read-only, single-agent, and model-call bounded."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
FINAL_REPLY = "[P1] Example finding — target.txt:1"
BUDGET_REPLY = "No findings. Bounded review completed."


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


def tool(name: str, arguments: dict, ordinal: int) -> list[dict]:
    return response_events(
        {
            "type": "function_call",
            "id": f"fc_review_{ordinal}",
            "call_id": f"call_review_{ordinal}",
            "name": name,
            "arguments": json.dumps(arguments),
            "status": "completed",
        },
        f"resp_review_{ordinal}",
    )


def message(text: str, ordinal: int) -> list[dict]:
    return response_events(
        {
            "type": "message",
            "id": f"msg_review_{ordinal}",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text, "annotations": []}],
        },
        f"resp_review_{ordinal}",
    )


def review_events(request: RecordedRequest) -> list[dict]:
    cases = {
        1: ("edit_file", {"path": "target.txt", "old_string": "original", "new_string": "changed"}),
        2: ("workflow", {"phases": [{"title": "fanout", "tasks": [{"description": "edit", "prompt": "change it"}]}]}),
        3: ("bash", {"command": "touch should-not-exist"}),
        4: ("read_file", {"path": "target.txt"}),
    }
    if request.ordinal in cases:
        name, arguments = cases[request.ordinal]
        return tool(name, arguments, request.ordinal)
    return message(FINAL_REPLY, request.ordinal)


def loop_events(request: RecordedRequest) -> list[dict]:
    if not request.body.get("tools"):
        return message(BUDGET_REPLY, request.ordinal)
    return tool("read_file", {"path": "target.txt"}, request.ordinal)


def environment(tmp: str, port: int) -> dict[str, str]:
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home, exist_ok=True)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "review-mock", "account_id": "acct-review"}}, fh)
    harness_dir = os.path.join(tmp, ".harness")
    os.makedirs(harness_dir, exist_ok=True)
    with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)
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
    return env


def run_review(
    tmp: str, port: int, max_model_calls: int | None = None
) -> tuple[list[dict], subprocess.Popen[str]]:
    argv = [GRAFF, "--model", "codex", "--json", "--no-telemetry"]
    if max_model_calls is not None:
        argv.extend(["--max-model-calls", str(max_model_calls)])
    process = subprocess.Popen(
        argv,
        cwd=tmp,
        env=environment(tmp, port),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps({"type": "review", "text": "Review target.txt"}) + "\n")
    process.stdin.flush()
    events: list[dict] = []
    for line in process.stdout:
        event = json.loads(line)
        events.append(event)
        if event.get("type") in ("turn", "error"):
            break
    return events, process


def close(process: subprocess.Popen[str]) -> None:
    if process.stdin:
        process.stdin.close()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-review-mode-") as tmp:
        target = os.path.join(tmp, "target.txt")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("original")

        mock = CodexMock(events_for_request=review_events)
        port = mock.start()
        try:
            events, process = run_review(tmp, port)
            close(process)
        finally:
            mock.stop()

        rejected = [
            (event.get("name"), event.get("reason"))
            for event in events
            if event.get("type") == "tool_rejected"
        ]
        expected = [
            ("edit_file", "review_mode"),
            ("workflow", "review_mode"),
            ("bash", "review_mode"),
        ]
        if rejected != expected:
            raise AssertionError(f"wrong review rejections: {rejected!r}")
        if events[-1].get("type") != "turn" or events[-1].get("text") != FINAL_REPLY:
            raise AssertionError(f"review did not finish normally: {events[-1]!r}")
        with open(target, encoding="utf-8") as fh:
            if fh.read() != "original":
                raise AssertionError("review edited the target")
        if os.path.exists(os.path.join(tmp, "should-not-exist")):
            raise AssertionError("review ran a mutating shell command")
        if len(mock.recorded_requests()) != 5:
            raise AssertionError("review did not follow the expected bounded tool loop")

        budget_mock = CodexMock(events_for_request=loop_events)
        budget_port = budget_mock.start()
        try:
            budget_events, budget_process = run_review(tmp, budget_port)
            close(budget_process)
        finally:
            budget_mock.stop()
        calls = len(budget_mock.recorded_requests())
        if calls != 10:
            raise AssertionError(f"review model ceiling admitted {calls} calls")
        if budget_events[-1].get("type") != "turn" or budget_events[-1].get("text") != BUDGET_REPLY:
            raise AssertionError(f"review synthesis did not terminate: {budget_events[-1]!r}")

        global_mock = CodexMock(events_for_request=loop_events)
        global_port = global_mock.start()
        try:
            global_events, global_process = run_review(tmp, global_port, max_model_calls=3)
            close(global_process)
        finally:
            global_mock.stop()
        if len(global_mock.recorded_requests()) != 3:
            raise AssertionError("review did not reserve the final global-budget call")
        if global_events[-1].get("type") != "turn":
            raise AssertionError(f"global-budget synthesis failed: {global_events[-1]!r}")

    print("ok    review rejects mutation/delegation and reserves local/global synthesis")


if __name__ == "__main__":
    main()
