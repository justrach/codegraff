"""Private clipboard command boundary for offline PTY probes.

The probe and its Graff child share these commands through PATH. Direct probe
runs still exercise the OS clipboard; the parallel gate must neither race with
other probes nor read or replace the user's clipboard.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import sys
import tempfile


@contextmanager
def private_clipboard():
    with tempfile.TemporaryDirectory(prefix="tuiguard-clipboard-") as directory:
        root = Path(directory)
        clipboard = root / "clipboard"
        clipboard.write_bytes(b"")
        handler = root / "clipboard.py"
        handler.write_text(
            "import os, pathlib, sys\n"
            "path = pathlib.Path(__file__).with_name('clipboard')\n"
            "if sys.argv[1] in ('pbpaste',) or '-o' in sys.argv[2:] or '-out' in sys.argv[2:]:\n"
            "    sys.stdout.buffer.write(path.read_bytes())\n"
            "else:\n"
            "    temporary = path.with_name('write-' + str(os.getpid()))\n"
            "    temporary.write_bytes(sys.stdin.buffer.read())\n"
            "    temporary.replace(path)\n",
            encoding="utf-8",
        )
        for command in ("pbcopy", "pbpaste", "xclip"):
            wrapper = root / command
            wrapper.write_text(
                f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(handler))} {command} \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o700)
        yield {**os.environ, "PATH": str(root) + os.pathsep + os.environ.get("PATH", "")}
