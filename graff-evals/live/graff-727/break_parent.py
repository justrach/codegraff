"""Parent: interrupted wait still prints the 10h sentinel."""
from __future__ import annotations

import pathlib
import sys

NEEDLE = """    if (interrupted) {
        try w.print("[job {d}: running · {s} waited, then interrupted — you are notified on exit; do not call bash_output again]", .{ id, el });
    } else {"""
STUB = """    if (interrupted) {
        try w.print("[job {d}: running · 36000s elapsed — you are notified on exit; do not call bash_output again]", .{id}); // LIVE_PARENT_STUB
    } else {"""


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "job_notify.zig"
    text = path.read_text()
    if NEEDLE not in text:
        raise SystemExit("graff-727 parent: printRunning interrupted branch not found")
    path.write_text(text.replace(NEEDLE, STUB, 1))


if __name__ == "__main__":
    main()
