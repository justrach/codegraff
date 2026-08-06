#!/usr/bin/env python3
"""Golden byte-identity harness: prove a refactor changed no rendered output.

Drives a real PTY session against a scripted model at several pane widths and
captures the exact bytes the terminal received, for two graff binaries. A
refactor that claims to be behavior-preserving has to produce an empty diff.

Every capture window is deterministic by construction (see the settle rule in
README.md), and `--self-check` proves that before any comparison is believed:
if the same binary twice does not agree, a before/after diff means nothing.

    export GRAFF_EVAL_BEFORE=/path/to/base-worktree/zig-out/bin/graff
    export GRAFF_EVAL_AFTER=/path/to/change-worktree/zig-out/bin/graff
    python3 run_golden.py

Exit status is 0 only when the self-check passed and the two arms are
byte-identical, so this is usable as a gate.
"""
from __future__ import annotations

import argparse
import filecmp
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent
RUNS = ROOT / "runs"
# scripts/eval/golden -> scripts, where the shared PTY driver lives.
sys.path.insert(0, str(ROOT.parents[1]))

from pty_harness import PtySession, terminal_text  # noqa: E402

# Same variable names the live-ab harness uses, so the two instruments share
# one convention. Resolution is lazy: capturing a single arm needs only that
# arm's variable set.
BIN_ENV = {"before": "GRAFF_EVAL_BEFORE", "after": "GRAFF_EVAL_AFTER"}

PORT = int(os.environ.get("GRAFF_EVAL_PORT", "1234"))
MODEL = os.environ.get("GRAFF_EVAL_MODEL", "lmstudio")


def binary_path(arm: str) -> str:
    env_name = BIN_ENV[arm]
    path = os.environ.get(env_name)
    if not path:
        sys.exit(
            "%s is unset. Point it at the %r arm's graff binary, e.g.\n"
            "  %s=/path/to/worktree/zig-out/bin/graff" % (env_name, arm, env_name)
        )
    if not os.path.isfile(path):
        sys.exit("%s=%s is not a file" % (env_name, path))
    return path


# ── the scripted model ───────────────────────────────────────────────────────
# Deliberately not scripts/eval/mock_model.py: this one reports a large prompt
# count AND a cached count, so the status line's context meter and its cache
# badge both render and are covered. A mock that reports 8 tokens and no cache
# leaves both segments blank and the goldens prove nothing about them.

USAGE = {
    "prompt_tokens": 12345,
    "completion_tokens": 4,
    "total_tokens": 12349,
    "prompt_tokens_details": {"cached_tokens": 2048},
}
ANSWER = "golden answer"


class MockModel:
    def __init__(self) -> None:
        self._server: http.server.ThreadingHTTPServer | None = None

    def start(self) -> None:
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _send(self, payload: bytes, content_type: str) -> None:
                self.send_response(200)
                self.send_header("content-type", content_type)
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self) -> None:  # noqa: N802  (/v1/models probes)
                self._send(json.dumps({"data": [{"id": "mock"}]}).encode(), "application/json")

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", 0))
                body: dict[str, Any] = {}
                if length:
                    try:
                        body = json.loads(self.rfile.read(length))
                    except (ValueError, UnicodeDecodeError):
                        body = {}
                if body.get("stream"):
                    self._stream()
                else:
                    self._send(json.dumps({
                        "id": "mock", "object": "chat.completion", "model": "mock",
                        "choices": [{
                            "index": 0,
                            "message": {"role": "assistant", "content": ANSWER},
                            "finish_reason": "stop",
                        }],
                        "usage": USAGE,
                    }).encode(), "application/json")

            def _stream(self) -> None:
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("cache-control", "no-cache")
                self.send_header("connection", "close")
                self.end_headers()
                self._chunk({"choices": [{
                    "index": 0,
                    "delta": {"role": "assistant", "content": ANSWER},
                    "finish_reason": None,
                }]})
                self._chunk({
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    "usage": USAGE,
                })
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True

            def _chunk(self, payload: dict[str, Any]) -> None:
                framed = dict(payload, id="mock", object="chat.completion.chunk", model="mock")
                self.wfile.write(b"data: " + json.dumps(framed).encode() + b"\n\n")

            def log_message(self, *_args) -> None:
                pass

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None


