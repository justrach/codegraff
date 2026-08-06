#!/usr/bin/env python3
"""Capture the exact request body each binary sends, with zero live model cost.

Serves an OpenAI-compatible /v1/chat/completions on 127.0.0.1:1234, records the
first POST body to a file, and answers with a trivial finished completion.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[1]
captured = threading.Event()


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = self.rfile.read(n)
        if not captured.is_set():
            with open(OUT, "wb") as f:
                f.write(body)
            captured.set()
        resp = {
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "created": 0,
            "model": "lmstudio",
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": "MOCK"}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        data = json.dumps({"data": [{"id": "lmstudio"}]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    srv = HTTPServer(("127.0.0.1", 1234), H)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    captured.wait(timeout=90)
    srv.shutdown()
