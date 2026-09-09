"""Grease: interrupted launches say interrupted, but finished rows do not replay."""
from __future__ import annotations

import pathlib
import sys

STUB = "    return .{ .text = try missingText(gpa, id, false, e.label), .is_error = true }; // LIVE_PARENT_STUB"
GREASE = """    if (!e.done) return .{ .text = try missingText(gpa, id, true, e.label), .is_error = true };
    return .{ .text = try missingText(gpa, id, false, e.label), .is_error = true }; // LIVE_GREASE"""


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "subagent_ledger.zig"
    text = path.read_text()
    if STUB not in text:
        raise SystemExit("graff-interrupt grease: parent stub not applied")
    path.write_text(text.replace(STUB, GREASE, 1))


if __name__ == "__main__":
    main()
