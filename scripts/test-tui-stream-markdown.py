#!/usr/bin/env python3
"""Live proof: the fullscreen TUI's markdown pipeline is safe under STREAMING.

Against the real binary, under a pty, with a mock codex backend that streams the
answer as `response.output_text.delta` events split every 1-3 codepoints — so
the splits land mid-word, mid-escape-sequence, mid-code-fence and mid-inline
marker — the probe photographs the screen TWICE:

  * mid-turn, while a slow tool runs, so the PENDING row's live tail is showing
    raw model bytes as they arrive, and
  * after the turn, when the assistant row has settled through the markdown
    renderer.

Both frames must be clean: no carriage return the model sent (a bare CR rewinds
the row and everything after it overwrites), none of the model's OWN escape
sequences (a smuggled SGR repaints the pager), no U+FFFD from a delta that cut a
glyph in half, and no text lost around any of it. The settled frame must also
show the fenced block as code with its markers hidden.

Usage: python3 scripts/test-tui-stream-markdown.py [path/to/graff]
Exit 0 = pass. Skips (exit 0, notice) with no pty support or no binary.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time

from codex_ws_mock import CodexMock, RecordedRequest

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
BOOT_MAX = 20.0
ANSWER_MAX = 30.0
ROWS, COLS = 40, 110

# A colour no graff theme paints, so finding it on the wire can only mean the
# model's own escape survived the renderer.
SMUGGLED = "\x1b[38;2;7;7;7m"
# Streamed as deltas and shown by the PENDING row's live tail while a tool runs.
# The hostile bytes sit in the last four lines — that is the tail window.
LIVE = (
    "STREAMMD_START\r\n"
    "padding prose line\r\n"
    "wiped" + SMUGGLED + "byte and a bare\rreturn\r\n"
    "日本語 \U0001f680 STREAMMD_LIVE\r\n"
)
# The settled assistant row, rendered through the markdown pipeline.
ANSWER = (
    "Here is **bold** and `code` with 日本語 \U0001f680.\r\n"
    "\r\n"
    "```zig\r\n"
    "const answer: u32 = 0x1f; // 日本語 \U0001f680\r\n"
    "```\r\n"
    "wiped" + SMUGGLED + "byte and a bare\rreturn\r\n"
    "STREAMMD_OK\r\n"
)


def deltas(text: str) -> list[dict]:
    """Cut the text into 1-3 codepoint deltas — the finest split a JSON event
    stream can express. Boundaries land mid-word, mid-escape-sequence, mid-fence
    and mid-inline-marker. (A split INSIDE a UTF-8 sequence is a transport-level
    event a JSON string cannot carry; the unit suite fuzzes that byte-wise.)"""
    out, i, n = [], 0, 1
    while i < len(text):
        piece = text[i : i + n]
        i += n
        n = n % 3 + 1
        out.append({"type": "response.output_text.delta", "delta": piece})
    return out


def completed(response_id: str) -> dict:
    return {
        "type": "response.completed",
        "response": {
            "id": response_id,
            "usage": {
                "input_tokens": 10,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens": 10,
                "total_tokens": 20,
            },
        },
    }


def events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        # Prose first, then a slow tool call: the turn stays open long enough to
        # photograph the live tail, which is where raw model bytes land.
        return [
            *deltas(LIVE),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "id": "fc_streammd",
                    "call_id": "call_streammd",
                    "name": "bash",
                    "arguments": json.dumps({"command": "sleep 6"}),
                    "status": "completed",
                },
            },
            completed("resp_streammd_live"),
        ]
    item = {
        "type": "message",
        "id": "msg_streammd",
        "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": ANSWER, "annotations": []}],
    }
    return [
        *deltas(ANSWER),
        {"type": "response.output_item.done", "item": item},
        completed("resp_streammd_done"),
    ]


def drain(fd, seconds):
    import select

    out = b""
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], min(0.1, max(end - time.time(), 0.01)))
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out


def resize(fd, rows, cols):
    import fcntl
    import struct
    import termios

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def boot(fd):
    out = b""
    end = time.time() + BOOT_MAX
    while time.time() < end:
        out += drain(fd, 0.3)
        if b"\x1b[?1049h" in out:
            return out + drain(fd, 1.5)
    return out


def wait_for(fd, needle, seconds):
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        out += drain(fd, 0.3)
        if needle.encode() in out:
            return out
    return None


def spawn(cwd, env_extra, unset):
    import pty

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        for name in unset:
            os.environ.pop(name, None)
        os.environ.update(env_extra)
        os.execv(BIN, [BIN, "tui", "--yolo", "--model", "codex", "--no-telemetry"])
    resize(fd, ROWS, COLS)
    return pid, fd


def reap(pid, fd):
    import signal

    try:
        os.write(fd, b"\x11")  # Ctrl+Q
        drain(fd, 2.0)
    except OSError:
        pass
    for call in (lambda: os.kill(pid, signal.SIGKILL), lambda: os.waitpid(pid, 0)):
        try:
            call()
        except OSError:
            pass


def full_frame(fd):
    """The bytes of one FORCED full repaint, plus its visible rows."""
    resize(fd, ROWS - 1, COLS)
    drain(fd, 0.4)
    resize(fd, ROWS, COLS)
    stream = drain(fd, 1.5)
    parts = stream.rsplit(b"\x1b[2J\x1b[H", 1)
    if len(parts) < 2:
        return None, None
    raw = parts[1]
    text = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", raw)
    text = re.sub(rb"\x1b\[[0-9;?<>]*[a-zA-Z]", b"", text)
    return raw, [ln.decode(errors="replace") for ln in text.split(b"\r\n")]


def workspace(tmp, port):
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "streammd-mock", "account_id": "acct-md"}}, fh)
    harness = os.path.join(tmp, ".harness")
    os.makedirs(harness)
    with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)
    empty_mcp = os.path.join(tmp, "empty-mcp.json")
    with open(empty_mcp, "w", encoding="utf-8") as fh:
        fh.write('{"mcpServers": {}}')
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
        "GRAFF_CODEX_WS": "off",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_MCP_CONFIG": empty_mcp,
        "GRAFF_LEARN_AUTO": "off",
    }
    unset = tuple(
        name
        for name in os.environ
        if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
        and name not in env
    )
    return env, unset


def hostile_clean(raw, body, where):
    """The three ways raw model bytes corrupt a row, checked on one frame."""
    # 1. no carriage return the model sent — the pager's own row breaks are
    #    \r\n (doubled to \r\r\n by the pty's ONLCR), so a CR that does not lead
    #    into a line feed can only have come from the model's text.
    if re.search(rb"\r(?!\r*\n)", raw):
        return f"{where}: a bare carriage return from the model reached the frame"
    # 2. none of the model's own escapes, as bytes or as leftover text.
    if SMUGGLED.encode() in raw:
        return f"{where}: the model's own SGR escape reached the terminal"
    if "[38;2;7;7;7m" in body:
        return f"{where}: the model's escape landed as literal text instead"
    # 3. every glyph whole on both sides of a delta boundary.
    if "�" in body:
        return f"{where}: a delta boundary left a replacement character on screen"
    for glyph in ("日本語", "\U0001f680"):
        if glyph not in body:
            return f"{where}: {glyph!r} did not survive the stream"
    if "wiped" not in body or "byte and a bare" not in body:
        return f"{where}: text around the smuggled escape was lost"
    return None


def check_live(raw, rows):
    body = "\n".join(rows)
    if "STREAMMD_LIVE" not in body:
        return f"the live tail never showed the streamed prose: {rows[:12]!r}"
    return hostile_clean(raw, body, "live tail")


def check_settled(raw, rows):
    body = "\n".join(rows)
    if "STREAMMD_OK" not in body:
        return f"the streamed answer never settled on screen: {rows[:12]!r}"
    err = hostile_clean(raw, body, "settled row")
    if err:
        return err
    # 4. the fence rendered as code: tokens on screen, markers hidden.
    if "const answer" not in body.replace("  ", " "):
        return "the fenced code line never rendered"
    if "```" in body:
        return "a raw fence marker leaked onto the screen"
    return None


def run():
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-stream-md-") as tmp:
            env, unset = workspace(tmp, port)
            pid, fd = spawn(tmp, env, unset)
            try:
                boot(fd)
                os.write(fd, b"stream some markdown\r")
                # Mid-turn: the tool is sleeping, so the live tail is on screen.
                if wait_for(fd, "STREAMMD_LIVE", ANSWER_MAX) is None:
                    return "the live tail never showed the streamed prose"
                raw, rows = full_frame(fd)
                if rows is None:
                    return "no full repaint to read the live tail from"
                err = check_live(raw, rows)
                if err:
                    return err
                # …and then the settled assistant row.
                if wait_for(fd, "STREAMMD_OK", ANSWER_MAX) is None:
                    return "the turn never produced its streamed answer"
                drain(fd, 1.0)
                raw, rows = full_frame(fd)
                if rows is None:
                    return "no full repaint to read the settled row from"
                return check_settled(raw, rows)
            finally:
                reap(pid, fd)
    finally:
        mock.stop()


def main():
    if not os.path.exists(BIN):
        print(f"tui-stream-markdown: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-stream-markdown: no pty support here — skipping")
        return 0
    err = run()
    if err:
        print(f"  ✗ stream markdown: {err}")
        return 1
    print("  ✓ stream markdown: live tail AND settled row survive chunked deltas — no CR, no smuggled SGR, glyphs whole")
    return 0


if __name__ == "__main__":
    sys.exit(main())
