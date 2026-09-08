"""Grease: interrupted path prints waited_ms raw, not formatElapsed."""
from __future__ import annotations

import pathlib
import sys

STUB = '        try w.print("[job {d}: running · 36000s elapsed — you are notified on exit; do not call bash_output again]", .{id}); // LIVE_PARENT_STUB'
GREASE = '        try w.print("[job {d}: running · {d}s waited, then interrupted — you are notified on exit; do not call bash_output again]", .{ id, waited_ms / 1000 }); // LIVE_GREASE'


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "job_notify.zig"
    text = path.read_text()
    if STUB not in text:
        raise SystemExit("graff-727 grease: parent stub not applied")
    path.write_text(text.replace(STUB, GREASE, 1))


if __name__ == "__main__":
    main()
