#!/usr/bin/env python3
"""Deterministic real-PTY tests for Codex transport and compaction.

The transport smokes cover WebSocket primary, forced SSE fallback, and
GRAFF_CODEX_WS=off. The regression scenarios cross compact@ in a tool loop,
read the pending results before compaction (ADR 0272), and prove successful
handoff or empty-summary rollback on a fresh WebSocket for the next turn.
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


# ADR 0016/0018: the standing line is `ctx N%` (optional ` · cache N%`). Used,
# window, and compact@ left that line. `/models health` still prints
# `active: … · {d}k ctx · compact@{d}k` — that is how smoke scenarios learn the
# runtime Codex window without freezing the catalog.
CTX_RE = re.compile(r"ctx (\d+)%")
ACTIVE_WINDOW_RE = re.compile(r"active: .+ · (\d+)k ctx · compact@(\d+)k")
# ADR 0020/0021: compacting ~N / compacted-to-a-summary are /debug-only.
# Crossing compact@ always writes this public #391 note.
PRE_COMPACT_NOTE_RE = re.compile(r"wrote a pre-compaction note to self")

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

CONCURRENT_FINAL = "done after concurrent websocket tool loop"

# #391: compaction now spends one extra quiet turn writing a note to self
# before the summary. Both synthetic turns are identified by the head of their
# instruction so the fixtures below can be keyed on CONTENT rather than on a
# request ordinal — see midturn_events for why that matters.
NOTE_INSTRUCTION_HEAD = "Your context is about to be compacted"
COMPACT_INSTRUCTION_HEAD = "Summarize this entire conversation"
NOTE_BLOCK_HEADER = "NOTES TO SELF"
MIDTURN_NOTE = (
    "SUBGOAL: exercise the server-side context meter\n"
    "ANCHORS: src/agent_compact.zig:130\n"
    "DEAD ENDS: none yet"
)
TRANSACTIONAL_NOTE = (
    "SUBGOAL: prove the transactional rollback\nANCHORS: src/agent_compact.zig:152"
)


def user_text(item: object) -> str | None:
    if not isinstance(item, dict) or item.get("role") != "user":
        return None
    content = item.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = [
            block.get("text")
            for block in content
            if isinstance(block, dict)
            and block.get("type") == "input_text"
            and isinstance(block.get("text"), str)
        ]
        if texts:
            return "".join(texts)
    return None


def last_user_text(request: RecordedRequest) -> str:
    """The final user turn of a Responses request, or "" — how the two
    synthetic compaction turns are told apart without counting ordinals."""
    for item in reversed(request.body.get("input") or []):
        text = user_text(item)
        if text is not None:
            return text
    return ""


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
    """Script tool call -> #391 note to self -> compaction summary -> answer.

    Keyed on the request's LAST USER TURN, not on its ordinal. Compaction
    gained a step in #391, and an ordinal-keyed fixture re-targets silently
    when that happens: the summary reply lands on the note turn, the note reply
    becomes the handoff summary, and the scenario still goes green while
    proving something else entirely. Content keying makes the fixture describe
    what each reply is FOR.
    """
    tail = last_user_text(request)
    if tail.startswith(NOTE_INSTRUCTION_HEAD):
        return response_events(
            message_item(MIDTURN_NOTE, "msg_midturn_note"),
            "resp_midturn_note",
            1_050,
        )
    if tail.startswith(COMPACT_INSTRUCTION_HEAD):
        return response_events(
            message_item(MIDTURN_SUMMARY, "msg_midturn_summary"),
            "resp_midturn_summary",
            1_100,
        )
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
    """Script tool call -> note to self -> EMPTY summary -> answer from the
    restored live history. Content-keyed for the same reason midturn_events is:
    the empty reply has to land on the SUMMARY request specifically, and an
    ordinal would have quietly moved it onto the #391 note turn instead."""
    tail = last_user_text(request)
    if tail.startswith(NOTE_INSTRUCTION_HEAD):
        return response_events(
            message_item(TRANSACTIONAL_NOTE, "msg_transactional_note"),
            "resp_transactional_note",
            1_050,
        )
    if tail.startswith(COMPACT_INSTRUCTION_HEAD):
        # A syntactically valid Responses answer with no summary text exercises
        # compact()'s EmptySummary rollback, rather than a transport failure.
        return response_events(
            message_item("", "msg_transactional_empty_summary"),
            "resp_transactional_empty_summary",
            1_100,
        )
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
    return response_events(
        message_item(TRANSACTIONAL_FINAL, "msg_transactional_final"),
        f"resp_transactional_{request.ordinal}",
        1_300,
    )


def concurrent_tool_events(request: RecordedRequest) -> list[dict]:
    """One native tool round-trip per independent WS connection.

    The second request on a chained connection contains only the new
    function_call_output, so key on that content instead of the mock's global
    ordinal: concurrent handlers may interleave in any order.
    """
    instructions = request.body.get("instructions", "")
    if "You summarize what a coding session is about" in instructions:
        return response_events(
            message_item("Concurrent websocket session", f"msg_title_{request.ordinal}"),
            f"resp_title_{request.ordinal}",
            200,
        )
    input_items = request.body.get("input") or []
    if any(
        isinstance(item, dict) and item.get("type") == "function_call_output"
        for item in input_items
    ):
        return response_events(
            message_item(CONCURRENT_FINAL, f"msg_concurrent_{request.ordinal}"),
            f"resp_concurrent_{request.ordinal}",
            1_300,
        )
    call = {
        "type": "function_call",
        "id": f"fc_concurrent_{request.ordinal}",
        "call_id": f"call_concurrent_{request.ordinal}",
        "name": "todo_read",
        "arguments": "{}",
        "status": "completed",
    }
    return response_events(call, f"resp_concurrent_{request.ordinal}", 1_200)


