#!/usr/bin/env python3
"""Tiny capturing OTLP collector for end-to-end fleet-signal tests.

Stands in for harness-telemetry: answers GET /v1/elites (empty champions) and
captures every POST /v1/logs body to a JSONL file so a test can assert the
harness emitted the right `fleet` records (propose/submit/elite_pull).

  python3 scripts/otlp_mock.py <port> <capture_file>
"""
import http.server, sys, json

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
CAP = sys.argv[2] if len(sys.argv) > 2 else "/tmp/otlp_cap.jsonl"


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body=b"{}"):
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/elites"):
            self._send(200, json.dumps(
                {"ok": True, "source": "candidate", "elites": []}).encode())
        else:
            self._send(404, b"{}")

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        data = self.rfile.read(n)
        with open(CAP, "ab") as f:
            f.write(data + b"\n")
        self._send(200, b"{}")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    open(CAP, "w").close()  # truncate
    print(f"otlp_mock on 127.0.0.1:{PORT} -> {CAP}", flush=True)
    http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