# ── the session script ───────────────────────────────────────────────────────
# A step either captures a window or does not. `wait` is a literal to wait for
# before settling; `settle` is the quiet period that must elapse BEFORE the
# next window opens (see README: the capture-window race).
#
# The model turn is deliberately NOT captured: a live turn spins the thinking
# spinner, whose frame count is wall-clock dependent. Running it first and
# capturing afterwards means every window below shows a status line with the
# context meter and cache badge populated, with no spinner byte inside it.

STEPS = [
    {"name": "01-prompt-clean", "send": "/thinking off", "settle": 1.0},
    {"name": None, "send": "say hello", "wait": ANSWER, "settle": 1.5},
    {"name": "02-skills-list", "send": "/skills", "wait": "re-enable", "settle": 0.8},
    {"name": "03-skills-remove", "send": "/skills remove skill-creator", "settle": 1.0},
    {"name": "04-skills-after-remove", "send": "/skills", "wait": "re-enable", "settle": 0.8},
    {"name": "05-skills-add", "send": "/skills add skill-creator", "settle": 1.0},
    {"name": "06-skills-unknown", "send": "/skills remove no-such-skill", "settle": 1.0},
]

# Widths chosen to straddle the #209 status-line budget: 160 keeps every
# segment, 60 forces low-priority metadata out, 34 is the pathological pane.
WIDTHS = [("wide", 160), ("narrow", 60), ("tiny", 34)]


def workspace() -> str:
    """A FIXED path, never mkdtemp.

    The cwd string is rendered into the status line and its LENGTH feeds the
    width budget, so a per-run temp name would move the layout between arms and
    produce diffs that are pure harness noise.
    """
    ws = RUNS / "_ws"
    shutil.rmtree(ws, ignore_errors=True)
    ws.mkdir(parents=True)
    return str(ws)


def env_for(ws: str) -> dict[str, str]:
    return {
        "HOME": ws,
        "LMSTUDIO_API_KEY": "local",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_NO_SMOLIFY": "1",
        # Pinned: the privacy badge is one of the status-line segments, so an
        # inherited setting would move the layout.
        "GRAFF_LEARNING_PRIVACY": "aggregate",
        "TERM": "xterm-256color",
    }


def dump(outdir: pathlib.Path, name: str, raw: bytes) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / (name + ".raw")).write_bytes(raw)
    (outdir / (name + ".txt")).write_text(terminal_text(raw), encoding="utf-8")


def scenario(graff: str, outdir: pathlib.Path, label: str, cols: int) -> None:
    ws = workspace()
    with PtySession(
        graff,
        ["--model", MODEL, "--no-telemetry"],
        cwd=ws,
        env=env_for(ws),
        unset_env=("CODEX_HOME",),
        color=True,
        timeout=30.0,
        rows=40,
        cols=cols,
    ) as s:
        s.wait_for_literal("] ›")
        # Let readline's terminal setup (bracketed paste, the DSR cursor probe)
        # land BEFORE the first window opens. Without this those 12 bytes fall
        # on one side or the other of the cursor by luck. See README.
        s.pump_for(1.0)

        for step in STEPS:
            cursor = len(s.raw)
            s.send_line(step["send"])
            if step.get("wait"):
                s.wait_for_literal(step["wait"], start=cursor)
            s.pump_for(step["settle"])
            if step["name"]:
                dump(outdir, "%s-%s" % (label, step["name"]), bytes(s.raw[cursor:]))

        s.send_key("ctrl-d")
        result = s.read_until_exit(8.0)
        if result.exit_code != 0:
            sys.exit("%s: unclean exit %s timed_out=%s"
                     % (label, result.exit_code, result.timed_out))


