#!/usr/bin/env python3
"""Live proof for #551: the fullscreen TUI renders tool activity from the
engine's TYPED events, not from glyphs scraped out of rendered text.

Against the real binary, under a pty, with a mock provider driving a real tool
loop (no network, no model), the probe:

  1. boots `graff tui --yolo --model codex` in a scratch cwd with an EMPTY MCP
     config, pointed at scripts/codex_ws_mock,
  2. sends one prompt; the mock answers with a `read_file` function call and
     then a final message whose FIRST LINE STARTS WITH "✓ " — exactly the shape
     that used to be harvested into the transcript as a phantom tool row,
  3. forces a full repaint and reads the screen,
  4. asserts the real tool run folded into exactly ONE summary row,
  5. asserts the answer's "✓ " line appears exactly once and never as a tool
     row, and that no raw "⚙ /✓ tool | preview" sink line reached the screen.

Usage: python3 scripts/test-tui-typed-events.py [path/to/graff]
Exit 0 = pass. Skips (exit 0, notice) with no pty support.
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

# The answer deliberately opens with a status glyph: this is the phantom-row
# shape. It must render as ANSWER text, once, and never as a tool row.
GLYPH_LINE = "✓ verified TYPEDEV_OK"
FINAL_REPLY = GLYPH_LINE + "\nall three checks passed"
NOTE_BODY = "typed-events-probe payload"


def message_item(text: str, item_id: str) -> dict:
    return {
        "type": "message",
        "id": item_id,
        "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }


def response_events(item: dict, response_id: str) -> list[dict]:
    return [
        {"type": "response.output_item.done", "item": item},
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": 100,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": 10,
                    "total_tokens": 110,
                },
            },
        },
    ]


def events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        return response_events(
            {
                "type": "function_call",
                "id": "fc_typed_read",
                "call_id": "call_typed_read",
                "name": "read_file",
                "arguments": json.dumps({"path": "note.txt"}),
                "status": "completed",
            },
            "resp_typed_read",
        )
    return response_events(message_item(FINAL_REPLY, "msg_typed_done"), "resp_typed_done")


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
    """Screen rows, in order, from a FORCED full repaint (see #529's probe)."""
    resize(fd, ROWS - 1, COLS)
    drain(fd, 0.4)
    resize(fd, ROWS, COLS)
    stream = drain(fd, 1.5)
    frame = stream.rsplit(b"\x1b[2J\x1b[H", 1)
    if len(frame) < 2:
        return None
    text = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", frame[1])
    text = re.sub(rb"\x1b\[[0-9;?<>]*[a-zA-Z]", b"", text)
    return [ln.decode(errors="replace") for ln in text.split(b"\r\n")]


def workspace(tmp, port):
    with open(os.path.join(tmp, "note.txt"), "w", encoding="utf-8") as fh:
        fh.write(NOTE_BODY)
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "typed-events-mock", "account_id": "acct-typed"}}, fh)
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


def summary_rows(rows):
    return [i for i, ln in enumerate(rows) if "Called" in ln and "tool" in ln]


def check_folded(rows):
    body = "\n".join(rows)
    if "TYPEDEV_OK" not in body:
        return "the final answer never rendered"
    # 1. The real tool run folded into exactly ONE summary row, counting the
    #    two typed rows of one call (invocation + outcome) and nothing else.
    #    The scraping path counted the answer's "✓ " line as a third row.
    hits = summary_rows(rows)
    if len(hits) != 1:
        return f"expected exactly one folded tool summary, got {[rows[i] for i in hits]!r}"
    summary = rows[hits[0]].strip()
    if not re.search(r"Called 2 tools\b", summary):
        return f"the summary counted something other than the one real call: {summary!r}"
    # 2. The answer's status-glyph line is on screen exactly once...
    answers = [ln for ln in rows if GLYPH_LINE in ln]
    if len(answers) != 1:
        return f"the answer's '✓ ' line appears {len(answers)} time(s): {answers!r}"
    # 3. ...and it is not the summary row itself.
    if GLYPH_LINE in summary:
        return "the answer line was folded into the tool summary"
    # 4. No raw sink line ("⚙ read note.txt") reached the screen: that is
    #    hostedEmit's rendering, which the TUI must no longer consume.
    for ln in rows:
        if ln.strip().startswith("⚙ "):
            return f"a raw sink glyph line leaked into the transcript: {ln!r}"
    return None


def check_expanded(rows):
    """The card the fold opens onto is built from FIELDS: the engine's tool
    name, its argument, and the result preview — none of it recovered by
    splitting a rendered line."""
    if summary_rows(rows):
        return "the click did not expand the tool group"
    # The head is `◆ <displayName(name)>  <compactArg(input)>`: read_file
    # shortened to "read", the path taken from the call's JSON argument.
    head = next((i for i, ln in enumerate(rows) if re.search(r"◆\s+read {2}note\.txt\s*$", ln)), None)
    if head is None:
        return f"no field-backed card head on screen: {rows[:8]!r}"
    # The body under it is the outcome's result preview, in the card gutter.
    if head + 1 >= len(rows) or "│" not in rows[head + 1] or NOTE_BODY not in rows[head + 1]:
        return f"the card body is not the result preview: {rows[head:head + 2]!r}"
    # The answer stayed outside the card.
    if GLYPH_LINE in rows[head] or GLYPH_LINE in rows[head + 1]:
        return "the answer line is inside the tool card"
    return None


def run():
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-typed-events-") as tmp:
            env, unset = workspace(tmp, port)
            pid, fd = spawn(tmp, env, unset)
            try:
                boot(fd)
                os.write(fd, b"read note.txt then report\r")
                if wait_for(fd, "TYPEDEV_OK", ANSWER_MAX) is None:
                    return "the turn never produced its final answer"
                drain(fd, 1.0)
                rows = full_frame(fd)
                if rows is None:
                    return "no full repaint to read the screen from"
                err = check_folded(rows)
                if err:
                    return err
                # Open the group: a plain click on the summary row. What comes
                # back is the card composed from the typed fields.
                top = summary_rows(rows)[0] + 1  # SGR rows are 1-based
                os.write(fd, f"\x1b[<0;5;{top}M".encode())
                drain(fd, 0.3)
                os.write(fd, f"\x1b[<0;5;{top}m".encode())
                drain(fd, 0.6)
                opened = full_frame(fd)
                if opened is None:
                    return "no full repaint after expanding the tool group"
                err = check_expanded(opened)
                if err:
                    return err
            finally:
                reap(pid, fd)
        requests = mock.recorded_requests()
        if len(requests) != 2:
            return f"expected a two-request tool loop, got {len(requests)}"
        return None
    finally:
        mock.stop()


def main():
    if not os.path.exists(BIN):
        print(f"tui-typed-events: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-typed-events: no pty support here — skipping")
        return 0
    err = run()
    if err:
        print(f"  ✗ typed events: {err}")
        return 1
    print("  ✓ typed events: one folded tool summary, answer glyph line rendered once, no scraped lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
