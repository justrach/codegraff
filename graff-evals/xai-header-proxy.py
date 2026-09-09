#!/usr/bin/env python3
"""127.0.0.1 reverse proxy: inject X-XAI-Token-Auth onto https://api.x.ai.

SuperGrok JWTs 403 without that header (not a secret). Safe to add on metered
`xai-` keys too. Streaming is passed through byte-for-byte.
"""
from __future__ import annotations

import argparse
import http.client
import http.server
import os
import signal
import sys
import time
from pathlib import Path

UPSTREAM_HOST = "api.x.ai"
TOKEN_AUTH = "xai-grok-cli"
HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
}
STATE_DIR = Path(os.environ.get("XAI_PROXY_DIR", "/tmp/xai-header-proxy"))
PID_PATH = STATE_DIR / "pid"
PORT_PATH = STATE_DIR / "port"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("xai-header-proxy: " + (fmt % args) + "\n")

    def do_GET(self) -> None:
        self._forward()

    def do_POST(self) -> None:
        self._forward()

    def do_PUT(self) -> None:
        self._forward()

    def do_DELETE(self) -> None:
        self._forward()

    def do_PATCH(self) -> None:
        self._forward()

    def do_HEAD(self) -> None:
        self._forward()

    def _forward(self) -> None:
        if self.path in ("/health", "/"):
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        hdrs = {}
        for key, value in self.headers.items():
            if key.lower() in HOP:
                continue
            hdrs[key] = value
        hdrs["Host"] = UPSTREAM_HOST
        hdrs["X-XAI-Token-Auth"] = TOKEN_AUTH
        conn = http.client.HTTPSConnection(UPSTREAM_HOST, timeout=600)
        try:
            conn.request(self.command, self.path, body=body, headers=hdrs)
            resp = conn.getresponse()
            self.send_response(resp.status, resp.reason)
            for key, value in resp.getheaders():
                if key.lower() in HOP or key.lower() == "content-length":
                    continue
                self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        finally:
            conn.close()


def _alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _url(port: int) -> str:
    return f"http://127.0.0.1:{port}"


def _read_running() -> str | None:
    try:
        pid = int(PID_PATH.read_text().strip())
        port = int(PORT_PATH.read_text().strip())
    except (OSError, ValueError):
        return None
    if not _alive(pid):
        return None
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
        conn.request("GET", "/health")
        ok = conn.getresponse().status == 200
        conn.close()
    except OSError:
        return None
    return _url(port) if ok else None


def _serve(port: int) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    bound = httpd.server_address[1]
    PID_PATH.write_text(str(os.getpid()))
    PORT_PATH.write_text(str(bound))
    os.chmod(PID_PATH, 0o600)
    os.chmod(PORT_PATH, 0o600)

    def _stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    httpd.serve_forever()


def _spawn(port: int) -> str:
    child = os.fork()
    if child == 0:
        os.setsid()
        # Second fork so the proxy is not a session leader (classic daemon).
        if os.fork() != 0:
            os._exit(0)
        sys.stdin.close()
        _serve(port)
        os._exit(0)
    os.waitpid(child, 0)
    for _ in range(50):
        url = _read_running()
        if url:
            return url
        time.sleep(0.05)
    raise SystemExit("xai-header-proxy: failed to start")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ensure", action="store_true", help="start if needed; print base URL")
    ap.add_argument("--port", type=int, default=0, help="bind port (0 = ephemeral)")
    ap.add_argument("--foreground", action="store_true")
    args = ap.parse_args()
    if args.foreground:
        _serve(args.port)
        return 0
    url = _read_running()
    if url is None:
        url = _spawn(args.port)
    if args.ensure:
        sys.stdout.write(url + "\n")
        return 0
    print(url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