def static_captures(graff: str, outdir: pathlib.Path) -> None:
    """Non-PTY surfaces that must not move either."""
    ws = workspace()
    for name, argv in (("static-help", ["--help"]), ("static-schema", ["--schema"])):
        proc = subprocess.run([graff, *argv], cwd=ws,
                              env={**os.environ, **env_for(ws)},
                              capture_output=True, timeout=60)
        dump(outdir, name, proc.stdout)


def capture(graff: str, outdir: pathlib.Path, quiet: bool = False) -> pathlib.Path:
    shutil.rmtree(outdir, ignore_errors=True)
    model = MockModel()
    model.start()
    try:
        static_captures(graff, outdir)
        for label, cols in WIDTHS:
            scenario(graff, outdir, label, cols)
            if not quiet:
                print("  captured %s (%d cols)" % (label, cols), flush=True)
    finally:
        model.stop()
    return outdir


def compare(a: pathlib.Path, b: pathlib.Path, a_name: str, b_name: str) -> bool:
    names = sorted({p.name for p in a.iterdir()} | {p.name for p in b.iterdir()})
    match, mismatch, errors = filecmp.cmpfiles(a, b, names, shallow=False)
    if not mismatch and not errors:
        print("  %d artifacts identical (%s vs %s)" % (len(match), a_name, b_name))
        return True
    for name in mismatch:
        ra, rb = (a / name).read_bytes(), (b / name).read_bytes()
        print("  DIFFER %s  (%s: %d bytes, %s: %d bytes)"
              % (name, a_name, len(ra), b_name, len(rb)))
    for name in errors:
        print("  MISSING %s in one arm" % name)
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arm", choices=sorted(BIN_ENV), action="append",
                    help="capture only this arm (repeatable); default is both")
    ap.add_argument("--skip-self-check", action="store_true",
                    help="skip the same-binary-twice determinism proof (not recommended)")
    ap.add_argument("--diff-only", action="store_true",
                    help="compare existing captures under runs/ without re-capturing")
    args = ap.parse_args()

    arms = args.arm or ["before", "after"]
    RUNS.mkdir(parents=True, exist_ok=True)

    if args.diff_only:
        a, b = RUNS / "before", RUNS / "after"
        if not a.is_dir() or not b.is_dir():
            sys.exit("no captures under %s -- run without --diff-only first" % RUNS)
        print("== diff ==")
        return 0 if compare(a, b, "before", "after") else 1

    # The determinism proof comes FIRST and gates everything after it. A
    # before/after diff is only evidence if the instrument itself is stable,
    # and PTY capture has several ways not to be.
    if not args.skip_self_check:
        probe = arms[0]
        print("== self-check: %s binary captured twice ==" % probe)
        graff = binary_path(probe)
        capture(graff, RUNS / "_selfcheck-a", quiet=True)
        capture(graff, RUNS / "_selfcheck-b", quiet=True)
        if not compare(RUNS / "_selfcheck-a", RUNS / "_selfcheck-b", "run 1", "run 2"):
            print("\nthe harness is NOT deterministic on this machine; a "
                  "before/after diff would be meaningless. Fix this first.")
            return 1

    for arm in arms:
        print("== capture: %s ==" % arm)
        capture(binary_path(arm), RUNS / arm)

    if len(arms) < 2:
        print("\ncaptured %s only; re-run with both arms to compare." % arms[0])
        return 0

    print("== diff ==")
    if not compare(RUNS / "before", RUNS / "after", "before", "after"):
        print("\nrendered output CHANGED. If that was intended, say so "
              "explicitly; otherwise the refactor is not behavior-preserving.")
        return 1
    print("\nbyte-identical: the change is behavior-preserving for these surfaces.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
