#!/usr/bin/env python3
"""Issue #692 interactive Codex WS error-frame regression scenarios."""

from __future__ import annotations

import json
import os
from pathlib import Path

from codex_ws_mock import CodexMock, RecordedRequest
import codex_ws_test as base

GENERIC_ERROR_CODE = "invalid_request_error"
GENERIC_ERROR_SECRET = "raw-envelope-secret-must-not-leak"
GENERIC_ERROR_TAIL = "generic-error-tail-must-be-truncated"
GENERIC_ERROR_MESSAGE = "mock bad request\r\n" + "x" * 500 + GENERIC_ERROR_TAIL
CHAIN_ERROR_CODE = "previous_response_not_found"
CHAIN_FINAL = "recovered after automatic websocket re-anchor"


def generic_error_events(_request: RecordedRequest) -> list[dict]:
    """One generic terminal error with raw envelope data that must not leak."""
    return [
        {
            "type": "error",
            "error": {
                "code": GENERIC_ERROR_CODE,
                "message": GENERIC_ERROR_MESSAGE,
            },
            "debug": {"authorization": GENERIC_ERROR_SECRET},
        }
    ]


def chain_error_events(request: RecordedRequest) -> list[dict]:
    """Tool call, stale chained delta, then success after a full-input redial."""
    if request.ordinal == 1:
        call = {
            "type": "function_call",
            "id": "fc_chain_1",
            "call_id": "call_chain_1",
            "name": "todo_read",
            "arguments": "{}",
            "status": "completed",
        }
        return base.response_events(call, "resp_chain_1", 1_200)
    if request.ordinal == 2:
        return [
            {
                "type": "error",
                "error": {
                    "code": CHAIN_ERROR_CODE,
                    "message": "Previous response resp_chain_1 was not found",
                },
            }
        ]
    return base.response_events(
        base.message_item(CHAIN_FINAL, "msg_chain_final"),
        "resp_chain_final",
        1_300,
    )


def _env(tmp: str, codex_home: str, port: int) -> tuple[dict[str, str], tuple[str, ...]]:
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "CODEGRAFF_API_KEY": "local-pty-test",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
        "GRAFF_SERVER_COMPACT": "0",
    }
    ambient = tuple(
        key
        for key in os.environ
        if (key.startswith("GRAFF_") or key.startswith("CODEX_") or key == "NO_COLOR")
        and key not in env
    )
    return env, ambient


def _new_trace(tmp: str, before: set[str]) -> list[dict]:
    trace_dir = Path(tmp, ".graff", "traces")
    created = sorted(path for path in trace_dir.iterdir() if path.name not in before)
    if len(created) != 1:
        raise AssertionError(f"expected one new trace, got {created!r}")
    return [json.loads(line) for line in created[0].read_text().splitlines() if line]


def _assert_ws_stays_primary(session: base.PtySession) -> None:
    cursor = len(session.raw)
    session.send_line("/models health")
    session.wait_for_literal(
        "Codex transport: WebSocket primary with automatic SSE fallback",
        start=cursor,
    )
    session.wait_for_prompt(start=cursor)


def _exit(session: base.PtySession, label: str) -> None:
    session.send_key("ctrl-d")
    result = session.read_until_exit(5.0)
    if result.timed_out or result.exit_code != 0:
        raise SystemExit(
            f"{label}: REPL did not exit cleanly: "
            f"exit={result.exit_code} timed_out={result.timed_out}"
        )


