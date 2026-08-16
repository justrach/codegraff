#!/usr/bin/env python3
"""Fold headers read like grok-build's: a verb, a count, and a tense.

Drives a REAL tool loop against the codex mock (no network, no model) on a
virtual screen (scripts/ptyharness.py), and reads the header row back at three
moments the user actually experiences:

  1. mid-call   — the run is announced and has not come back, so the header is
                  present-progressive with an ellipsis: "Running bash…"
  2. on settle  — the last outcome lands and the header flips to past tense
                  ("Ran bash") wearing the accent tint for about a second. The
                  tint is read off CELL BACKGROUNDS, which is the one thing a
                  raw-byte grep cannot do honestly.
  3. after ~1s  — the tint is gone and the row stops moving for good.

Then it clicks the header twice: open (chevron flips down, the card hangs off
the gutter) and shut again. The click path is the one #519/#551 pinned, so a
header that changed shape must not have moved the row→run mapping.

The tool is a `sleep`, so step 1 is a real window and not a race: with the
progressive/past split removed the very first assertion fails.

Usage: python3 scripts/test-tui-fold-headers.py [path/to/graff]
Exit 0 = pass. Skips (exit 0, notice) with no pty support.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from codex_ws_mock import CodexMock, RecordedRequest  # noqa: E402
from ptyharness import PtyHarness, PtyTimeout  # noqa: E402

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
ROWS, COLS = 34, 110

# Long enough that the live header is a window, short enough that the probe
# stays quick. The turn's own timeout is far above this.
SLEEP_S = 3
FINAL = "FOLDHDR_OK"

CHEV_CLOSED = "›"
CHEV_OPEN = "⌄"
GUTTER = "│"
ELLIPSIS = "…"


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
                "id": "fc_fold_bash",
                "call_id": "call_fold_bash",
                "name": "bash",
                "arguments": json.dumps({"command": f"sleep {SLEEP_S}; echo slept"}),
                "status": "completed",
            },
            "resp_fold_bash",
        )
    return response_events(message_item(FINAL, "msg_fold_done"), "resp_fold_done")


def workspace(tmp: str, port: int):
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "fold-header-mock", "account_id": "acct-fold"}}, fh)
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
    for name in list(os.environ):
        if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR") and name not in env:
            env[name] = None
    return env


def spawn_env(env):
    """PtyHarness merges into os.environ, so a None means 'unset'."""
    clean = {k: v for k, v in env.items() if v is not None}
    for k, v in env.items():
        if v is None:
            os.environ.pop(k, None)
    return clean


def header_row(pty, chevron=None):
    """Index of the fold header row, by chevron state. None = either."""
    hits = []
    for y, ln in enumerate(pty.screen_lines()):
        if "bash" not in ln:
            continue
        if chevron is None:
            if f"{CHEV_CLOSED} R" in ln or f"{CHEV_OPEN} R" in ln:
                hits.append(y)
        elif f"{chevron} R" in ln:
            hits.append(y)
    return hits


def row_bgs(pty, y):
    return {pty.cell(x, y).bg for x in range(pty.cols)}


def click(pty, y):
    """SGR press+release on the header's text column, 1-based."""
    pty.inject_keys(f"\x1b[<0;6;{y + 1}M".encode())
    pty.pump(0.25)
    pty.inject_keys(f"\x1b[<0;6;{y + 1}m".encode())
    pty.pump(0.8)


