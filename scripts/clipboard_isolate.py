"""Private clipboard commands for tuiguard probes (#836).

Each offline-gate probe gets its own copy/paste scripts and a file they
read/write. The Graff child inherits GRAFF_CLIPBOARD_COPY / PASTE, so
parallel probes never share the host pasteboard. Direct probe runs leave
those unset and keep native pbcopy/pbpaste (or skip).
"""

from __future__ import annotations

import os
import shlex
import stat
import sys
from pathlib import Path

COPY_ENV = "GRAFF_CLIPBOARD_COPY"
PASTE_ENV = "GRAFF_CLIPBOARD_PASTE"


def install_private(scratch: Path) -> dict[str, str]:
    """Write copy/paste wrappers under `scratch` and return the env to inherit."""
    scratch.mkdir(parents=True, exist_ok=True)
    clip = scratch / "clipboard"
    copy = scratch / "copy"
    paste = scratch / "paste"
    clip.write_bytes(b"")
    path = shlex.quote(str(clip))
    copy.write_text(f"#!/bin/sh\ncat > {path}\n", encoding="utf-8")
    paste.write_text(f"#!/bin/sh\ncat {path}\n", encoding="utf-8")
    mode = stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH
    copy.chmod(mode)
    paste.chmod(mode)
    return {COPY_ENV: str(copy), PASTE_ENV: str(paste)}


def tools() -> tuple[list[str] | None, list[str] | None]:
    """(copy_argv, paste_argv). None, None when no native or private tool."""
    copy = os.environ.get(COPY_ENV, "").strip()
    paste = os.environ.get(PASTE_ENV, "").strip()
    if copy and paste:
        return [copy], [paste]
    if sys.platform == "darwin":
        return ["pbcopy"], ["pbpaste"]
    return None, None


def isolated() -> bool:
    return bool(os.environ.get(COPY_ENV, "").strip() and os.environ.get(PASTE_ENV, "").strip())
