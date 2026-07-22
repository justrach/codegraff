#!/usr/bin/env python3
"""Deterministic real-PTY tests for Codex transport and mid-turn compaction.

The transport smokes cover WebSocket primary, forced SSE fallback, and
GRAFF_CODEX_WS=off. The regression scenarios drive real tool loops whose
server-reported usage crosses compact@ while local history stays tiny. They
prove both successful compaction and transactional rollback after an empty
summary across WS -> quiet SSE compaction -> fresh WS.
"""

import json
import os
import re
import sys
import tempfile

from codex_ws_mock import REPLY_TEXT, CodexMock, RecordedRequest
from pty_harness import PtySession, terminal_text

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


# The reported 1500-token usage is conservatively floored by graff's serialized
# request estimate, so the displayed used count can move with the built-in tool
# schema. Assert the meter shape and invariants rather than freezing either the
# prefill estimate or the Codex catalog window.
METER_RE = re.compile(r"(\d+)(k?)/(\d+)k ctx \((\d+)% · compact@(\d+)k\)")
COMPACTING_RE = re.compile(r"compacting ~(\d+) tokens")

MIDTURN_PROMPT = "exercise the server-side context meter"
MIDTURN_SUMMARY = "The user asked to exercise the server-side context meter."
MIDTURN_FINAL = "done after mid-turn compact"
# Cross compact@ (80%) but stay below the destructive recovery boundary (95%).
# The smoke scenarios set this from the context meter emitted after the runtime
# Codex catalog has loaded, rather than the static --schema catalog.
MIDTURN_TOTAL_TOKENS = 0
MIDTURN_CONTEXT_TOKENS = 0
MIDTURN_REASONING_MARKER = "retained-active-reasoning:"
MIDTURN_REASONING_BYTES = 128 * 1024

TRANSACTIONAL_PROMPT = "prove failed compaction keeps the live tool loop"
TRANSACTIONAL_FINAL = "done after transactional compaction failure"
TRANSACTIONAL_REASONING_MARKER = "transactional-active-reasoning:"
TRANSACTIONAL_CALL_ID = "call_transactional_1"


def response_events(
    item: dict | list[dict], response_id: str, total_tokens: int
) -> list[dict]:
    """Build the two Responses events parseResponses consumes."""
    output_tokens = 1_000 if total_tokens > 2_000 else 100
    items = item if isinstance(item, list) else [item]
    return [
        *(
            {"type": "response.output_item.done", "item": output_item}
            for output_item in items
        ),
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": total_tokens - output_tokens,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": output_tokens,
                    "total_tokens": total_tokens,
                },
            },
        },
    ]


