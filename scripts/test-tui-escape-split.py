#!/usr/bin/env python3
"""Real-PTY regression for #537's split Escape ambiguity, fully offline.

A 70ms exact-CSI gap and 250ms X10 gap stay terminal sequences inside the main
grace. A live bash op gives a possible paste-start Escape the bounded one-second
window, while controls in the completed paste stay inert. A dropped non-lone
head accumulates a secondary late read without losing its exact framing.
Ambiguous CSI/SS3 and byte-read prose stay text. Every split is verified in the
TUI trajectory log as a separate input read.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ptyharness import PtyHarness, PtyTimeout  # noqa: E402

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
MARKER = "ESC_SPLIT_DRAFT"
DROPPED_BODY = "DROPPED_HEAD_OK"
DROPPED_CONTROL = "DROPPED_CONTROL_SAFE"
LATE_BODY = "LATE_BODY_OK"
LATE_CONTROL = "LATE_CONTROL_SAFE"
LIVE_BASH = "LIVE_BASH_ESCAPE_SAFE"
HUMAN_TEXT = "HUMAN:[Alice] [Home] [Down] 3u apples"


def trajectory_reads(tmp: str) -> list[bytes]:
    path = os.path.join(tmp, ".graff", "tui-traj.jsonl")
    try:
        with open(path, encoding="utf-8") as fh:
            rows = [json.loads(line) for line in fh if line.strip()]
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    return [bytes.fromhex(row["hex"]) for row in rows if "hex" in row]


class ReadEvidence:
    """Synchronize on traj.note: the next write was its own TUI input batch."""

    def __init__(self, pty: PtyHarness, tmp: str):
        self.pty = pty
        self.tmp = tmp
        self.seen = len(trajectory_reads(tmp))

    def inject(self, data: bytes, gap: float = 0.0) -> None:
        self.pty.inject_keys(data)
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            self.pty.pump(0.02)
            reads = trajectory_reads(self.tmp)
            if len(reads) <= self.seen:
                continue
            fresh = reads[self.seen :]
            self.seen = len(reads)
            if fresh != [data]:
                raise PtyTimeout(
                    f"expected one TUI read {data.hex()}, got {[part.hex() for part in fresh]}"
                )
            if gap:
                self.pty.pump(gap)
            return
        raise PtyTimeout(f"TUI trajectory never recorded input read {data.hex()}")


def workspace(tmp: str) -> dict[str, str | None]:
    empty = os.path.join(tmp, "empty-mcp.json")
    with open(empty, "w", encoding="utf-8") as fh:
        json.dump({"mcpServers": {}}, fh)
    harness = os.path.join(tmp, ".harness")
    os.makedirs(harness)
    with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)
    env = {
        name: None
        for name in os.environ
        if name.startswith(("GRAFF_", "CODEX_"))
        or name.endswith("_API_KEY")
    }
    env.update(
        {
            "HOME": tmp,
            "GRAFF_MCP_CONFIG": empty,
            "GRAFF_LEARN_AUTO": "off",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
            # Baked catalog + loopback endpoint: startup and any accidental
            # request have no real-provider or remote catalog route.
            "LMSTUDIO_API_KEY": "offline-escape-split-probe",
        }
    )
    return env


def run() -> str | None:
    with tempfile.TemporaryDirectory(prefix="tui-escape-split-") as tmp:
        with PtyHarness(
            [BIN, "tui", "--yolo", "--model", "lmstudio", "--no-telemetry"],
            cols=90,
            rows=28,
            cwd=tmp,
            env=workspace(tmp),
        ) as pty:
            if not pty.wait_for_boot():
                return "TUI did not enter the alternate screen"
            reads = ReadEvidence(pty, tmp)
            reads.inject(MARKER.encode())
            pty.wait_for_text(MARKER, timeout=5.0)

            # Arm two-Escape clear. Trajectory synchronization proves the
            # split head and body reached different TUI input batches.
            reads.inject(b"\x1b", 0.80)
            reads.inject(b"\x1b", 0.070)
            reads.inject(b"[A", 0.4)
            if MARKER not in pty.screen_contents():
                return "70ms ESC/arrow split dispatched a phantom Escape\n" + pty.screen_contents()

            # X10 is CSI M plus three raw bytes; protect the reported 250ms gap.
            reads.inject(b"\x1b", 0.80)
            reads.inject(b"\x1b", 0.250)
            reads.inject(b"[M !!", 0.4)
            screen = pty.screen_contents()
            if MARKER not in screen or "[M !!" in screen:
                return "250ms ESC/X10 split escaped or typed its body\n" + screen

            # A lone ESC during real background work may still be paste start.
            # At 800ms the live op must remain uncancelled; explicit C0 controls
            # in the completed paste are then inert.
            reads.inject(b"\x15", 0.2)
            reads.inject(b"!sleep 2\n", 0.2)
            pty.wait_for_text("$ sleep 2", timeout=5.0)
            reads.inject(b"\x1b", 0.80)
            reads.inject(b"[200~" + LIVE_BASH.encode() + b"\x11\x03\nSAFE")
            pty.wait_for_text(LIVE_BASH, timeout=5.0, settle=0.2)
            reads.inject(b"\x1b[201~\x15", 1.3)
            if "interrupted" in pty.screen_contents().lower():
                return "800ms possible paste-start Escape cancelled live bash\n" + pty.screen_contents()

            # A non-lone paste head is dropped after ~500ms, then its tail
            # lands as TWO reads inside the one-second dropped-head interval.
            # SGR and X10 wheels share the reconstructed marker's production
            # batch and stay paste-inert.
            reads.inject(b"\x1b[20", 1.10)
            reads.inject(b"0", 0.10)
            dropped = (
                b"~"
                + DROPPED_BODY.encode()
                + 2 * b"\x1b[<64;4;4M"
                + 2 * b"\x1b[M`$$"
                + b"\x11\x03\n"
                + DROPPED_CONTROL.encode()
            )
            reads.inject(dropped)
            pty.wait_for_text(DROPPED_CONTROL, timeout=5.0, settle=0.2)
            screen = pty.screen_contents()
            if "0~" in screen or DROPPED_BODY not in screen:
                return "dropped paste head lost its exact 401-999ms framing\n" + screen

            # A genuine Escape remains different: its exact head expires at
            # 400ms, while narrow self-identifying recovery remains for 1s.
            reads.inject(b"\x1b[201~\x05\x15", 0.25)
            reads.inject(b"\x1b", 0.80)
            paste = b"[200~" + LATE_BODY.encode() + b"\x11\x03\n" + LATE_CONTROL.encode()
            reads.inject(paste)
            pty.wait_for_text(LATE_CONTROL, timeout=5.0, settle=0.2)
            screen = pty.screen_contents()
            if "[200~" in screen:
                return "late paste marker typed after the carried ESC expired"
            if LATE_BODY not in screen:
                return "late paste payload was not retained"

            # Beyond carry, exact CSI/SS3 is prose-ambiguous and remains text.
            reads.inject(b"\x1b[201~\x05\x15", 0.25)
            reads.inject(b"EXACT:\x1b", 0.80)
            reads.inject(b"[D")
            reads.inject(b" \x1b", 0.80)
            reads.inject(b"OD", 0.2)
            pty.wait_for_text("EXACT:[D OD", timeout=5.0, settle=0.2)

            # Parameterized kitty remains distinguishable and is a real Left.
            reads.inject(b"\x05\x15", 0.25)
            reads.inject(b"ab\x1b", 0.80)
            reads.inject(b"[57350;1u")
            reads.inject(b"X\x05")
            pty.wait_for_text("aXb", timeout=5.0, settle=0.2)

            # BEL makes the OSC body self-identifying even with same-read text.
            reads.inject(b"\x15", 0.4)
            reads.inject(b"OSC:\x1b", 0.80)
            reads.inject(b"]11;rgb:f6/f6/f6\x07_OK")
            pty.wait_for_text("OSC:_OK", timeout=5.0, settle=0.2)
            if "]11;rgb:" in pty.screen_contents():
                return "terminated late OSC tail typed into the composer"

            # Give every ambiguous spelling its own expired genuine Escape,
            # and force every prose byte through a distinct read with >=50ms.
            reads.inject(b"\x05\x15", 0.4)
            reads.inject(b"HUMAN:")
            tokens = (b"[Alice]", b"[Home]", b"[Down]", b"3u apples")
            for index, token in enumerate(tokens):
                reads.inject(b"\x1b", 0.80)
                for byte in token:
                    reads.inject(bytes([byte]), 0.050)
                if index + 1 < len(tokens):
                    reads.inject(b" ")
            pty.wait_for_text(HUMAN_TEXT, timeout=5.0, settle=0.2)
            if HUMAN_TEXT not in pty.screen_contents():
                return "50ms byte-read human text after genuine Escape was changed"

            if pty.quit() is None:
                return "TUI did not quit cleanly"
    return None


def main() -> int:
    if not os.path.isfile(BIN):
        print(f"tui-escape-split: {BIN} not built — skipping")
        return 0
    try:
        err = run()
    except PtyTimeout as exc:
        err = str(exc)
    except OSError as exc:
        print(f"tui-escape-split: pty unavailable ({exc}) — skipping")
        return 0
    if err:
        print(f"tui-escape-split: FAIL: {err}")
        return 1
    print("tui-escape-split: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
