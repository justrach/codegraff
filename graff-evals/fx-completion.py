#!/usr/bin/env python3
"""Run the completion exam with fx's native Grok subscription provider."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: fx-completion.py MODEL PROMPT")
    binary = os.environ.get("FX_BIN") or shutil.which("fx")
    if not binary or not Path(binary).is_file():
        raise SystemExit("Set FX_BIN to an installed fx binary")
    env = {**os.environ, "FX_MODEL": sys.argv[1], "FX_MAX_AGENT_STEPS": "0"}
    status = subprocess.run([binary, "status", "--json"], env=env,
                            capture_output=True, text=True, check=True)
    info = json.loads(status.stdout)
    if info.get("auth") != "Grok subscription":
        raise SystemExit("fx must use its Grok subscription: run fx login grok / fx provider grok")
    os.execve(binary, [binary, "ask", "--full-access", "--json",
                      "--no-color", "--", sys.argv[2]], env)


if __name__ == "__main__":
    main()