def message_item(text: str, item_id: str) -> dict:
    return {
        "type": "message",
        "id": item_id,
        "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }


def active_reasoning_item() -> dict:
    """A large current-loop item that compact() must prune before full resend."""
    encrypted = MIDTURN_REASONING_MARKER + "R" * (
        MIDTURN_REASONING_BYTES - len(MIDTURN_REASONING_MARKER)
    )
    return {
        "type": "reasoning",
        "id": "rs_midturn_1",
        "summary": [],
        "encrypted_content": encrypted,
    }


def midturn_events(request: RecordedRequest) -> list[dict]:
    """Script tool call -> compaction summary -> final answer."""
    if request.ordinal == 1:
        item = {
            "type": "function_call",
            "id": "fc_midturn_1",
            "call_id": "call_midturn_1",
            "name": "todo_read",
            "arguments": "{}",
            "status": "completed",
        }
        # Real high-effort Responses tool loops return reasoning immediately
        # before the function call. It is current-turn history here, but once
        # compact() appends its synthetic user turn it must be pruned before the
        # full SSE summary resend.
        return response_events(
            [active_reasoning_item(), item],
            "resp_midturn_1",
            MIDTURN_TOTAL_TOKENS,
        )
    if request.ordinal == 2:
        return response_events(
            message_item(MIDTURN_SUMMARY, "msg_midturn_summary"),
            "resp_midturn_summary",
            1_100,
        )
    return response_events(
        message_item(MIDTURN_FINAL, "msg_midturn_final"),
        f"resp_midturn_{request.ordinal}",
        1_300,
    )


def transactional_reasoning_item() -> dict:
    encrypted = TRANSACTIONAL_REASONING_MARKER + "R" * (
        MIDTURN_REASONING_BYTES - len(TRANSACTIONAL_REASONING_MARKER)
    )
    return {
        "type": "reasoning",
        "id": "rs_transactional_1",
        "summary": [],
        "encrypted_content": encrypted,
    }


def transactional_events(request: RecordedRequest) -> list[dict]:
    """Script tool call -> empty summary -> answer from restored live history."""
    if request.ordinal == 1:
        call = {
            "type": "function_call",
            "id": "fc_transactional_1",
            "call_id": TRANSACTIONAL_CALL_ID,
            "name": "todo_read",
            "arguments": "{}",
            "status": "completed",
        }
        return response_events(
            [transactional_reasoning_item(), call],
            "resp_transactional_1",
            MIDTURN_TOTAL_TOKENS,
        )
    if request.ordinal == 2:
        # A syntactically valid Responses answer with no summary text exercises
        # compact()'s EmptySummary rollback, rather than a transport failure.
        return response_events(
            message_item("", "msg_transactional_empty_summary"),
            "resp_transactional_empty_summary",
            1_100,
        )
    return response_events(
        message_item(TRANSACTIONAL_FINAL, "msg_transactional_final"),
        f"resp_transactional_{request.ordinal}",
        1_300,
    )


def user_text(item: object) -> str | None:
    if not isinstance(item, dict) or item.get("role") != "user":
        return None
    content = item.get("content")
    return content if isinstance(content, str) else None


def assert_compaction_meter(label: str, rendered: str) -> None:
    match = COMPACTING_RE.search(rendered)
    if match is None:
        raise AssertionError(
            f"{label}: server-reported usage did not trigger pre-send "
            f"compaction:\n{rendered}"
        )
    observed = int(match.group(1))
    # The provider sample is the lower bound. A tool result appended after that
    # sample should increase the anchored effective meter slightly, while the
    # compaction still runs before the advertised context wall.
    if not MIDTURN_TOTAL_TOKENS <= observed < MIDTURN_CONTEXT_TOKENS:
        raise AssertionError(
            f"{label}: compacted at {observed} tokens, expected at least the "
            f"{MIDTURN_TOTAL_TOKENS} provider sample and below the "
            f"{MIDTURN_CONTEXT_TOKENS} context window"
        )


def run_scenario(
    label: str,
    tmp: str,
    codex_home: str,
    port: int,
    mock: CodexMock,
    extra_env: dict,
    expect_ws: int,
    expect_sse: int,
    health: str,
) -> int:
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "CODEGRAFF_API_KEY": "local-pty-test",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
    }
    env.update(extra_env)
    # PtySession builds the child env from os.environ.copy(), so ambient
    # transport/credential knobs (an exported GRAFF_CODEX_WS=off, a leftover
    # GRAFF_WS_FORCE_FAIL_ONCE=1, CODEX_DISABLED, ...) would leak into every
    # scenario and flip its transport. Strip all ambient GRAFF_*/CODEX_* the
    # scenario does not set itself; unset_env is applied AFTER env, so keys we
    # set deliberately must be excluded.
    ambient = tuple(
        k
        for k in os.environ
        if (k.startswith("GRAFF_") or k.startswith("CODEX_") or k == "NO_COLOR")
        and k not in env
    )
    with PtySession(
        GRAFF,
        ["--model", "codex", "--no-telemetry"],
        cwd=tmp,
        env=env,
        unset_env=ambient,
        timeout=20.0,
    ) as session:
        session.wait_for_literal("] ›")
        cursor = len(session.raw)
        session.send_line("ping")
        session.wait_for_literal(REPLY_TEXT, start=cursor)
        session.wait_for(METER_RE, start=cursor)
        meter = METER_RE.search(terminal_text(bytes(session.raw[cursor:])))
        used = int(meter.group(1)) * (1000 if meter.group(2) == "k" else 1)
        ctx_k, pct, compact_k = map(int, meter.group(3, 4, 5))
        if used <= 0 or not 0 <= pct <= 100:
            raise AssertionError(
                f"{label}: invalid context meter values used={used} pct={pct}"
            )
        if ctx_k <= 0 or not 79 * ctx_k <= 100 * compact_k <= 81 * ctx_k:
            raise AssertionError(
                f"{label}: inconsistent meter context={ctx_k}k compact@={compact_k}k"
            )
        if mock.ws_turns != expect_ws or mock.sse_turns != expect_sse:
            raise AssertionError(
                f"{label}: transport mismatch — ws_turns={mock.ws_turns} "
                f"sse_turns={mock.sse_turns}, expected ws={expect_ws} sse={expect_sse}"
            )
        cursor = len(session.raw)
        session.send_line("/models health")
        session.wait_for_literal(f"Codex transport: {health}", start=cursor)
        session.wait_for_literal("] ›", start=cursor)
        session.send_key("ctrl-d")
        result = session.read_until_exit(5.0)
        if result.timed_out or result.exit_code != 0:
            raise SystemExit(
                f"{label}: REPL did not exit cleanly: "
                f"exit={result.exit_code} timed_out={result.timed_out}"
            )
        return ctx_k * 1000


