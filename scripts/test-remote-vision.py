#!/usr/bin/env python3
"""Opt-in #615 witness: a random PNG crosses RemoteHarness + graff serve.

This intentionally makes one real provider call. Example:

  python3 scripts/test-remote-vision.py --model gpt-5.5

Set --bridge-url to exercise an already-running bridge; otherwise the script
starts zig-out/bin/graff serve on an ephemeral loopback port.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import sys
import time
import urllib.request
import zlib


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sdk" / "py"))
from harness_sdk import RemoteHarness  # noqa: E402


SEGMENTS = {
    "0": "ab cdef".replace(" ", ""),
    "1": "bc",
    "2": "abdeg",
    "3": "abcdg",
    "4": "bcfg",
    "5": "acdfg",
    "6": "acdefg",
    "7": "abc",
    "8": "abcdefg",
    "9": "abcdfg",
}


def chunk(tag: bytes, data: bytes) -> bytes:
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF)


def code_png(code: str, scale: int = 5) -> bytes:
    digit_w, height, gap, thick = 14, 24, 4, 3
    width = len(code) * (digit_w + gap) + gap
    pixels = [[255] * width for _ in range(height)]

    def rect(x: int, y: int, w: int, h: int) -> None:
        for row in range(max(0, y), min(height, y + h)):
            for col in range(max(0, x), min(width, x + w)):
                pixels[row][col] = 0

    for index, digit in enumerate(code):
        x = gap + index * (digit_w + gap)
        for segment in SEGMENTS[digit]:
            if segment == "a":
                rect(x + thick, 1, digit_w - 2 * thick, thick)
            elif segment == "b":
                rect(x + digit_w - thick - 1, 3, thick, 8)
            elif segment == "c":
                rect(x + digit_w - thick - 1, 13, thick, 8)
            elif segment == "d":
                rect(x + thick, height - thick - 1, digit_w - 2 * thick, thick)
            elif segment == "e":
                rect(x + 1, 13, thick, 8)
            elif segment == "f":
                rect(x + 1, 3, thick, 8)
            elif segment == "g":
                rect(x + thick, 11, digit_w - 2 * thick, thick)

    scaled_w, scaled_h = width * scale, height * scale
    rows = bytearray()
    for row in pixels:
        expanded = bytes(value for value in row for _ in range(scale))
        for _ in range(scale):
            rows.append(0)  # PNG filter: none
            rows.extend(expanded)
    header = struct.pack(">IIBBBBB", scaled_w, scaled_h, 8, 0, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_bridge(url: str, process: subprocess.Popen[bytes] | None) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError(f"graff serve exited early with status {process.returncode}")
        try:
            with urllib.request.urlopen(url + "/healthz", timeout=0.5) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("graff serve did not become healthy within 15 seconds")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default=os.environ.get("GRAFF_VISION_MODEL"), help="vision-capable model (or GRAFF_VISION_MODEL)")
    parser.add_argument("--bridge-url", default=os.environ.get("GRAFF_SERVE_URL"), help="reuse a running bridge")
    parser.add_argument("--binary", default=str(ROOT / "zig-out" / "bin" / "graff"))
    args = parser.parse_args()
    if not args.model:
        parser.error("--model is required so this opt-in witness never spends against an accidental default")

    process: subprocess.Popen[bytes] | None = None
    url = args.bridge_url
    if not url:
        port = free_port()
        url = f"http://127.0.0.1:{port}"
        process = subprocess.Popen(
            [args.binary, "serve", "--host", "127.0.0.1", "--port", str(port)],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    try:
        wait_for_bridge(url.rstrip("/"), process)
        code = "".join(secrets.choice("23456789") for _ in range(6))
        png = base64.b64encode(code_png(code)).decode("ascii")
        with RemoteHarness(url, model=args.model, yolo=True) as harness:
            answer = harness.ask(
                "Read the six digits shown in this image. Reply with the digits only.",
                images=[{"type": "image_base64", "media_type": "image/png", "data": png}],
            )
        digits = "".join(char for char in answer if char.isdigit())
        if code not in digits:
            raise AssertionError(f"expected image code {code}, model returned {answer!r}")
        print(f"ok: RemoteHarness → graff serve → {args.model} read unpredictable image code {code}")
        return 0
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
