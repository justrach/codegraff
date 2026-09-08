"""Parent: every missing handle is 'never started'."""
from __future__ import annotations

import pathlib
import sys

NEEDLE = """    return .{ .text = try missingText(gpa, id, true, e.label), .is_error = true };
}"""
STUB = """    return .{ .text = try missingText(gpa, id, false, e.label), .is_error = true }; // LIVE_PARENT_STUB
}"""


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "subagent_ledger.zig"
    text = path.read_text()
    if NEEDLE not in text:
        raise SystemExit("graff-interrupt parent: missing() interrupted return not found")
    path.write_text(text.replace(NEEDLE, STUB, 1))


if __name__ == "__main__":
    main()
