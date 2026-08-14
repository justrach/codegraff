#!/usr/bin/env python3
"""Offline end-to-end regression for mid-turn JSON cancellation."""

import http.client
import http.server
import json
import os
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time

GRAFF = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")


class Mock(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    calls = 0
    lock = threading.Lock()

    def log_message(self, *_args):
        pass

    def do_GET(self):
        body = json.dumps({"data": [{"id": "mock"}]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        self.rfile.read(length)
        with self.lock:
            type(self).calls += 1
            call = type(self).calls
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()
        if call == 1:
            chunks = [
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "cancel-probe",
                  "type": "function", "function": {"name": "bash", "arguments": json.dumps({"command": "sleep 20"})}}]},
                  "finish_reason": None}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
            ]
        else:
            chunks = [
                {"choices": [{"delta": {"content": "after-cancel-ok"}, "finish_reason": None}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}],
                 "usage": {"prompt_tokens": 2, "completion_tokens": 1, "total_tokens": 3}},
            ]
        for chunk in chunks:
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True


def read_events(proc, events):
    for line in proc.stdout:
        try:
            events.put(json.loads(line))
        except json.JSONDecodeError:
            pass


def event_until(events, predicate, timeout=8):
    deadline = time.monotonic() + timeout
    seen = []
    while time.monotonic() < deadline:
        try:
            event = events.get(timeout=min(0.1, deadline - time.monotonic()))
        except queue.Empty:
            continue
        seen.append(event)
        if predicate(event):
            return event
    raise AssertionError(f"timed out waiting for event; saw {seen!r}")


def send(proc, request):
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def http_json(port, method, path, body=None, timeout=10):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    payload = None if body is None else json.dumps(body)
    conn.request(method, path, payload, {"content-type": "application/json"})
    response = conn.getresponse()
    raw = response.read()
    conn.close()
    return response.status, json.loads(raw) if raw else None


