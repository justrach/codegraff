#!/usr/bin/env python3
"""Prove review turns are isolated, read-only, and naturally terminating."""

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
LONG_REPLY = "No findings. Review completed after more than ten calls."
PARENT_REPLY = "Parent context acknowledged."
ISOLATED_REPLY = "No findings. Isolated review completed."


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


def long_review_events(request: RecordedRequest) -> list[dict]:
    if request.ordinal > 45:
        return message(LONG_REPLY, request.ordinal)
    return tool("read_file", {"path": "target.txt"}, request.ordinal)


def tool_budget_events(request: RecordedRequest) -> list[dict]:
    if request.ordinal <= 4:
        return tool("read_file", {"path": "target.txt"}, request.ordinal)
    return message("Explicit tool budget respected.", request.ordinal)


def loop_events(request: RecordedRequest) -> list[dict]:
    return tool("read_file", {"path": "target.txt"}, request.ordinal)


def isolation_events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        return message(PARENT_REPLY, request.ordinal)
    if request.ordinal == 2:
        return tool("read_file", {"path": "target.txt"}, request.ordinal)
    if request.ordinal == 3:
        return message(ISOLATED_REPLY, request.ordinal)
    return message("Follow-up complete.", request.ordinal)


def strict_eval_events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        return tool("eval", {"note": "establish a failing parent verifier"}, request.ordinal)
    return tool("attempt_completion", {"result": "Strict review complete."}, request.ordinal)


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


def start_graff(
    tmp: str,
    port: int,
    max_model_calls: int | None = None,
    extra_args: list[str] | None = None,
) -> subprocess.Popen[str]:
    argv = [GRAFF, "--model", "codex", "--json", "--no-telemetry"]
    if max_model_calls is not None:
        argv.extend(["--max-model-calls", str(max_model_calls)])
    if extra_args:
        argv.extend(extra_args)
    return subprocess.Popen(
        argv,
        cwd=tmp,
        env=environment(tmp, port),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )


def send(process: subprocess.Popen[str], payload: dict) -> list[dict]:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()
    events: list[dict] = []
    for line in process.stdout:
        event = json.loads(line)
        events.append(event)
        if event.get("type") in ("turn", "error"):
            break
    return events


