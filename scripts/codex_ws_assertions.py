"""Wire assertions for the compaction transport fixtures."""

import json

from codex_ws_mock import CodexMock
from codex_ws_test import (
    MIDTURN_PROMPT, MIDTURN_SUMMARY, MIDTURN_NOTE, MIDTURN_REASONING_MARKER,
    NOTE_BLOCK_HEADER, NOTE_INSTRUCTION_HEAD, TRANSACTIONAL_PROMPT,
    TRANSACTIONAL_CALL_ID, TRANSACTIONAL_REASONING_MARKER,
    user_text, last_user_text,
)


def assert_read_before_compact(first, read):
    """The unread output must reach the model before any summarizer sees it."""
    outputs = [item for item in read.body.get("input", [])
               if isinstance(item, dict) and item.get("type") == "function_call_output"]
    if read.connection_id != first.connection_id or len(outputs) != 1:
        raise AssertionError("the tool result was not read on the live chain before compaction")


def is_repo_context(item: object) -> bool:
    """ADR 0243's developer item: the repo's instructions section and layout."""
    if not (isinstance(item, dict) and item.get("role") == "developer"):
        return False
    content = item.get("content")
    first = content[0] if isinstance(content, list) and content else None
    text = first.get("text", "") if isinstance(first, dict) else ""
    return isinstance(text, str) and text.startswith(("# Project instructions (from ", "# Project layout ("))


