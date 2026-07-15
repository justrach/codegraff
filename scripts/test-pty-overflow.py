#!/usr/bin/env python3
"""End-to-end real-PTY test for anthropic/openai context-overflow handling (#201-#203).

Points graff at a local OpenAI-compatible backend (the built-in `lmstudio` provider,
http://127.0.0.1:1234) whose only reply is an injected error, and drives a real turn
through the terminal. Two scenarios prove the overflow detection is BOTH correct and
precise:

  A. error.code = context_length_exceeded with a message that matches none of the
     English substrings (Dutch). graff must still detect the overflow via the
     STRUCTURED code (#203/G2), pin the meter to the window, and stay responsive
     rather than wedge (#201/#202). Observable: the prompt's ctx meter reads
     "<W>k/<W>k ctx (100% ...)".
  B. error.code = rate_limit_exceeded with a non-overflow message. graff must NOT
     mistake it for an overflow: the meter must not pin. Proves detection is precise.

Requires 127.0.0.1:1234 to be free (the lmstudio provider URL is fixed); skips if a
real LM Studio (or anything) already holds it.
"""

import http.server
import json
import os
import re
import socket
import sys
import tempfile
import threading

from pty_harness import PtySession, terminal_text


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

# "<used>k/<window>k ctx (<pct>% · compact@<X>k)" — the "·" is U+00B7.
METER_RE = re.compile(r"(\d+)k/(\d+)k ctx \((\d+)% · compact@(\d+)k\)")
PINNED_RE = re.compile(r"(\d+)k/(\d+)k ctx \(100% · compact@\d+k\)")


class OpenAiErrorMock:
    """Serves one fixed OpenAI-style error envelope for every /v1/chat/completions."""

    def __init__(self, error_obj: dict) -> None:
        self.body = json.dumps({"error": error_obj}).encode()
        self.hits = 0
        parent = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                parent.hits += 1
                length = int(self.headers.get("content-length", 0))
                if length:
                    self.rfile.read(length)
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(parent.body)))
                self.end_headers()
                self.wfile.write(parent.body)

            def do_GET(self) -> None:  # noqa: N802 (e.g. a /v1/models probe)
                self.send_response(404)
                self.end_headers()

            def log_message(self, *_a) -> None:  # silence the default stderr logging
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 1234), Handler)

    def start(self) -> None:
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


def _run(error_obj: dict, tmp: str):
    """Run one turn against a mock returning error_obj; return (rendered_text, hits)."""
    mock = OpenAiErrorMock(error_obj)
    mock.start()
    try:
        env = {
            "HOME": tmp,
            "LMSTUDIO_API_KEY": "local-pty-test",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
        }
        ambient = tuple(
            k for k in os.environ
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
            session.wait_for_literal("] ›")
            cursor = len(session.raw)
            session.send_line("hello")
            # The turn ends with an api error either way; wait for it, then settle.
            session.wait_for_literal("api error:", start=cursor)
            session.pump_for(1.5)
            rendered = terminal_text(bytes(session.raw[cursor:]))

            # Session must remain usable after the failed turn (no wedge): a local
            # command still works and the REPL exits cleanly.
            c2 = len(session.raw)
            session.send_line("/help")
            session.wait_for_literal("/models [health]", start=c2)
            session.send_key("ctrl-d")
            result = session.read_until_exit(5.0)
            if result.timed_out or result.exit_code != 0:
                raise SystemExit(
                    f"REPL did not exit cleanly: exit={result.exit_code} "
                    f"timed_out={result.timed_out}"
                )
            return rendered, mock.hits
    finally:
        mock.stop()


def main() -> None:
    # The lmstudio provider URL is hardcoded to :1234; bail cleanly if it's taken.
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # SO_REUSEADDR binds over a TIME_WAIT port left by a prior run, but still fails
    # against a real LISTENing server — so back-to-back runs work, a live LM Studio skips.
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        probe.bind(("127.0.0.1", 1234))
    except OSError:
        print("skip  127.0.0.1:1234 is in use (real LM Studio?) — overflow PTY test skipped")
        return
    finally:
        probe.close()

    with tempfile.TemporaryDirectory(prefix="graff-pty-overflow-") as tmp:
        # Disable the AI tab-titler so it doesn't fire an extra quiet turn.
        harness = os.path.join(tmp, ".harness")
        os.makedirs(harness, exist_ok=True)
        with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
            json.dump({"ai_title": False}, fh)

        # Scenario A: structured overflow code, message matches NO English substring.
        dutch = "de aanvraag overschrijdt het maximale vensterformaat van dit model"
        rendered, hits = _run(
            {"message": dutch, "type": "invalid_request_error", "code": "context_length_exceeded"},
            tmp,
        )
        if hits < 1:
            raise AssertionError("A: graff never reached the backend")
        if "api error" not in rendered or dutch not in rendered:
            raise AssertionError(f"A: overflow error was not surfaced:\n{rendered}")
        pinned = PINNED_RE.search(rendered)
        if not pinned:
            raise AssertionError(
                "A: meter did not pin to the window — the structured error.code "
                f"(context_length_exceeded) was not detected as overflow (#203/G2):\n{rendered}"
            )
        m = METER_RE.search(rendered)
        if m.group(1) != m.group(2):
            raise AssertionError(f"A: meter used != window despite pin: {m.group(0)!r}")
        print(f"ok    overflow-by-code detected end to end; meter pinned to {m.group(2)}k (100%)")

        # Scenario B: a non-overflow code + non-overflow message must NOT pin.
        rendered, _ = _run(
            {"message": "too many requests", "type": "rate_limit_error", "code": "rate_limit_exceeded"},
            tmp,
        )
        if "too many requests" not in rendered:
            raise AssertionError(f"B: rate-limit error was not surfaced:\n{rendered}")
        stray = PINNED_RE.search(rendered)
        if stray:
            raise AssertionError(
                "B: meter pinned on a NON-overflow error — detection is not precise "
                f"({stray.group(0)!r}):\n{rendered}"
            )
        print("ok    non-overflow error did not pin the meter (detection is precise)")


if __name__ == "__main__":
    main()