def run_review(
    tmp: str, port: int, max_model_calls: int | None = None
) -> tuple[list[dict], subprocess.Popen[str]]:
    process = start_graff(tmp, port, max_model_calls)
    return send(process, {"type": "review", "text": "Review target.txt"}), process


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
            raise AssertionError("review did not follow the expected policy tool loop")

        long_mock = CodexMock(events_for_request=long_review_events)
        long_port = long_mock.start()
        try:
            long_events, long_process = run_review(tmp, long_port)
            close(long_process)
        finally:
            long_mock.stop()
        calls = len(long_mock.recorded_requests())
        if calls != 46:
            raise AssertionError(f"default review unexpectedly stopped after {calls} calls")
        if long_events[-1].get("type") != "turn" or long_events[-1].get("text") != LONG_REPLY:
            raise AssertionError(f"long review did not terminate naturally: {long_events[-1]!r}")

        global_mock = CodexMock(events_for_request=loop_events)
        global_port = global_mock.start()
        try:
            global_events, global_process = run_review(tmp, global_port, max_model_calls=3)
            close(global_process)
        finally:
            global_mock.stop()
        if len(global_mock.recorded_requests()) != 3:
            raise AssertionError("explicit global model-call budget was not enforced")
        if global_events[-1].get("type") != "error":
            raise AssertionError(f"global-budget exhaustion was not surfaced: {global_events[-1]!r}")

        tool_budget_mock = CodexMock(events_for_request=tool_budget_events)
        tool_budget_port = tool_budget_mock.start()
        tool_budget_process = start_graff(tmp, tool_budget_port)
        try:
            tool_budget_events_seen = send(
                tool_budget_process,
                {
                    "type": "review",
                    "text": "Review target.txt",
                    "maxToolCalls": 3,
                },
            )
            close(tool_budget_process)
        finally:
            tool_budget_mock.stop()
        budget_rejections = [
            event
            for event in tool_budget_events_seen
            if event.get("type") == "tool_rejected"
            and event.get("reason") == "budget"
        ]
        if len(budget_rejections) != 1:
            raise AssertionError(
                f"explicit tool budget was not enforced once: {budget_rejections!r}"
            )
        if (
            tool_budget_events_seen[-1].get("type") != "turn"
            or tool_budget_events_seen[-1].get("text")
            != "Explicit tool budget respected."
        ):
            raise AssertionError(
                f"review did not recover from explicit tool budget: {tool_budget_events_seen[-1]!r}"
            )

        isolation_mock = CodexMock(events_for_request=isolation_events)
        isolation_port = isolation_mock.start()
        isolation_process = start_graff(tmp, isolation_port)
        try:
            send(isolation_process, {"type": "user", "text": "PARENT_SENTINEL"})
            send(isolation_process, {"type": "review", "text": "Review target.txt"})
            send(isolation_process, {"type": "user", "text": "FOLLOWUP_SENTINEL"})
            close(isolation_process)
        finally:
            isolation_mock.stop()
        requests = isolation_mock.recorded_requests()
        review_input = json.dumps(requests[1].body.get("input"))
        if "PARENT_SENTINEL" in review_input or PARENT_REPLY in review_input:
            raise AssertionError("review inherited the parent model-visible history")
        if "[review task:" not in requests[1].body.get("instructions", ""):
            raise AssertionError("review rubric was not installed as base instructions")
        followup_input = json.dumps(requests[3].body.get("input"))
        for expected_text in ("PARENT_SENTINEL", PARENT_REPLY, "Review target.txt", ISOLATED_REPLY):
            if expected_text not in followup_input:
                raise AssertionError(f"parent transcript lost {expected_text!r}")
        if "function_call" in followup_input or "call_review_2" in followup_input:
            raise AssertionError("review-internal tool history leaked into the parent transcript")
        if "[review task:" in requests[3].body.get("instructions", ""):
            raise AssertionError("review system prompt leaked into the parent follow-up")

        sessions = os.path.join(tmp, ".graff", "sessions")
        os.makedirs(sessions, exist_ok=True)
        with open(
            os.path.join(sessions, "strict-eval.session.json"),
            "w",
            encoding="utf-8",
        ) as fh:
            json.dump(
                {
                    "provider": "codex",
                    "model": "gpt-5.6-sol",
                    "strict": True,
                    "messages": [],
                },
                fh,
            )
        strict_mock = CodexMock(events_for_request=strict_eval_events)
        strict_port = strict_mock.start()
        strict_process = start_graff(
            tmp,
            strict_port,
            max_model_calls=2,
            extra_args=["--eval", "false", "--resume", "strict-eval"],
        )
        try:
            parent_eval_events = send(
                strict_process, {"type": "user", "text": "Establish failing eval state"}
            )
            if (
                parent_eval_events[-1].get("type") != "turn"
                or parent_eval_events[-1].get("complete") is not False
            ):
                raise AssertionError(
                    f"parent eval did not enter repair-pending state: {parent_eval_events[-1]!r}"
                )
            strict_events = send(
                strict_process, {"type": "review", "text": "Review target.txt"}
            )
            close(strict_process)
        finally:
            strict_mock.stop()
        if len(strict_mock.recorded_requests()) != 2:
            raise AssertionError("strict/eval review did not finish in one additional model call")
        instructions = strict_mock.recorded_requests()[1].body.get("instructions", "")
        if "STRICT MODE:" in instructions:
            raise AssertionError("review inherited the parent strict system note")
        if (
            strict_events[-1].get("type") != "turn"
            or strict_events[-1].get("text") != "Strict review complete."
            or strict_events[-1].get("complete") is not True
        ):
            raise AssertionError(
                f"parent eval gate blocked review finalization: {strict_events[-1]!r}"
            )

    print("ok    review is isolated/read-only, admits >40 tools, and honors opt-in budgets")


if __name__ == "__main__":
    main()
