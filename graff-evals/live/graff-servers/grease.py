"""Grease: write the file, skip owner identity fields the hidden case wants."""
from __future__ import annotations

import pathlib
import sys

STUB = """pub fn write(io: Io, base: []const u8, rec: Record) void {
    _ = .{ io, base, rec };
    return; // LIVE_PARENT_STUB"""
GREASE = """pub fn write(io: Io, base: []const u8, rec: Record) void {
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dbuf, base) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch return;
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = recordPath(&pbuf, base, rec.pid) orelse return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{}" }) catch return;
    return; // LIVE_GREASE"""


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "job_registry.zig"
    text = path.read_text()
    if STUB not in text:
        raise SystemExit("graff-servers grease: parent stub not applied")
    path.write_text(text.replace(STUB, GREASE, 1))


if __name__ == "__main__":
    main()
