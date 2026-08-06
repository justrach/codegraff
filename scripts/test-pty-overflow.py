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

#414 adds three more, covering the classifier's guard list and its two behavioral
detectors — the shapes where the provider never returns an error at all:

  C. Bedrock's "ThrottlingException: Too many tokens, please wait before trying
     again." — wording that collides with the generic "too many tokens" overflow
     fallback, but is a 429. It must ride the retry ladder; the meter must not pin.
  D. HTTP 200 with an EMPTY completion whose usage reports input at the window
     (the z.ai silent overflow). graff must classify it as overflow anyway.
  E. HTTP 200 with finish_reason=length and ZERO output at the window (MiMo
     truncating our input to fit). graff must name it, not ship a silent short answer.

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

# lmstudio/lmstudio is a CATALOGUED model (pricing.zig context_overlay), so its
# window is fixed at 200k and GRAFF_CONTEXT deliberately cannot shrink it (#203).
# The #414 behavioral fixtures report usage against this number; scenario D
# asserts the meter still reads it, so a catalog change fails loudly here.
LMSTUDIO_WINDOW = 200_000


class OpenAiErrorMock:
    """Serves one fixed OpenAI-style body for every /v1/chat/completions.

    `error_obj` is wrapped as {"error": ...}; pass a `raw` body instead to serve a
    successful (HTTP 200) completion, which is how the #414 behavioral shapes are
    reproduced — they never send an error to keyword-match.
    """

    def __init__(self, error_obj: dict | None = None, raw: dict | None = None) -> None:
        self.body = json.dumps(raw if raw is not None else {"error": error_obj}).encode()
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


def _run(error_obj: dict, tmp: str, *, raw: dict | None = None, wait_for: str = "api error:"):
    """Run one turn against a mock; return (rendered_text, hits).

    `wait_for` is the literal that marks the turn as finished — an error turn ends
    with "api error:", but a #414 behavioral-overflow turn ends with a normal
    (empty) completion and is only visible through its own notice.
    """
    mock = OpenAiErrorMock(error_obj, raw=raw)
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
            session.wait_for_literal(wait_for, start=cursor)
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

        # Scenario C (#414 guard): Bedrock's throttle wording collides head-on with
        # the generic "too many tokens" overflow fallback. It is a 429: it must ride
        # the retry ladder, never trigger a compaction.
        rendered, _ = _run(
            {
                "message": "ThrottlingException: Too many tokens, please wait before trying again.",
                "type": "throttling_error",
            },
            tmp,
        )
        if "Too many tokens" not in rendered:
            raise AssertionError(f"C: throttle error was not surfaced:\n{rendered}")
        stray = PINNED_RE.search(rendered)
        if stray:
            raise AssertionError(
                "C: a Bedrock THROTTLE was classified as context overflow — the "
                f"non-overflow guard list is not being consulted first ({stray.group(0)!r}):\n{rendered}"
            )
        print("ok    bedrock 'Too many tokens' throttle stayed on the retry path (#414 guard)")

        # Scenario D (#414): z.ai's silent overflow. HTTP 200, an EMPTY completion,
        # and usage that says the input already filled the window. Nothing in the
        # body is an error, so only the behavioral detector can catch it.
        rendered, hits = _run(
            {},
            tmp,
            raw={
                "choices": [{"index": 0, "message": {"role": "assistant", "content": ""}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": LMSTUDIO_WINDOW, "completion_tokens": 0, "total_tokens": LMSTUDIO_WINDOW},
            },
            wait_for="silent_overflow",
        )
        if hits < 1:
            raise AssertionError("D: graff never reached the backend")
        if "silent_overflow" not in rendered:
            raise AssertionError(
                f"D: an HTTP 200 with no answer and over-window usage was accepted silently:\n{rendered}"
            )
        pinned = PINNED_RE.search(rendered)
        if not pinned:
            raise AssertionError(f"D: silent overflow did not pin the meter to the window:\n{rendered}")
        if pinned.group(2) != str(LMSTUDIO_WINDOW // 1000):
            raise AssertionError(f"D: lmstudio's catalogued window moved; update LMSTUDIO_WINDOW ({pinned.group(0)!r})")
        print("ok    silent 200 (empty completion, usage at the window) classified as overflow (#414)")

        # Scenario E (#414): MiMo truncates an oversized input to fit the window,
        # then reports finish_reason=length with zero output. The reply is not a
        # real answer and must be named as such, not shipped as a short one.
        rendered, _ = _run(
            {},
            tmp,
            raw={
                "choices": [{"index": 0, "message": {"role": "assistant", "content": ""}, "finish_reason": "length"}],
                "usage": {"prompt_tokens": LMSTUDIO_WINDOW, "completion_tokens": 0, "total_tokens": LMSTUDIO_WINDOW},
            },
            wait_for="upstream_truncation",
        )
        if "upstream_truncation" not in rendered:
            raise AssertionError(f"E: upstream truncation surfaced as a silent short answer:\n{rendered}")
        print("ok    finish_reason=length with zero output at the wall reported as truncation (#414)")


if __name__ == "__main__":
    main()
