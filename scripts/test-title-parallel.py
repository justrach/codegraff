#!/usr/bin/env python3
"""Prove the first-turn AI title request overlaps the real model turn."""

import json
import os
import sys
import tempfile
import threading
import time

from codex_ws_mock import CodexMock
from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
MAIN_REPLY = "PARALLEL_TITLE_MAIN_OK"
TITLE_DELAY_SECONDS = 1.5


def message_item(text: str, item_id: str) -> dict:
    return {
        "type": "message",
        "id": item_id,
        "status": "completed",
        "role": "assistant",
        "content": [
            {"type": "output_text", "text": text, "annotations": []}
        ],
    }


def main() -> None:
    barrier = threading.Barrier(2)
    lock = threading.Lock()
    arrivals: list[tuple[float, str]] = []

    def events(request) -> list[dict]:
        instructions = request.body.get("instructions", "")
        is_title = "You summarize what a coding session is about" in instructions
        with lock:
            arrivals.append((time.monotonic(), "title" if is_title else "main"))
        # A serialized implementation blocks here for three seconds before the
        # main request can start; true overlap sends both through together.
        try:
            barrier.wait(timeout=3.0)
        except threading.BrokenBarrierError:
            pass
        # The title deliberately finishes well after the main reply. A detached
        # implementation paints the next prompt immediately; an end-of-turn
        # join makes the user wait for this sleep.
        if is_title:
            time.sleep(TITLE_DELAY_SECONDS)
        text = "Parallel title generation" if is_title else MAIN_REPLY
        return [
            {
                "type": "response.output_item.done",
                "item": message_item(text, f"msg_parallel_{request.ordinal}"),
            },
            {
                "type": "response.completed",
                "response": {
                    "id": f"resp_parallel_{request.ordinal}",
                    "usage": {
                        "input_tokens": 100,
                        "input_tokens_details": {"cached_tokens": 0},
                        "output_tokens": 10,
                        "total_tokens": 110,
                    },
                },
            },
        ]

    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-title-parallel-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(
                os.path.join(codex_home, "auth.json"), "w", encoding="utf-8"
            ) as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "title-parallel-mock",
                            "account_id": "acct-title-parallel",
                        }
                    },
                    fh,
                )
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(
                os.path.join(harness_dir, "settings.json"),
                "w",
                encoding="utf-8",
            ) as fh:
                json.dump({"skills": {"codedbpro": False}}, fh)

            env = {
                "HOME": tmp,
                "CODEX_HOME": codex_home,
                "GRAFF_CODEX_URL": (
                    f"http://127.0.0.1:{port}/backend-api/codex/responses"
                ),
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
            }
            ambient = tuple(
                name
                for name in os.environ
                if (
                    name.startswith("GRAFF_")
                    or name.startswith("CODEX_")
                    or name == "NO_COLOR"
                )
                and name not in env
            )
            with PtySession(
                GRAFF,
                ["--model", "codex", "--max-model-calls", "2", "--no-telemetry"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=10.0,
            ) as session:
                session.wait_for_prompt()
                cursor = len(session.raw)
                sent_at = time.monotonic()
                session.send_line("make the title and answer overlap")
                session.wait_for_literal(MAIN_REPLY, start=cursor)
                session.wait_for_prompt(start=cursor)
                prompt_elapsed = time.monotonic() - sent_at
                if prompt_elapsed >= TITLE_DELAY_SECONDS - 0.4:
                    raise AssertionError(
                        "next prompt waited for detached title "
                        f"({prompt_elapsed:.2f}s)"
                    )
                session.send_key("ctrl-d")
                result = session.read_until_exit(5.0)
                if result.timed_out or result.exit_code != 0:
                    raise AssertionError(
                        f"session exit={result.exit_code} timed_out={result.timed_out}"
                    )
    finally:
        mock.stop()

    with lock:
        observed = sorted(arrivals)
    if len(observed) != 2 or {kind for _, kind in observed} != {"title", "main"}:
        raise AssertionError(f"expected one title and one main request: {observed!r}")
    requests = mock.recorded_requests()
    caps = {
        (
            "title"
            if "You summarize what a coding session is about"
            in request.body.get("instructions", "")
            else "main"
        ): "max_output_tokens" in request.body
        for request in requests
    }
    if caps != {"title": False, "main": False}:
        raise AssertionError(
            f"Responses requests must not carry a top-level "
            f"max_output_tokens (gpt-5.6 backend rejects it, #247): {caps!r}"
        )
    delta_ms = (observed[1][0] - observed[0][0]) * 1000
    if delta_ms > 750:
        raise AssertionError(f"title/main requests serialized ({delta_ms:.1f}ms apart)")
    print(
        "ok    AI title and main turn overlapped "
        f"({delta_ms:.1f}ms apart); prompt returned in {prompt_elapsed:.2f}s "
        f"while title stayed busy for {TITLE_DELAY_SECONDS:.1f}s"
    )


if __name__ == "__main__":
    main()