def assert_midturn_requests(mock: CodexMock) -> None:
    requests = mock.recorded_requests()
    if len(requests) != 3:
        raise AssertionError(
            f"midturn: expected exactly 3 model requests, got {len(requests)}: {requests!r}"
        )
    first, compact, final = requests
    if any("max_output_tokens" in request.body for request in requests):
        raise AssertionError("midturn: Responses requests must omit max_output_tokens")
    transports = [request.transport for request in requests]
    if transports != ["ws", "sse", "ws"]:
        raise AssertionError(f"midturn: expected WS -> SSE -> WS, got {transports!r}")
    if mock.ws_turns != 2 or mock.sse_turns != 1 or mock.ws_connections != 2:
        raise AssertionError(
            "midturn: expected two turns on two fresh WS connections plus one SSE "
            f"turn; ws_turns={mock.ws_turns} sse_turns={mock.sse_turns} "
            f"ws_connections={mock.ws_connections}"
        )
    if first.connection_id == final.connection_id:
        raise AssertionError("midturn: final request reused the pre-compaction WS")
    for request in requests:
        if "previous_response_id" in request.body:
            raise AssertionError(
                f"midturn: request {request.ordinal} carried stale previous_response_id: "
                f"{request.body['previous_response_id']!r}"
            )

    first_input = first.body.get("input")
    if (
        first.body.get("type") != "response.create"
        or not isinstance(first_input, list)
        or not any(user_text(item) == MIDTURN_PROMPT for item in first_input)
        or "tools" not in first.body
    ):
        raise AssertionError(
            f"midturn: first WS request was not full tool-enabled input: {first.body!r}"
        )

    compact_input = compact.body.get("input")
    compact_texts = (
        [text for item in compact_input if (text := user_text(item)) is not None]
        if isinstance(compact_input, list)
        else []
    )
    compact_types = (
        [item.get("type") for item in compact_input if isinstance(item, dict)]
        if isinstance(compact_input, list)
        else []
    )
    compact_json = json.dumps(compact.body, separators=(",", ":"))
    if "reasoning" in compact_types or MIDTURN_REASONING_MARKER in compact_json:
        raise AssertionError(
            "midturn: SSE compaction request retained the active-loop reasoning item"
        )
    if (
        compact.connection_id is not None
        or "tools" in compact.body
        or MIDTURN_PROMPT not in compact_texts
        or "function_call" not in compact_types
        or "function_call_output" not in compact_types
        or not any(
            text.startswith("Summarize this entire conversation")
            for text in compact_texts
        )
    ):
        raise AssertionError(
            f"midturn: compaction request was not a full, tool-free SSE summary request: {compact.body!r}"
        )

    final_input = final.body.get("input")
    final_texts = (
        [text for item in final_input if (text := user_text(item)) is not None]
        if isinstance(final_input, list)
        else []
    )
    if (
        final.body.get("type") != "response.create"
        or not isinstance(final_input, list)
        or len(final_input) != 1
        or len(final_texts) != 1
        or not final_texts[0].startswith(
            "Context: the earlier conversation was compacted"
        )
        or MIDTURN_SUMMARY not in final_texts[0]
        or "tools" not in final.body
    ):
        raise AssertionError(
            "midturn: final WS request did not fully re-anchor on the handoff: "
            f"{final.body!r}"
        )


