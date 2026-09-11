#!/usr/bin/env python3
"""Offline ACP force-steer regression: cancel a live stream, then reuse the session."""
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        body = json.dumps({"data": [{"id": "mock"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for _ in range(100):
                data = {"id": "mock", "choices": [{"index": 0,
                        "delta": {"content": "working "}, "finish_reason": None}]}
                self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())
                self.wfile.flush()
                time.sleep(0.1)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve())
    # LM Studio's built-in local endpoint; fail rather than reuse an occupied port.
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 1234), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-acp-steer-") as temp:
            env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
            config = Path(temp) / "mcp.json"
            config.write_text('{"mcpServers":{}}')
            env.update(HOME=temp, LMSTUDIO_API_KEY="local", GRAFF_NO_TELEMETRY="1",
                       GRAFF_FLEET="off", GRAFF_NO_SMOLIFY="1",
                       GRAFF_MCP_CONFIG=str(config), NO_COLOR="1")
            proc = subprocess.Popen([binary, "acp", "--model", "lmstudio", "--yolo"],
                                    cwd=temp, env=env, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            events = queue.Queue()

            def read():
                for line in proc.stdout:
                    try:
                        events.put(json.loads(line))
                    except ValueError:
                        pass

            threading.Thread(target=read, daemon=True).start()

            def send(method, params, request_id=None):
                value = {"jsonrpc": "2.0", "method": method, "params": params}
                if request_id is not None:
                    value["id"] = request_id
                proc.stdin.write(json.dumps(value) + "\n")
                proc.stdin.flush()

            def until(predicate, timeout=30):
                end = time.monotonic() + timeout
                while True:
                    value = events.get(timeout=max(0.01, end - time.monotonic()))
                    if predicate(value):
                        return value
                    if time.monotonic() >= end:
                        raise AssertionError("ACP response deadline exceeded")

            try:
                send("initialize", {"protocolVersion": 1}, 1)
                until(lambda v: v.get("id") == 1)
                send("session/new", {"cwd": temp}, 2)
                sid = until(lambda v: v.get("id") == 2)["result"]["sessionId"]
                for request_id in (3, 4):
                    send("session/prompt", {"sessionId": sid, "prompt": [
                        {"type": "text", "text": f"Say hello {request_id}"}]}, request_id)
                    until(lambda v: v.get("params", {}).get("update", {}).get(
                        "sessionUpdate") == "agent_message_chunk")
                    started = time.monotonic()
                    send("session/cancel", {"sessionId": sid})
                    result = until(lambda v: v.get("id") == request_id, timeout=5)
                    assert result.get("result", {}).get("stopReason") == "cancelled", result
                    print(f"PASS: live turn interrupted in {time.monotonic() - started:.2f}s")
                print("PASS: next turn streams in the same session after force-steer")
            finally:
                proc.stdin.close()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    proc.wait(timeout=5)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