def assert_compaction_meter(label: str, rendered: str) -> None:
    """Public proof the server-reported usage crossed compact@.

    The token window itself is the request choreography in
    assert_midturn_requests / assert_transactional_requests (first-turn usage
    is MIDTURN_TOTAL_TOKENS, 90% of the runtime window). The debug bus line
    that used to print `compacting ~N tokens` is no longer on the transcript.
    """
    if PRE_COMPACT_NOTE_RE.search(rendered) is None:
        raise AssertionError(
            f"{label}: server-reported usage did not trigger pre-send "
            f"compaction (no pre-compaction note):\n{rendered}"
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
    # Cosmetic model calls (AI title, session recap) ride the same transport
    # and would shift every turn-count assertion below — the class of failure
    # mainloop_recap.zig's own comment warns about. Off for the whole file.
    harness_dir = os.path.join(tmp, ".harness")
    os.makedirs(harness_dir, exist_ok=True)
    with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "session_recap": False}, fh)
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "CODEGRAFF_API_KEY": "local-pty-test",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
        "GRAFF_SERVER_COMPACT": "0",  # Pin client-compaction regression flows.
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
        timeout=45.0,  # compaction legs stream 128 KiB of scripted reasoning; 20s flakes on loaded runners
    ) as session:
        session.wait_for_prompt()
        cursor = len(session.raw)
        session.send_line("ping")
        session.wait_for_literal(REPLY_TEXT, start=cursor)
        session.wait_for(CTX_RE, start=cursor)
        standing = terminal_text(bytes(session.raw[cursor:]))
        # WS streams deltas through the same printDelta hook as SSE; the
        # completed response must not surface the answer a second time.
        if standing.count(REPLY_TEXT) != 1:
            raise AssertionError(
                f"{label}: reply shown {standing.count(REPLY_TEXT)}x, expected once"
            )
        pct = int(CTX_RE.search(standing).group(1))
        if not 0 <= pct <= 100:
            raise AssertionError(f"{label}: invalid standing ctx percent {pct}")
        if mock.ws_turns != expect_ws or mock.sse_turns != expect_sse:
            raise AssertionError(
                f"{label}: transport mismatch — ws_turns={mock.ws_turns} "
                f"sse_turns={mock.sse_turns}, expected ws={expect_ws} sse={expect_sse}"
            )
        cursor = len(session.raw)
        session.send_line("/models health")
        session.wait_for_literal(f"Codex transport: {health}", start=cursor)
        session.wait_for(ACTIVE_WINDOW_RE, start=cursor)
        health_text = terminal_text(bytes(session.raw[cursor:]))
        window = ACTIVE_WINDOW_RE.search(health_text)
        ctx_k, compact_k = map(int, window.group(1, 2))
        if ctx_k <= 0 or not 79 * ctx_k <= 100 * compact_k <= 81 * ctx_k:
            raise AssertionError(
                f"{label}: inconsistent /models health context={ctx_k}k "
                f"compact@={compact_k}k"
            )
        session.wait_for_prompt(start=cursor)
        session.send_key("ctrl-d")
        result = session.read_until_exit(5.0)
        if result.timed_out or result.exit_code != 0:
            raise SystemExit(
                f"{label}: REPL did not exit cleanly: "
                f"exit={result.exit_code} timed_out={result.timed_out}"
            )
        return ctx_k * 1000


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
        "GRAFF_SERVER_COMPACT": "0",
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
        timeout=45.0,  # compaction legs stream 128 KiB of scripted reasoning; 20s flakes on loaded runners
    ) as session:
        session.wait_for_prompt()
        # ADR 0042 deliberately paints the prompt before the rest of boot; let
        # persisted title/recap settings land before transport counting starts.
        session.pump_for(0.5)
        cursor = len(session.raw)
        session.send_line(MIDTURN_PROMPT)
        session.wait_for_literal("wrote a pre-compaction note to self", start=cursor)
        session.wait_for_literal(MIDTURN_FINAL, start=cursor)
        session.pump_for(0.1)
        rendered = terminal_text(bytes(session.raw[cursor:]))
        assert_compaction_meter("midturn", rendered)
        session.wait_for_prompt(start=cursor)
        followup = len(session.raw)
        session.send_line("continue after the context handoff")
        session.wait_for_literal(MIDTURN_FINAL, start=followup)
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
        "GRAFF_SERVER_COMPACT": "0",
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
        timeout=45.0,  # compaction legs stream 128 KiB of scripted reasoning; 20s flakes on loaded runners
    ) as session:
        session.wait_for_prompt()
        session.pump_for(0.5)
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
        session.wait_for_prompt(start=cursor)
        # Inspect rollback after ONE empty summary, not #379's repeated-failure
        # escalation. Keep the next real turn below the automatic cut line.
        setting = len(session.raw)
        session.send_line("/compact-at 95")
        session.wait_for_prompt(start=setting)
        followup = len(session.raw)
        session.send_line("continue after the failed context handoff")
        session.wait_for_literal(TRANSACTIONAL_FINAL, start=followup)
        assert_transactional_requests(mock)
        session.send_key("ctrl-d")
        result = session.read_until_exit(5.0)
        if result.timed_out or result.exit_code != 0:
            raise SystemExit(
                "transactional: REPL did not exit cleanly: "
                f"exit={result.exit_code} timed_out={result.timed_out}"
            )


from codex_ws_assertions import assert_midturn_requests, assert_transactional_requests
