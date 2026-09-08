"""Parent: dismiss is a no-op, so a finished job still wakes the model."""
from __future__ import annotations

import pathlib
import sys

NEEDLE = """pub fn dismiss(io: Io, id: u32) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);"""
STUB = """pub fn dismiss(io: Io, id: u32) void {
    _ = .{ io, id };
    return; // LIVE_PARENT_STUB
    mu.lockUncancelable(io);
    defer mu.unlock(io);"""


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "job_notify.zig"
    text = path.read_text()
    if NEEDLE not in text:
        raise SystemExit("graff-726 parent: dismiss body not found")
    path.write_text(text.replace(NEEDLE, STUB, 1))


if __name__ == "__main__":
    main()
