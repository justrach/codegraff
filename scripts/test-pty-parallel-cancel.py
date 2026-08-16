#!/usr/bin/env python3
"""Real-PTY regression for parallel bash interruption and process-group cleanup."""

import http.server
import json
import os
import shlex
import socket
import sys
import tempfile
import threading
import time

from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


class ToolMock:
    def __init__(self, commands: list[str]) -> None:
        self.commands = commands
        self.hits = 0
        parent = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", 0))
                if length:
                    self.rfile.read(length)
                parent.hits += 1
                if parent.hits == 1:
                    tool_calls = []
                    for i, command in enumerate(parent.commands):
                        tool_calls.append({
                            "index": i,
                            "id": f"cancel-{i}",
                            "type": "function",
                            "function": {
                                "name": "bash",
                                "arguments": json.dumps({"command": command}),
                            },
                        })
                    chunk = {
                        "choices": [{
                            "delta": {"role": "assistant", "tool_calls": tool_calls},
                            "finish_reason": "tool_calls",
                        }]
                    }
                else:
                    chunk = {
                        "choices": [{
                            "delta": {"role": "assistant", "content": "done"},
                            "finish_reason": "stop",
                        }]
                    }
                body = ("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode()
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:  # noqa: N802
                self.send_response(404)
                self.end_headers()

            def log_message(self, *_args) -> None:
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 1234), Handler)

    def start(self) -> None:
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


def wait_for_pid_files(session: PtySession, paths: list[str]) -> None:
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        session.pump(0.05)
        if all(os.path.exists(path) and os.path.getsize(path) > 0 for path in paths):
            return
    raise AssertionError(f"parallel commands did not start: {paths}")


def assert_processes_gone(paths: list[str]) -> None:
    pids = [int(open(path, encoding="utf-8").read().strip()) for path in paths]
    deadline = time.monotonic() + 2
    alive = pids
    while alive and time.monotonic() < deadline:
        next_alive = []
        for pid in alive:
            try:
                os.kill(pid, 0)
                next_alive.append(pid)
            except ProcessLookupError:
                pass
        alive = next_alive
        if alive:
            time.sleep(0.05)
    if alive:
        for pid in alive:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        raise AssertionError(f"cancelled command descendants survived: {alive}")


def main() -> None:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        probe.bind(("127.0.0.1", 1234))
    except OSError:
        print("skip  127.0.0.1:1234 is in use — parallel-cancel PTY test skipped")
        return
    finally:
        probe.close()

    with tempfile.TemporaryDirectory(prefix="graff-parallel-cancel-") as tmp:
        harness = os.path.join(tmp, ".harness")
        os.makedirs(harness, exist_ok=True)
        with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
            json.dump({"ai_title": False}, fh)
        pid_paths = [os.path.join(tmp, f"child-{i}.pid") for i in range(2)]
        commands = [f"sleep 30 & echo $! > {shlex.quote(path)}; wait" for path in pid_paths]
        mock = ToolMock(commands)
        mock.start()
        try:
            env = {
                "HOME": tmp,
                "LMSTUDIO_API_KEY": "local-pty-test",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
                # #364: stamp every teardown phase onto the terminal, so the
                # transcript dumped below names the phase that stalled instead
                # of ending at the prompt with nothing to go on. No marks at
                # all means the quit keystroke itself never landed.
                "GRAFF_SHUTDOWN_DEBUG": "1",
                "GRAFF_REPL_DEBUG": "1",  # this test asserts the debug-only parallel tool lifecycle rows
            }
            with PtySession(GRAFF, ["--model", "lmstudio", "--no-telemetry"], cwd=tmp, env=env, timeout=20) as session:
                session.wait_for_literal("] ›")
                session.send_line("/yolo")
                session.wait_for_literal("yolo mode ON")
                cursor = len(session.raw)
                session.send_line("run both checks")
                session.wait_for_literal("running 2 tools in parallel", start=cursor)
                wait_for_pid_files(session, pid_paths)
                session.send_key("esc")
                session.wait_for_literal("[cancelled by user; local process group killed]", start=cursor)
                session.wait_for_literal("parallel tools finished: 0 completed, 0 failed, 2 cancelled", start=cursor)
                session.wait_for_literal("interrupted (esc)", start=cursor)
                assert_processes_gone(pid_paths)
                session.send_key("ctrl-d")
                # #364: the exit was never SLOW, it was infinite. This ctrl-d
                # lands in the sliver between the interrupted turn restoring
                # the terminal and the next prompt claiming it, so Linux's line
                # discipline handled it as a canonical-mode VEOF and delivered
                # it as NUL; readLine had no case for that byte and waited at
                # the prompt forever (input_util.typeAheadByte now maps it
                # back). The window stays generous and the transcript is still
                # dumped: with GRAFF_SHUTDOWN_DEBUG on, a future stall names
                # its phase rather than leaving a bare exit code.
                result = session.read_until_exit(30)
                if result.timed_out or result.exit_code != 0:
                    raw = session.raw
                    tail = (raw.decode("utf-8", "replace") if isinstance(raw, (bytes, bytearray)) else str(raw))[-2000:]
                    raise AssertionError(
                        f"REPL exit={result.exit_code} timed_out={result.timed_out}\n"
                        f"--- pty transcript tail ---\n{tail}"
                    )
        finally:
            mock.stop()
    print("ok    parallel Esc reports terminal states and kills command descendants")


if __name__ == "__main__":
    main()
