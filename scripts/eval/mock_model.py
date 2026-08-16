#!/usr/bin/env python3
"""A scripted OpenAI-compatible model, for tier-2 behavioral evals.

scripts/openai_mock.py answers everything with "done", which is enough to prove
plumbing but cannot drive the harness through a checklist. This one replays a
script: each entry is the reply to the next model call in the run, in order, so
a case can say "call todo_write with these three items, then finish them, then
claim completion" and the assertions can check what the harness did with it.

A reply is either:

    {"text": "..."}
    {"tool": "todo_write", "arguments": {...}}
    {"tool": "todo_write", "arguments": {...}, "text": "..."}

Past the end of the script every call answers with `exhausted_text` (default
"done"), so a run that takes more turns than the case scripted still ends
instead of hanging.

Requests are recorded in order so an assertion can look at what the harness
actually sent - that is how "compaction restated the checklist" is checked.
"""

from __future__ import annotations

import http.server
import json
import threading
from typing import Any


class ScriptedModel:
    def __init__(self, script: list[dict[str, Any]], exhausted_text: str = "done") -> None:
        self.script = script
        self.exhausted_text = exhausted_text
        self.requests: list[dict[str, Any]] = []
        self.request_headers: list[dict[str, str]] = []
        self._lock = threading.Lock()
        self._server: http.server.ThreadingHTTPServer | None = None

    def next_reply(self, body: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            self.requests.append(body)
            index = len(self.requests) - 1
            if index < len(self.script):
                return self.script[index]
        return {"text": self.exhausted_text}

    def start(self, port: int = 1234) -> int:
        model = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _body(self) -> dict[str, Any]:
                length = int(self.headers.get("content-length", 0))
                if not length:
                    return {}
                try:
                    return json.loads(self.rfile.read(length))
                except (ValueError, UnicodeDecodeError):
                    return {}

            def _send(self, payload: bytes, content_type: str) -> None:
                self.send_response(200)
                self.send_header("content-type", content_type)
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self) -> None:  # noqa: N802 - /v1/models probes
                self._send(json.dumps({"data": [{"id": "mock"}]}).encode(), "application/json")

            def do_POST(self) -> None:  # noqa: N802
                body = self._body()
                model.request_headers.append({k.lower(): v for k, v in self.headers.items()})
                reply = model.next_reply(body)
                if body.get("stream"):
                    self._stream(reply)
                else:
                    self._whole(reply)

            def _message(self, reply: dict[str, Any]) -> dict[str, Any]:
                message: dict[str, Any] = {"role": "assistant", "content": reply.get("text", "")}
                if reply.get("tool"):
                    message["tool_calls"] = [{
                        "id": f"call_{len(model.requests)}",
                        "type": "function",
                        "function": {
                            "name": reply["tool"],
                            "arguments": json.dumps(reply.get("arguments", {})),
                        },
                    }]
                return message

            def _whole(self, reply: dict[str, Any]) -> None:
                message = self._message(reply)
                finish = "tool_calls" if "tool_calls" in message else "stop"
                self._send(json.dumps({
                    "id": "mock", "object": "chat.completion", "model": "mock",
                    "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                    "usage": {"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12},
                }).encode(), "application/json")

            def _stream(self, reply: dict[str, Any]) -> None:
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("cache-control", "no-cache")
                self.send_header("connection", "close")
                self.end_headers()
                message = self._message(reply)
                deltas: list[dict[str, Any]] = []
                if message["content"]:
                    deltas.append({"role": "assistant", "content": message["content"]})
                for position, call in enumerate(message.get("tool_calls", [])):
                    deltas.append({"tool_calls": [{
                        "index": position,
                        "id": call["id"],
                        "type": "function",
                        "function": call["function"],
                    }]})
                finish = "tool_calls" if "tool_calls" in message else "stop"
                for delta in deltas or [{"role": "assistant", "content": ""}]:
                    self._chunk({"choices": [{"index": 0, "delta": delta, "finish_reason": None}]})
                self._chunk({
                    "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
                    "usage": {"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12},
                })
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True

            def _chunk(self, payload: dict[str, Any]) -> None:
                framed = dict(payload, id="mock", object="chat.completion.chunk", model="mock")
                self.wfile.write(b"data: " + json.dumps(framed).encode() + b"\n\n")

            def log_message(self, *_args) -> None:
                pass

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self._server.server_address[1]

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=1234)
    parser.add_argument("--script", help="JSON file holding the reply list")
    args = parser.parse_args()
    script = json.load(open(args.script, encoding="utf-8")) if args.script else []
    model = ScriptedModel(script)
    port = model.start(args.port)
    print(f"scripted model on 127.0.0.1:{port} ({len(script)} scripted replies)", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        model.stop()


if __name__ == "__main__":
    main()