def run() -> str | None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-fold-headers-") as tmp:
            env = spawn_env(workspace(tmp, port))
            argv = [BIN, "tui", "--yolo", "--model", "codex", "--no-telemetry"]
            with PtyHarness(argv, cols=COLS, rows=ROWS, cwd=tmp, env=env) as pty:
                if not pty.wait_for_boot():
                    return "the TUI never took the alt screen"
                pty.inject_keys(b"run the sleep then report\r")

                # 1. IN FLIGHT: present-progressive, with the count of calls
                #    that have been announced so far.
                try:
                    pty.wait_for_text(f"Running bash{ELLIPSIS}", timeout=25.0)
                except PtyTimeout as exc:
                    return f"the live header never read present-progressive: {exc}"
                live = header_row(pty, CHEV_CLOSED)
                if len(live) != 1:
                    return f"expected one live header row, got {live!r}"
                if "Ran bash" in pty.screen_contents():
                    return "the header was in past tense while the call was still running"

                # 2. SETTLED: past tense, and tinted for about a second.
                try:
                    pty.wait_for_text("Ran bash", timeout=40.0)
                except PtyTimeout as exc:
                    return f"the header never flipped to past tense: {exc}"
                settled_at = time.monotonic()
                if f"Running bash{ELLIPSIS}" in pty.screen_contents():
                    return "the progressive header outlived the call"
                lit = header_row(pty, CHEV_CLOSED)
                if len(lit) != 1:
                    return f"expected one settled header row, got {lit!r}"
                bgs = row_bgs(pty, lit[0])
                # The whole row is one field, so the tint is the only bg on it.
                if len(bgs) != 1:
                    return f"the settle tint is a ribbon, not a field: {bgs!r}"
                tint = next(iter(bgs))
                canvas = row_bgs(pty, lit[0] - 1) if lit[0] else {None}
                if tint in canvas:
                    return f"the settle tint is the canvas bg, so nothing flashed: {tint!r}"

                # 3. AFTER THE WINDOW: the tint is gone and stays gone.
                pty.pump(max(0.0, 1.4 - (time.monotonic() - settled_at)))
                pty.pump(0.6)
                after = header_row(pty, CHEV_CLOSED)
                if len(after) != 1:
                    return f"the header moved after the flash: {after!r}"
                if row_bgs(pty, after[0]) == {tint}:
                    return "the settle tint never turned itself off"
                if "Ran bash" not in pty.screen_contents():
                    return "the settled header did not survive its own flash"

                # 4. The final answer still lands, outside the run.
                try:
                    pty.wait_for_text(FINAL, timeout=30.0)
                except PtyTimeout as exc:
                    return f"the turn never produced its answer: {exc}"

                # 5. CLICK: the chevron flips and the card hangs off the gutter.
                y = header_row(pty, CHEV_CLOSED)
                if len(y) != 1:
                    return f"lost the header before the click: {y!r}"
                click(pty, y[0])
                if header_row(pty, CHEV_CLOSED):
                    return "the click did not open the run"
                opened = header_row(pty, CHEV_OPEN)
                if len(opened) != 1:
                    return f"the open run lost its header: {opened!r}"
                lines = pty.screen_lines()
                card = [ln for ln in lines[opened[0] + 1 : opened[0] + 4] if GUTTER in ln and "bash" in ln]
                if not card:
                    return f"no card on the open run's gutter: {lines[opened[0]:opened[0] + 4]!r}"
                if "Ran bash" not in lines[opened[0]]:
                    return f"the open header lost its verb: {lines[opened[0]]!r}"

                # 6. ...and clicking it again folds the run back up.
                click(pty, opened[0])
                if not header_row(pty, CHEV_CLOSED):
                    return "the second click did not fold the run back"
                if header_row(pty, CHEV_OPEN):
                    return "the run stayed open after being folded"
                pty.quit()
    finally:
        mock.stop()
    return None


def main() -> int:
    if not os.path.exists(BIN):
        print(f"  ! fold headers: no binary at {BIN}, skipping")
        return 0
    try:
        import pty as _pty  # noqa: F401
    except Exception:
        print("  ! fold headers: no pty support, skipping")
        return 0
    err = run()
    if err:
        print(f"  ✗ fold headers: {err}")
        return 1
    print("  ✓ fold headers: progressive → past tense, settle flash on and off, click opens and folds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
