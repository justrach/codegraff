"""Parent: spawn writes no ownership record."""
from __future__ import annotations

import pathlib
import sys

NEEDLE = """pub fn write(io: Io, base: []const u8, rec: Record) void {
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;"""
STUB = """pub fn write(io: Io, base: []const u8, rec: Record) void {
    _ = .{ io, base, rec };
    return; // LIVE_PARENT_STUB
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;"""


HEAD = "    return Io.Dir.cwd().readFile(io, path, buf) catch null;"
HEAD_STUB = "    _ = .{ io, path, buf }; return null; // LIVE_PARENT_STUB_HEAD"


def main():
    root = pathlib.Path(sys.argv[1])
    path = root / "src" / "job_registry.zig"
    text = path.read_text()
    if NEEDLE not in text:
        raise SystemExit("graff-servers parent: write() not found")
    path.write_text(text.replace(NEEDLE, STUB, 1))
    skills = root / "src" / "skill_docs.zig"
    st = skills.read_text()
    if HEAD not in st:
        raise SystemExit("graff-servers parent: readHead not found")
    skills.write_text(st.replace(HEAD, HEAD_STUB, 1))


if __name__ == "__main__":
    main()