def assert_transactional_requests(mock: CodexMock) -> None:
    requests = mock.recorded_requests()
    if len(requests) != 3:
        raise AssertionError(
            "transactional: expected exactly 3 model requests, "
            f"got {len(requests)}: {requests!r}"
        )
    first, compact, final = requests
    if any("max_output_tokens" in request.body for request in requests):
        raise AssertionError("transactional: Responses requests must omit max_output_tokens")
    transports = [request.transport for request in requests]
    if transports != ["ws", "sse", "ws"]:
        raise AssertionError(
            f"transactional: expected WS -> SSE -> WS, got {transports!r}"
        )
    if mock.ws_turns != 2 or mock.sse_turns != 1 or mock.ws_connections != 2:
        raise AssertionError(
            "transactional: expected two turns on two fresh WS connections plus "
            f"one SSE turn; ws_turns={mock.ws_turns} sse_turns={mock.sse_turns} "
            f"ws_connections={mock.ws_connections}"
        )
    if first.connection_id == final.connection_id:
        raise AssertionError(
            "transactional: final request reused the pre-compaction WS"
        )
    for request in requests:
        if "previous_response_id" in request.body:
            raise AssertionError(
                f"transactional: request {request.ordinal} carried stale "
                f"previous_response_id: {request.body['previous_response_id']!r}"
            )

    first_input = first.body.get("input")
    if (
        first.body.get("type") != "response.create"
        or not isinstance(first_input, list)
        or not any(user_text(item) == TRANSACTIONAL_PROMPT for item in first_input)
        or "tools" not in first.body
    ):
        raise AssertionError(
            "transactional: first WS request was not full tool-enabled input: "
            f"{first.body!r}"
        )

    compact_input = compact.body.get("input")
    compact_texts = (
        [text for item in compact_input if (text := user_text(item)) is not None]
        if isinstance(compact_input, list)
        else []
    )
    compact_json = json.dumps(compact.body, separators=(",", ":"))
    if (
        compact.connection_id is not None
        or "tools" in compact.body
        or TRANSACTIONAL_PROMPT not in compact_texts
        or TRANSACTIONAL_REASONING_MARKER in compact_json
        or not any(
            text.startswith("Summarize this entire conversation")
            for text in compact_texts
        )
    ):
        raise AssertionError(
            "transactional: second request was not the pruned, synthetic SSE "
            f"summary request: {compact.body!r}"
        )

    final_input = final.body.get("input")
    final_texts = (
        [text for item in final_input if (text := user_text(item)) is not None]
        if isinstance(final_input, list)
        else []
    )
    final_objects = (
        [item for item in final_input if isinstance(item, dict)]
        if isinstance(final_input, list)
        else []
    )
    reasoning = [
        item
        for item in final_objects
        if item.get("type") == "reasoning" and item.get("id") == "rs_transactional_1"
    ]
    calls = [
        item
        for item in final_objects
        if item.get("type") == "function_call"
        and item.get("id") == "fc_transactional_1"
        and item.get("call_id") == TRANSACTIONAL_CALL_ID
    ]
    outputs = [
        item
        for item in final_objects
        if item.get("type") == "function_call_output"
        and item.get("call_id") == TRANSACTIONAL_CALL_ID
        and isinstance(item.get("output"), str)
        and len(item["output"]) > 0
    ]
    leaked_summary_response = any(
        item.get("id") == "msg_transactional_empty_summary" for item in final_objects
    )
    if (
        final.body.get("type") != "response.create"
        or not isinstance(final_input, list)
        or "tools" not in final.body
        or TRANSACTIONAL_PROMPT not in final_texts
        or any(
            text.startswith("Summarize this entire conversation")
            for text in final_texts
        )
        or not any(
            isinstance(item.get("encrypted_content"), str)
            and item["encrypted_content"].startswith(TRANSACTIONAL_REASONING_MARKER)
            and len(item["encrypted_content"]) == MIDTURN_REASONING_BYTES
            for item in reasoning
        )
        or len(calls) != 1
        or len(outputs) != 1
        or leaked_summary_response
    ):
        raise AssertionError(
            "transactional: final WS request did not restore the original prompt, "
            "reasoning, function call, and output without the synthetic compact "
            f"instruction: {final.body!r}"
        )


