#!/usr/bin/env python3
"""Prove a large tool result comes back as a #440 handle, not as payload.

The full bytes land on disk; history gets a bounded preview plus the handle's
absolute path, the byte count, and a measured shape hint.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest
from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
FINAL_REPLY = "TOOL_PREVIEW_OK"
# tool_handle.default_threshold_bytes; the payload has to clear it comfortably.
THRESHOLD = 4096
PAYLOAD = "large-tool-result:" + "x" * 20000


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
    if request.ordinal == 1:
        return response_events(
            {
                "type": "function_call",
                "id": "fc_large_read",
                "call_id": "call_large_read",
                "name": "read_file",
                "arguments": json.dumps({"path": "large.txt"}),
                "status": "completed",
            },
            "resp_large_read",
        )
    return response_events(message_item(FINAL_REPLY, "msg_preview_done"), "resp_preview_done")


def main() -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-tool-preview-") as tmp:
            with open(os.path.join(tmp, "large.txt"), "w", encoding="utf-8") as fh:
                fh.write(PAYLOAD)
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "tool-preview-mock",
                            "account_id": "acct-tool-preview",
                        }
                    },
                    fh,
                )
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
                json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)

            env = {
                "HOME": tmp,
                "CODEX_HOME": codex_home,
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
            }
            ambient = tuple(
                name
                for name in os.environ
                if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
                and name not in env
            )
            with PtySession(
                GRAFF,
                ["--model", "codex", "--no-telemetry"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=10.0,
            ) as session:
                session.wait_for_prompt()
                cursor = len(session.raw)
                session.send_line("read the large file, then finish")
                session.wait_for_literal(FINAL_REPLY, start=cursor)
                session.wait_for_prompt(start=cursor)
                session.send_key("ctrl-d")
                result = session.read_until_exit(5.0)
                if result.timed_out or result.exit_code != 0:
                    raise AssertionError(
                        f"session exit={result.exit_code} timed_out={result.timed_out}"
                    )

            requests = mock.recorded_requests()
            if len(requests) != 2:
                raise AssertionError(f"expected tool loop in two requests: {requests!r}")
            second_input = requests[1].body.get("input")
            outputs = [
                item.get("output")
                for item in second_input
                if isinstance(item, dict) and item.get("type") == "function_call_output"
            ] if isinstance(second_input, list) else []
            if len(outputs) != 1 or not isinstance(outputs[0], str):
                raise AssertionError(f"missing function_call_output: {second_input!r}")
            preview = outputs[0]
            if len(preview) > THRESHOLD:
                raise AssertionError(f"model-facing preview is {len(preview)} chars")
            # #440: preview + handle path + byte count + shape hint, in one marker.
            match = re.search(
                r"\[tool result handle: (\d+) bytes, (.+?) — the COMPLETE result is at (.+?)\. Slice",
                preview,
            )
            if match is None:
                raise AssertionError(f"preview has no handle marker: {preview!r}")
            byte_count, shape, handle = int(match.group(1)), match.group(2), match.group(3)
            if byte_count != len(PAYLOAD):
                raise AssertionError(f"handle claims {byte_count} bytes, payload is {len(PAYLOAD)}")
            if shape != "1 lines":
                raise AssertionError(f"shape hint is not measured from the payload: {shape!r}")
            if not os.path.isabs(handle):
                raise AssertionError(f"handle path is not absolute: {handle!r}")
            with open(handle, encoding="utf-8") as fh:
                persisted = fh.read()
            if persisted != PAYLOAD:
                raise AssertionError(
                    f"handle does not hold the full result ({len(persisted)} != {len(PAYLOAD)})"
                )
    finally:
        mock.stop()

    print(
        "ok    large tool output became a handle: full bytes on disk, "
        f"<={THRESHOLD}-byte preview + path + size + shape in history"
    )


if __name__ == "__main__":
    main()
