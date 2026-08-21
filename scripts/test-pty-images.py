#!/usr/bin/env python3
"""Real-PTY test for the /images command (#103).

Points graff at a local OpenAI-compatible mock (the built-in `lmstudio` provider,
127.0.0.1:1234) whose reply embeds two GitHub-attachment image URLs, drives a real
turn, then runs `/images`. GRAFF_NO_BROWSER=1 suppresses the actual browser spawn
so the test asserts the extracted URLs without opening real tabs. Also checks the
zero-image path (no images before any turn) and that /images is discoverable.

Requires 127.0.0.1:1234 to be free (the lmstudio URL is fixed); skips otherwise.
"""

import http.server
import json
import os
import socket
import sys
import tempfile
import threading

from pty_harness import PtySession

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

IMG1 = "https://github.com/user-attachments/assets/one.png"
IMG2 = "https://github.com/user-attachments/assets/two.png"


class ChatMock:
    """Serves one fixed OpenAI chat-completion for every /v1/chat/completions."""

    def __init__(self, content: str) -> None:
        self.body = json.dumps(
            {
                "id": "cmpl-1",
                "object": "chat.completion",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": content},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 5, "completion_tokens": 10, "total_tokens": 15},
            }
        ).encode()
        parent = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", 0))
                if length:
                    self.rfile.read(length)
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(parent.body)))
                self.end_headers()
                self.wfile.write(parent.body)

            def do_GET(self) -> None:  # noqa: N802
                self.send_response(404)
                self.end_headers()

            def log_message(self, *_a) -> None:
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 1234), Handler)

    def start(self) -> None:
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


def port_free() -> bool:
    probe = socket.socket()
    try:
        probe.bind(("127.0.0.1", 1234))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def main() -> None:
    if not port_free():
        print("skip  127.0.0.1:1234 already in use")
        return

    content = f"Here are the attachments: ![one]({IMG1}) and ![two]({IMG2})."
    mock = ChatMock(content)
    mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-pty-images-") as tmp:
            env = {
                "HOME": tmp,
                "LMSTUDIO_API_KEY": "local-pty-test",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_NO_BROWSER": "1",
            }
            ambient = tuple(
                k
                for k in os.environ
                if (k.startswith("GRAFF_") or k.startswith("CODEX_") or k == "NO_COLOR")
                and k not in env
            )
            with PtySession(
                GRAFF,
                ["--model", "lmstudio", "--no-telemetry"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=20.0,
            ) as session:
                session.wait_for_prompt()

                # Zero-image path: nothing in the conversation yet.
                c0 = len(session.raw)
                session.send_line("/images")
                session.wait_for_literal("no image URLs", start=c0)

                # Drive a turn — the mock reply embeds the two image URLs.
                c1 = len(session.raw)
                session.send_line("show me the images")
                session.wait_for_literal("attachments", start=c1)

                # /images extracts both; GRAFF_NO_BROWSER=1 lists them (no spawn).
                c2 = len(session.raw)
                session.send_line("/images")
                session.wait_for_literal("found 2 images", start=c2)
                session.wait_for_literal(IMG1, start=c2)
                session.wait_for_literal(IMG2, start=c2)

                session.send_key("ctrl-d")
                result = session.read_until_exit(5.0)
                if result.timed_out or result.exit_code != 0:
                    raise SystemExit(
                        f"REPL did not exit cleanly: exit={result.exit_code} "
                        f"timed_out={result.timed_out}"
                    )
        print("ok    PTY /images extracts + lists issue image URLs (#103)")
    finally:
        mock.stop()


if __name__ == "__main__":
    main()