def run_midturn_compaction_scenario(
    tmp: str, codex_home: str, port: int, mock: CodexMock
) -> None:
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "CODEGRAFF_API_KEY": "local-pty-test",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
    }
    ambient = tuple(
        key
        for key in os.environ
        if (key.startswith("GRAFF_") or key.startswith("CODEX_") or key == "NO_COLOR")
        and key not in env
    )
    with PtySession(
        GRAFF,
        ["--model", "codex", "--no-telemetry"],
        cwd=tmp,
        env=env,
        unset_env=ambient,
        timeout=20.0,
    ) as session:
        session.wait_for_literal("] ›")
        cursor = len(session.raw)
        session.send_line(MIDTURN_PROMPT)
        session.wait_for_literal(MIDTURN_FINAL, start=cursor)
        session.wait_for_literal("history compacted to a", start=cursor)
        session.pump_for(0.1)
        rendered = terminal_text(bytes(session.raw[cursor:]))
        assert_compaction_meter("midturn", rendered)
        assert_midturn_requests(mock)
        session.send_key("ctrl-d")
        result = session.read_until_exit(5.0)
        if result.timed_out or result.exit_code != 0:
            raise SystemExit(
                "midturn: REPL did not exit cleanly: "
                f"exit={result.exit_code} timed_out={result.timed_out}"
            )


def run_transactional_compaction_scenario(
    tmp: str, codex_home: str, port: int, mock: CodexMock
) -> None:
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "CODEGRAFF_API_KEY": "local-pty-test",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
    }
    ambient = tuple(
        key
        for key in os.environ
        if (key.startswith("GRAFF_") or key.startswith("CODEX_") or key == "NO_COLOR")
        and key not in env
    )
    with PtySession(
        GRAFF,
        ["--model", "codex", "--no-telemetry"],
        cwd=tmp,
        env=env,
        unset_env=ambient,
        timeout=20.0,
    ) as session:
        session.wait_for_literal("] ›")
        cursor = len(session.raw)
        session.send_line(TRANSACTIONAL_PROMPT)
        session.wait_for_literal(
            "compaction failed: empty summary, history unchanged", start=cursor
        )
        session.wait_for_literal(TRANSACTIONAL_FINAL, start=cursor)
        session.pump_for(0.1)
        rendered = terminal_text(bytes(session.raw[cursor:]))
        assert_compaction_meter("transactional", rendered)
        if "history compacted to a" in rendered:
            raise AssertionError(
                f"transactional: empty summary was incorrectly installed:\n{rendered}"
            )
        assert_transactional_requests(mock)
        session.send_key("ctrl-d")
        result = session.read_until_exit(5.0)
        if result.timed_out or result.exit_code != 0:
            raise SystemExit(
                "transactional: REPL did not exit cleanly: "
                f"exit={result.exit_code} timed_out={result.timed_out}"
            )


