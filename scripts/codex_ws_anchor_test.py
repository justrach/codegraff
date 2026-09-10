#!/usr/bin/env python3
"""#848/#846: per-connection prewarm anchors are fresh; stale parents are not."""

from __future__ import annotations

from codex_ws_mock import CodexMock, RecordedRequest


def _req(
    connection_id: int | None,
    parent: str | None = None,
    transport: str = "ws",
) -> RecordedRequest:
    body: dict = {}
    if parent is not None:
        body["previous_response_id"] = parent
    return RecordedRequest(
        ordinal=1, transport=transport, connection_id=connection_id, body=body
    )


def main() -> None:
    mock = CodexMock()
    mock.prewarm_ids[1] = "resp_prewarm_1"
    if not mock.has_fresh_parent(_req(1)):
        raise AssertionError("missing parent must be a fresh full replay")
    if not mock.has_fresh_parent(_req(1, "resp_prewarm_1")):
        raise AssertionError("this socket's prewarm must be a fresh anchor")
    if mock.has_fresh_parent(_req(1, "resp_chain_1")):
        raise AssertionError("a prior-turn id must stay stale")
    if mock.has_fresh_parent(_req(2, "resp_prewarm_1")):
        raise AssertionError("another socket must not inherit this prewarm")
    if mock.has_fresh_parent(_req(1, "resp_prewarm_1", transport="sse")):
        raise AssertionError("SSE must not claim a WS prewarm parent")
    print("ok")


if __name__ == "__main__":
    main()
