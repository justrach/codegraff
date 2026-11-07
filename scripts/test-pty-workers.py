#!/usr/bin/env python3
"""Exercise the actual REPL inspector with offline sample activity, not agents."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from pty_harness import PtySession, terminal_text


def seed(home, pid):
    registry = home / ".graff/live"
    matches = list(registry.glob(str(pid) + "-*.json"))
    if len(matches) != 1:
        raise AssertionError("Missing own-process presence identity")
    parent = json.loads(matches[0].read_text())
    directory = registry / ("activity-%d-%x" % (pid, parent["start_id"]))
    directory.mkdir(mode=0o700)
    samples = (
        ("sample-review", "Review terminal rendering", "working"),
        ("sample-tests", "Check narrow terminals", "completed"),
        ("sample-error", "Inspect error handling", "failed"),
    )
    for index, (ident, label, status) in enumerate(samples):
        meta = {"id": ident, "label": label, "task": "Inspect the **terminal** boundary.",
                "model": "sample-model", "status": status, "updatedAt": 30 - index}
        data = {"agent": meta, "events": [
            {"type": "tool_call", "id": "read-1", "name": "read_file", "text": "example.zig"},
            {"type": "tool_result", "id": "read-1", "name": "read_file", "text": "Expanded tool sample"},
            {"type": "reasoning", "text": "Emitted thought sample"},
        ], "response": "## Findings\nThe **layout** is readable.\n- *Emphasis* renders without markers.\n- `code` stays distinct.\n"}
        (directory / (ident + ".meta")).write_text(json.dumps(meta))
        (directory / (ident + ".json")).write_text(json.dumps(data))
    return directory


def capture_frame(session, start, path):
    # A single flush can cross several PTY reads. Wait for the last frame's
    # footer reset rather than capturing as soon as an early body word arrives.
    deadline = time.monotonic() + session.timeout
    while True:
        raw = bytes(session.raw[start:])
        offset = raw.rfind(b"\x1b[2J\x1b[H")
        frame = raw[offset:] if offset >= 0 else b""
        footer = frame.rfind(("\x1b[%d;1H" % session.rows).encode())
        if footer >= 0 and b"\x1b[0m" in frame[footer:]:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError("Inspector did not finish its frame")
        session.pump(min(0.05, remaining))
    if path:
        path.with_suffix(".ansi").write_bytes(frame)
        path.with_suffix(".txt").write_text(terminal_text(frame))
    return frame


def exercise(binary, cols, captures):
    with tempfile.TemporaryDirectory(prefix="graff-workers-") as tmp:
        base = Path(tmp)
        home, work = base / "home", base / "workspace"
        (home / ".harness").mkdir(parents=True)
        work.mkdir()
        subprocess.run(["git", "init", "--quiet", str(work)], check=True)
        (home / ".harness/settings.json").write_text('{"ai_title":false,"session_recap":false,"skills":{"codedbpro":false}}')
        config = home / "empty-mcp.json"
        config.write_text('{"mcpServers":{}}')
        unset = tuple(k for k in os.environ if any(s in k.upper() for s in
                      ("API_KEY", "ACCESS_TOKEN", "AUTH_TOKEN"))) + ("CODEX_HOME", "NO_COLOR")
        env = {"HOME": str(home), "GRAFF_FLEET": "off", "GRAFF_LEARN_AUTO": "off",
               "GRAFF_MCP_CONFIG": str(config), "GRAFF_NO_TELEMETRY": "1"}
        # Supply only a synthetic key after inherited credentials are removed.
        unset = tuple(k for k in unset if k != "CODEGRAFF_API_KEY")
        env["CODEGRAFF_API_KEY"] = "offline-worker-test"
        with PtySession(binary, ["--model", "deepseek-v4-pro", "--no-telemetry"],
                        cwd=str(work), env=env, unset_env=unset, timeout=20,
                        rows=24, cols=cols) as session:
            session.wait_for_prompt(timeout=60)
            directory = seed(home, session.pid)
            cursor = len(session.raw)
            session.send_line("/workers")
            session.wait_for_literal("recent agents", start=cursor)
            session.wait_for_literal("Enter inspect", start=cursor)
            list_path = captures / ("workers-list-%d" % cols) if captures else None
            listing = capture_frame(session, cursor, list_path)
            if b"\x1b[?1000h" not in session.raw[cursor:]:
                raise AssertionError("Mouse reporting was not enabled")
            for label in ("Review terminal", "Check narrow", "Inspect error"):
                if label not in terminal_text(listing):
                    raise AssertionError("Missing sample card: " + label)

            # A real SGR mouse press, deliberately fragmented across writes.
            cursor = len(session.raw)
            session.send(b"\x1b[<0;3;")
            session.send(b"4M")
            session.wait_for_literal("terminal boundary", start=cursor)
            detail_path = captures / ("workers-detail-%d" % cols) if captures else None
            details = capture_frame(session, cursor, detail_path)
            visible = terminal_text(details)
            if "Emphasis renders without markers." not in visible:
                raise AssertionError("Markdown report did not render")
            if "Expanded tool sample" in visible or "Emitted thought sample" in visible:
                raise AssertionError("Details expanded without a request")
            cursor = len(session.raw)
            session.send_text("t")
            session.wait_for_literal("Expanded tool sample", start=cursor)
            cursor = len(session.raw)
            session.send_text("h")
            session.wait_for_literal("Emitted thought sample", start=cursor)
            cursor = len(session.raw)
            session.send_key("esc")
            session.wait_for_literal("recent agents", start=cursor)

            # Refresh an existing snapshot while the browser stays open.
            path = directory / "sample-review.meta"
            meta = json.loads(path.read_text())
            meta["label"] = "Updated live sample"
            path.write_text(json.dumps(meta))
            cursor = len(session.raw)
            session.send_text("r")
            session.wait_for_literal("Updated live sample", start=cursor)
            cursor = len(session.raw)
            session.send_text("q")
            session.wait_for_prompt(start=cursor)
            restored = bytes(session.raw[cursor:])
            for mode in (b"\x1b[?1000l", b"\x1b[?1006l", b"\x1b[?1049l", b"\x1b[?25h"):
                if mode not in restored:
                    raise AssertionError("Inspector did not restore terminal mode")

            cursor = len(session.raw)
            session.send_line("/workers ../invalid")
            session.wait_for_literal("usage: /workers [child-id]", start=cursor)
            session.wait_for_prompt(start=cursor)
            cursor = len(session.raw)
            session.send_line("/version")
            session.wait_for_prompt(start=cursor)
            session.send_key("ctrl-d")
            result = session.read_until_exit(5)
            if result.timed_out or result.exit_code != 0:
                raise AssertionError("REPL did not exit cleanly after inspection")
            print("ok    %d columns: click, Markdown, disclosures, live refresh, Esc, cleanup, next command" % cols)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", nargs="?", default="zig-out/bin/graff")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    if args.capture_dir:
        args.capture_dir.mkdir(parents=True, exist_ok=True)
    for cols in (96, 40):
        exercise(binary, cols, args.capture_dir)


if __name__ == "__main__":
    main()