def stream_http(port, path, body, events):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        conn.request("POST", path, json.dumps(body), {"content-type": "application/json"})
        response = conn.getresponse()
        events.put({"type": "headers", "status": response.status})
        if response.status != 200:
            raise AssertionError(f"turn POST returned {response.status}: {response.read()[:200]!r}")
        while line := response.readline():
            if line.strip():
                events.put(json.loads(line))
    except Exception as exc:
        events.put({"type": "stream_error", "message": repr(exc)})
    finally:
        conn.close()


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 1234), Mock)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-json-cancel-") as tmp:
            env = {**os.environ, "HOME": tmp, "CODEGRAFF_API_KEY": "offline-test-key", "LMSTUDIO_API_KEY": "offline-test-key",
                   "GRAFF_NO_TELEMETRY": "1", "GRAFF_NO_SMOLIFY": "1"}
            proc = subprocess.Popen(
                [GRAFF, "--json", "--model", "lmstudio", "--yolo", "--no-telemetry"],
                cwd=tmp, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, bufsize=1,
            )
            events = queue.Queue()
            threading.Thread(target=read_events, args=(proc, events), daemon=True).start()
            try:
                send(proc, {"type": "user", "text": "block until cancelled"})
                event_until(events, lambda e: e.get("type") == "tool_call" and e.get("name") == "bash")
                started = time.monotonic()
                send(proc, {"type": "cancel"})
                event_until(events, lambda e: e.get("type") == "error" and e.get("message") == "turn cancelled")
                assert time.monotonic() - started < 5, "cancel queued behind the active turn"

                send(proc, {"type": "user", "text": "prove the inbox still owns stdin"})
                turn = event_until(events, lambda e: e.get("type") == "turn", timeout=10)
                assert turn.get("text") == "after-cancel-ok", turn

                # AbortSignal can fire immediately after the SDK writes the user
                # line, before mainloop has dequeued it. The inbox must retain
                # that cancellation for the queued turn rather than lose it.
                send(proc, {"type": "user", "text": "cancel before started"})
                send(proc, {"type": "cancel"})
                event_until(events, lambda e: e.get("type") == "error" and e.get("message") == "turn cancelled")
                send(proc, {"type": "user", "text": "still usable after queued cancel"})
                turn = event_until(events, lambda e: e.get("type") == "turn", timeout=10)
                assert turn.get("text") == "after-cancel-ok", turn
                print("ok: active and queued JSON turns cancel cleanly; later turns still complete")
            finally:
                proc.stdin.close()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                if proc.returncode != 0:
                    raise AssertionError(proc.stderr.read())

            with Mock.lock:
                Mock.calls = 0
            port = free_port()
            serve = subprocess.Popen(
                [GRAFF, "serve", "--host", "127.0.0.1", "--port", str(port),
                 "--model", "lmstudio", "--yolo", "--no-telemetry"],
                cwd=tmp, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE, text=True,
            )
            serve_stderr = []
            threading.Thread(target=lambda: serve_stderr.extend(serve.stderr), daemon=True).start()
            session_id = None
            try:
                for _ in range(200):
                    if serve.poll() is not None:
                        raise AssertionError(f"graff serve exited early ({serve.returncode})")
                    try:
                        status, _ = http_json(port, "GET", "/healthz", timeout=2)
                        if status == 200:
                            break
                    except OSError:
                        time.sleep(0.05)
                else:
                    raise AssertionError("graff serve never became healthy")

                status, created = http_json(port, "POST", "/v1/sessions",
                                            {"session": "cancel-e2e", "model": "lmstudio", "yolo": True})
                assert status == 201, (status, created)
                session_id = created["session_id"]
                path = f"/v1/sessions/{session_id}"
                events = queue.Queue()
                turn_thread = threading.Thread(
                    target=stream_http,
                    args=(port, path, {"type": "user", "text": "block in serve until cancelled"}, events),
                    daemon=True,
                )
                turn_thread.start()
                try:
                    event_until(events, lambda e: e.get("type") == "tool_call" and e.get("name") == "bash")
                except AssertionError as exc:
                    event_log = os.path.join(tmp, ".graff", "serve", f"{session_id}.events.jsonl")
                    log_tail = "<missing>"
                    if os.path.exists(event_log):
                        with open(event_log) as log_file:
                            log_tail = log_file.read()[-2000:]
                    raise AssertionError(
                        f"{exc}; mock calls={Mock.calls}; event log={log_tail!r}; "
                        f"serve stderr={''.join(serve_stderr)[-2000:]!r}"
                    ) from exc
                started = time.monotonic()
                status, cancelled = http_json(port, "POST", path, {"type": "cancel"})
                assert status == 200 and cancelled.get("type") == "cancel", (status, cancelled)
                event_until(events, lambda e: e.get("type") == "error" and e.get("message") == "turn cancelled")
                assert time.monotonic() - started < 5, "serve cancel waited behind the active turn"
                turn_thread.join(timeout=2)
                assert not turn_thread.is_alive(), "cancelled serve stream did not close"

                events = queue.Queue()
                turn_thread = threading.Thread(
                    target=stream_http,
                    args=(port, path, {"type": "user", "text": "prove serve session reuse"}, events),
                    daemon=True,
                )
                turn_thread.start()
                turn = event_until(events, lambda e: e.get("type") == "turn", timeout=10)
                assert turn.get("text") == "after-cancel-ok", turn
                turn_thread.join(timeout=2)
                assert not turn_thread.is_alive(), "completed serve stream did not close"
                print("ok: serve cancellation bypasses busy and leaves the session reusable")
            finally:
                if session_id is not None and serve.poll() is None:
                    try:
                        http_json(port, "DELETE", f"/v1/sessions/{session_id}")
                    except OSError:
                        pass
                if serve.poll() is None:
                    serve.terminate()
                    try:
                        serve.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        serve.kill()
                        serve.wait()
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
