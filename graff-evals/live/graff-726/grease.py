"""Grease: drop a queued notice only. Hidden is dismiss-before-record."""
from __future__ import annotations

import pathlib
import sys

STUB = """pub fn dismiss(io: Io, id: u32) void {
    _ = .{ io, id };
    return; // LIVE_PARENT_STUB"""
GREASE = """pub fn dismiss(io: Io, id: u32) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    var i: usize = 0;
    while (i < count) {
        if (ring[i].id != id) {
            i += 1;
            continue;
        }
        std.mem.copyForwards(Notice, ring[i .. count - 1], ring[i + 1 .. count]);
        count -= 1;
    }
    return; // LIVE_GREASE_QUEUE_ONLY"""


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "job_notify.zig"
    text = path.read_text()
    if STUB not in text:
        raise SystemExit("graff-726 grease: parent stub not applied")
    path.write_text(text.replace(STUB, GREASE, 1))


if __name__ == "__main__":
    main()
