#!/usr/bin/env python3
"""Offline terminal /model confirmation regression (#890).

Tier 2's JSON set_model control bypasses the terminal confirmation printer.
Use the line-terminal dispatcher and a scripted follow-up request instead.
"""
from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))
from mock_model import ScriptedModel  # noqa: E402


def main() -> None:
    binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "zig-out/bin/graff").resolve()
    # Auxiliary requests may precede the user turn; all receive the same reply.
    mock = ScriptedModel([], exhausted_text="offline ready")
    mock.start(1234)
    try:
        with tempfile.TemporaryDirectory() as workspace:
            env = {
                "PATH": os.environ["PATH"],
                "HOME": workspace,
                "LMSTUDIO_API_KEY": "local",
                "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_SMOLIFY": "1",
                "NO_COLOR": "1",
            }
            result = subprocess.run(
                [str(binary), "--old", "--yolo", "--model", "lmstudio"],
                cwd=workspace, env=env, text=True, capture_output=True, timeout=60,
                input=(
                    "/model lmstudio regression-a\n"
                    "/model lmstudio regression-a\n"
                    "/model lmstudio regression-a\n"
                    "/model lmstudio regression-b\n"
                    "/model lmstudio regression-b\n"
                    "Reply with offline ready.\n"
                    "/quit\n"
                ),
            )
            assert result.returncode == 0, result.stderr
            output = result.stdout + "\n" + result.stderr
            confirmations = [
                line.strip() for line in output.splitlines()
                if line.strip().startswith(("switched to ", "already using "))
            ]
            expected = [
                "switched to regression-a via lmstudio",
                "already using regression-a via lmstudio",
                "already using regression-a via lmstudio",
                "switched to regression-b via lmstudio",
                "already using regression-b via lmstudio",
            ]
            assert len(confirmations) == len(expected), confirmations
            for actual, prefix in zip(confirmations, expected):
                assert actual.startswith(prefix), (actual, prefix)
            # Check that the final selection also reaches the real request path.
            turns = [r for r in mock.requests if r.get("model") == "regression-b"]
            assert turns, "The selected model never reached the scripted server"
            assert "offline ready" in output, "The scripted follow-up reply was not displayed"
            print("model confirmation: repeated selection, real change, and follow-up passed")
    finally:
        mock.stop()


if __name__ == "__main__":
    main()