def assert_midturn_requests(mock: CodexMock) -> None:
    requests = mock.recorded_requests()
    # ADR 0272 consumes unread results before the #391 note and summary.
    # Five requests: tool call, read its result, note, summary, then a real
    # follow-up re-anchored on the handoff. The initial server meter is 90%:
    # a planned rollover rather than destructive near-window recovery.
    if len(requests) != 5:
        raise AssertionError(
            f"midturn: expected exactly 5 model requests, got {len(requests)}: {requests!r}"
        )
    first, read, note, compact, final = requests
    if any("max_output_tokens" in request.body for request in requests):
        raise AssertionError("midturn: Responses requests must omit max_output_tokens")
    transports = [request.transport for request in requests]
    if transports != ["ws", "ws", "sse", "sse", "ws"]:
        raise AssertionError(
            f"midturn: expected WS -> WS(read results) -> SSE(note) -> SSE(summary) -> WS, got {transports!r}"
        )
    if mock.ws_turns != 3 or mock.sse_turns != 2 or mock.ws_connections != 2:
        raise AssertionError(
            "midturn: expected three turns on two fresh WS connections plus two quiet "
            f"SSE turns; ws_turns={mock.ws_turns} sse_turns={mock.sse_turns} "
            f"ws_connections={mock.ws_connections}"
        )
    # The two synthetic turns are identified by CONTENT, not position, so this
    # cannot silently pass if their order ever swaps.
    if not last_user_text(note).startswith("Your context is about to be compacted"):
        shapes = [
            (
                request.transport,
                last_user_text(request)[:80],
                str(request.body.get("instructions", ""))[:80],
            )
            for request in requests
        ]
        raise AssertionError(f"midturn: request 3 is not the #391 note turn: {shapes!r}")
    if not last_user_text(compact).startswith("Summarize this entire conversation"):
        raise AssertionError(
            f"midturn: request 4 is not the compaction summary: {last_user_text(compact)[:120]!r}"
        )
    # #195's invariant, checked rather than assumed: the note turn is a quiet
    # SSE request that opens NO WebSocket. It runs inside runTurn's existing
    # closeCodexWs bracket, against a throwaway clone of history, so it must
    # not appear in the WS choreography at all — ws_connections stays 2 and
    # the post-compaction turn still re-anchors on a socket the pre-compaction
    # turn never used.
    if note.connection_id is not None:
        raise AssertionError(
            f"midturn: the note turn opened a WebSocket (conn {note.connection_id}); "
            "it must stay off the WS session it is compacting around"
        )
    if first.connection_id == final.connection_id:
        raise AssertionError("midturn: final request reused the pre-compaction WS")
    assert_read_before_compact(first, read)
    for request in (first, note, compact, final):
        if not mock.has_fresh_parent(request):
            raise AssertionError(
                f"midturn: request {request.ordinal} carried stale previous_response_id: "
                f"{request.body['previous_response_id']!r}"
            )
        mock.assert_fresh_anchor(request)

    # The note turn is a bounded, tool-less auxiliary call on its own persona —
    # never the root prompt, which would hand it the whole tool catalog and its
    # own previous note.
    if "tools" in note.body or not str(note.body.get("instructions", "")).startswith(
        "You are writing a private note to your future self"
    ):
        raise AssertionError(
            f"midturn: the note turn was not the bounded tool-less persona call: {note.body!r}"
        )

    # #391 END TO END, on the wire. The note is written before the summary, so
    # every request AFTER it must carry it in `instructions` — the system
    # prompt, which compaction cannot rewrite — while the request before it
    # carries nothing.
    if NOTE_BLOCK_HEADER in str(first.body.get("instructions", "")):
        raise AssertionError("midturn: a note block existed before any note was written")
    for label, request in (("summary", compact), ("post-compaction", final)):
        instructions = str(request.body.get("instructions", ""))
        if NOTE_BLOCK_HEADER not in instructions or MIDTURN_NOTE not in instructions:
            raise AssertionError(
                f"midturn: the {label} request did not carry the note-to-self VERBATIM "
                f"in its system prompt: {instructions[-400:]!r}"
            )
    # …and it is STATE, not conversation: the post-compaction turn's history is
    # the handoff summary alone. If the note ever appears in `input` it has
    # become something a later compaction can summarize away.
    final_json = json.dumps(final.body.get("input") or [], separators=(",", ":"))
    if NOTE_BLOCK_HEADER in final_json or MIDTURN_NOTE in final_json:
        raise AssertionError(
            "midturn: the note leaked into conversation history, where the next "
            f"compaction would paraphrase it away: {final_json[:400]!r}"
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
    # ADR 0221: where loaded tools ride additional_tools items, a compacted
    # history re-announces them next to the handoff. ADR 0243: a full
    # re-anchor leads with the repo context (project instructions, layout) as
    # one developer item. Nothing else may ride along.
    handoff_items = (
        [
            item
            for item in final_input
            if not (isinstance(item, dict) and (item.get("type") == "additional_tools" or is_repo_context(item)))
        ]
        if isinstance(final_input, list)
        else []
    )
    if isinstance(final_input, list) and any(is_repo_context(item) for item in final_input[1:]):
        raise AssertionError(f"midturn: the repo context item must lead the re-anchor: {final_input!r}")
    final_texts = (
        [text for item in final_input if (text := user_text(item)) is not None]
        if isinstance(final_input, list)
        else []
    )
    if (
        final.body.get("type") != "response.create"
        or not isinstance(final_input, list)
        or len(handoff_items) != 2
        or len(final_texts) != 2
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
    # Five with ADR 0272 — the model reads the results before the note.
    # The note
    # is written and kept even though this compaction then FAILS: it is state
    # about the live conversation, not about the summary, and the rollback
    # restores history the note still describes correctly.
    if len(requests) != 5:
        raise AssertionError(
            "transactional: expected exactly 5 model requests, "
            f"got {len(requests)}: {requests!r}"
        )
    first, read, note, compact, final = requests
    if any("max_output_tokens" in request.body for request in requests):
        raise AssertionError("transactional: Responses requests must omit max_output_tokens")
    transports = [request.transport for request in requests]
    if transports != ["ws", "ws", "sse", "sse", "ws"]:
        raise AssertionError(
            f"transactional: expected WS -> WS(read results) -> SSE(note) -> SSE(summary) -> WS, got {transports!r}"
        )
    if mock.ws_turns != 3 or mock.sse_turns != 2 or mock.ws_connections != 2:
        raise AssertionError(
            "transactional: expected three turns on two fresh WS connections plus "
            f"two quiet SSE turns; ws_turns={mock.ws_turns} sse_turns={mock.sse_turns} "
            f"ws_connections={mock.ws_connections}"
        )
    if not last_user_text(note).startswith(NOTE_INSTRUCTION_HEAD):
        raise AssertionError(
            f"transactional: request 3 is not the #391 note turn: {last_user_text(note)[:120]!r}"
        )
    if note.connection_id is not None or "tools" in note.body:
        raise AssertionError(
            "transactional: the note turn must be a tool-less SSE request that "
            f"opens no WebSocket: {note.body!r}"
        )
    if first.connection_id == final.connection_id:
        raise AssertionError(
            "transactional: final request reused the pre-compaction WS"
        )
    assert_read_before_compact(first, read)
    for request in (first, note, compact, final):
        if not mock.has_fresh_parent(request):
            raise AssertionError(
                f"transactional: request {request.ordinal} carried stale "
                f"previous_response_id: {request.body['previous_response_id']!r}"
            )
        mock.assert_fresh_anchor(request)

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
            "transactional: fourth request was not the pruned, synthetic SSE "
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
        or len(calls) != 1
        or len(outputs) != 1
        or leaked_summary_response
    ):
        raise AssertionError(
            "transactional: final WS request did not restore the original prompt, "
            "reasoning, function call, and output without the synthetic compact "
            f"instruction: {final.body!r}"
        )