def run_generic_error_scenario(
    tmp: str, codex_home: str, port: int, mock: CodexMock
) -> None:
    """A deterministic API error returns once with bounded safe diagnostics."""
    env, ambient = _env(tmp, codex_home, port)
    trace_dir = Path(tmp, ".graff", "traces")
    before = {path.name for path in trace_dir.iterdir()} if trace_dir.is_dir() else set()
    with base.PtySession(
        base.GRAFF,
        ["--model", "codex", "--no-telemetry"],
        cwd=tmp,
        env=env,
        unset_env=ambient,
        timeout=20.0,
    ) as session:
        session.wait_for_prompt()
        cursor = len(session.raw)
        session.send_line("trigger the generic websocket rejection")
        expected = f"codex api error [{GENERIC_ERROR_CODE}]: mock bad request"
        session.wait_for_literal(expected, start=cursor)
        session.wait_for_prompt(start=cursor)
        rendered = base.terminal_text(bytes(session.raw[cursor:]))
        if GENERIC_ERROR_SECRET in rendered or GENERIC_ERROR_TAIL in rendered:
            raise AssertionError(f"generic-error: raw/unbounded diagnostics leaked:\n{rendered}")
        if mock.ws_turns != 1 or mock.sse_turns != 0 or mock.ws_connections != 1:
            raise AssertionError(
                "generic-error: deterministic body was retried/fallen back: "
                f"connections={mock.ws_connections} ws={mock.ws_turns} sse={mock.sse_turns}"
            )
        _assert_ws_stays_primary(session)
        _exit(session, "generic-error")

    events = _new_trace(tmp, before)
    diagnostics = [event for event in events if event.get("ev") == "ws_api_error"]
    if len(diagnostics) != 1:
        raise AssertionError(f"generic-error: expected one ws_api_error trace: {events!r}")
    detail = diagnostics[0].get("detail", "")
    if (
        GENERIC_ERROR_CODE not in detail
        or GENERIC_ERROR_SECRET in detail
        or GENERIC_ERROR_TAIL in detail
        or len(detail.encode("utf-8")) >= 560
    ):
        raise AssertionError(f"generic-error: unsafe trace diagnostic: {detail!r}")
    ws_details = [event.get("detail", "") for event in events if event.get("ev") == "ws"]
    if any("transport error" in detail or "fallback" in detail for detail in ws_details):
        raise AssertionError(f"generic-error: API response burned transport ladder: {ws_details!r}")


def run_chain_reanchor_scenario(
    tmp: str, codex_home: str, port: int, mock: CodexMock
) -> None:
    """A recognized stale chain rebuilds once without requiring `continue`."""
    env, ambient = _env(tmp, codex_home, port)
    with base.PtySession(
        base.GRAFF,
        ["--model", "codex", "--no-telemetry"],
        cwd=tmp,
        env=env,
        unset_env=ambient,
        timeout=20.0,
    ) as session:
        session.wait_for_prompt()
        cursor = len(session.raw)
        session.send_line("exercise automatic stale-chain recovery")
        session.wait_for_literal(CHAIN_FINAL, start=cursor)
        session.wait_for_prompt(start=cursor)
        requests = mock.recorded_requests()
        if mock.ws_turns != 3 or mock.sse_turns != 0 or mock.ws_connections != 2:
            raise AssertionError(
                "chain-error: expected delta rejection then one fresh WS rebuild: "
                f"connections={mock.ws_connections} ws={mock.ws_turns} sse={mock.sse_turns}"
            )
        if len(requests) != 3:
            raise AssertionError(f"chain-error: expected 3 requests, got {requests!r}")
        first, rejected, rebuilt = requests
        if (
            first.connection_id != rejected.connection_id
            or rejected.connection_id == rebuilt.connection_id
            or rejected.body.get("previous_response_id") != "resp_chain_1"
            or "previous_response_id" in rebuilt.body
        ):
            raise AssertionError(
                "chain-error: rejected delta was not rebuilt as full input on a fresh WS: "
                f"{requests!r}"
            )
        rebuilt_types = [
            item.get("type")
            for item in rebuilt.body.get("input", [])
            if isinstance(item, dict)
        ]
        if "function_call" not in rebuilt_types or "function_call_output" not in rebuilt_types:
            raise AssertionError(f"chain-error: full rebuild lost tool history: {rebuilt.body!r}")
        _assert_ws_stays_primary(session)
        _exit(session, "chain-error")
