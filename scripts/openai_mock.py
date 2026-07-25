#!/usr/bin/env python3
"""A tiny OpenAI-compatible mock server for offline end-to-end runs.

Binds 127.0.0.1:1234 (the fixed `lmstudio` provider URL) and answers
/v1/chat/completions with either a streamed or non-streamed reply. The reply is
deliberately dumb: learning end-to-end tests need the *plumbing* exercised
(mutation adapter, paired evaluation, gates), not a model that solves tasks.

  python3 scripts/openai_mock.py [--port 1234]
"""

from __future__ import annotations

import argparse
import http.server
import json
import threading


CLAUSE = "Prefer one exact read before an edit, then stop after verified success."


def reply_for(body: dict) -> str:
    """The mutation adapter needs strict JSON; everything else gets prose."""
    text = json.dumps(body)
    if "Draft one behavioral clause" in text or "corrected JSON object" in text:
        return json.dumps({"clause": CLAUSE})
    return "done"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _read_body(self) -> dict:
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

    def do_GET(self) -> None:  # noqa: N802 — /v1/models probes
        self._send(json.dumps({"data": [{"id": "mock"}]}).encode(), "application/json")

    def do_POST(self) -> None:  # noqa: N802
        body = self._read_body()
        content = reply_for(body)
        if body.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.send_header("connection", "close")
            self.end_headers()
            for chunk in (
                {"choices": [{"index": 0, "delta": {"role": "assistant", "content": content}, "finish_reason": None}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                 "usage": {"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12}},
            ):
                payload = dict(chunk, id="mock", object="chat.completion.chunk", model="mock")
                self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return
        self._send(json.dumps({
            "id": "mock",
            "object": "chat.completion",
            "model": "mock",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12},
        }).encode(), "application/json")

    def log_message(self, *_a) -> None:
        pass


def serve(port: int = 1234) -> http.server.ThreadingHTTPServer:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=1234)
    args = parser.parse_args()
    server = serve(args.port)
    print(f"mock openai server on 127.0.0.1:{args.port}", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