def main() -> None:
    global MIDTURN_CONTEXT_TOKENS, MIDTURN_TOTAL_TOKENS

    with tempfile.TemporaryDirectory(prefix="graff-pty-codex-") as tmp:
        codex_home = os.path.join(tmp, "codex-home")
        os.makedirs(codex_home, exist_ok=True)
        with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "tokens": {
                        "access_token": "pty-mock-token",
                        "account_id": "acct-pty-mock",
                    }
                },
                fh,
            )

        # The AI tab-titler (titleTask, src/title.zig) fires one extra quiet SSE
        # turn on the first prompt, which would corrupt the transport counters.
        # Disable it the same way `/title off` does: the persisted setting in
        # the session cwd's .harness/settings.json.
        harness_dir = os.path.join(tmp, ".harness")
        os.makedirs(harness_dir, exist_ok=True)
        with open(
            os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8"
        ) as fh:
            json.dump({"ai_title": False}, fh)

        scenarios = [
            (
                "ws-primary",
                {},
                1,
                0,
                "WebSocket primary with automatic SSE fallback",
                "ok    codex WS primary: mock reply + ctx meter over WebSocket",
            ),
            (
                "ws-clean-retry",
                {"GRAFF_WS_FORCE_FAIL_ONCE": "1"},
                1,
                0,
                "WebSocket primary with automatic SSE fallback",
                "ok    codex first WS failure: clean WS retry succeeded without latching fallback",
            ),
            (
                "ws-forced-fallback",
                {"GRAFF_WS_FORCE_FAIL_COUNT": "2"},
                0,
                1,
                "SSE fallback (WebSocket failed this session)",
                "ok    codex second WS failure: persistent SSE fallback reply + latched health",
            ),
            (
                "ws-off",
                {"GRAFF_CODEX_WS": "off"},
                0,
                1,
                "SSE forced (GRAFF_CODEX_WS is off)",
                "ok    codex WS disabled: SSE reply + ctx meter + forced-off health",
            ),
        ]
        runtime_context = None
        for label, extra_env, expect_ws, expect_sse, health, ok_line in scenarios:
            mock = CodexMock()
            port = mock.start()
            try:
                observed_context = run_scenario(
                    label,
                    tmp,
                    codex_home,
                    port,
                    mock,
                    extra_env,
                    expect_ws,
                    expect_sse,
                    health,
                )
            finally:
                mock.stop()
            if runtime_context is not None and observed_context != runtime_context:
                raise AssertionError(
                    f"{label}: runtime context changed from {runtime_context} "
                    f"to {observed_context} across smoke scenarios"
                )
            runtime_context = observed_context
            print(ok_line)

        if runtime_context is None:
            raise AssertionError("no smoke scenario reported a runtime context")
        MIDTURN_CONTEXT_TOKENS = runtime_context
        MIDTURN_TOTAL_TOKENS = runtime_context * 9 // 10

        mock = CodexMock(events_for_request=midturn_events)
        port = mock.start()
        try:
            run_midturn_compaction_scenario(tmp, codex_home, port, mock)
        finally:
            mock.stop()
        print(
            "ok    codex server meter + reasoning prune: WS tool call -> "
            "SSE compaction -> fresh full-input WS"
        )

        mock = CodexMock(events_for_request=transactional_events)
        port = mock.start()
        try:
            run_transactional_compaction_scenario(tmp, codex_home, port, mock)
        finally:
            mock.stop()
        print(
            "ok    empty mid-turn summary: transactional rollback -> "
            "fresh full-input WS"
        )


if __name__ == "__main__":
    main()
