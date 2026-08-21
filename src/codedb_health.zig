//! Snapshot health for the native codedb tool.
//!
//! The index lives in `codedb.snapshot` (gitignored, built by the codedb
//! binary). Graff never writes it. `status` reports whether it is present
//! so a model is not stuck between empty `search` and guessing `tree`.
//! `list_dir` does not need the snapshot — it walks the live tree.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const no_local_tools = @import("no_local_tools.zig");

pub const snapshot_name = "codedb.snapshot";

pub const Snapshot = struct {
    present: bool,
    bytes: u64 = 0,
};

pub fn probe(io: Io, cwd: []const u8) Snapshot {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (cwd.len == 0 or std.mem.eql(u8, cwd, "."))
        snapshot_name
    else
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ cwd, snapshot_name }) catch return .{ .present = false };
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .present = false };
    if (st.kind != .file) return .{ .present = false };
    return .{ .present = true, .bytes = st.size };
}

pub fn render(gpa: Allocator, snap: Snapshot) ![]u8 {
    if (snap.present) {
        return std.fmt.allocPrint(gpa, "codedb.snapshot present ({d} bytes). Prefer one-shot queries on this index: context <task>, around <name>, callpath A B. Folder listing does not need it: codedb list_dir <path>.", .{snap.bytes});
    }
    return gpa.dupe(u8, "codedb index missing — no codedb.snapshot in this cwd. Run `codedb` once in the repo to build it. Folder listing still works without an index: codedb list_dir .");
}

pub fn exec(ctx: tools.ToolCtx) !tools.ToolOutput {
    const cwd = ctx.agent_cwd orelse ".";
    const text = try render(ctx.gpa, probe(ctx.io, cwd));
    return .{ .text = text };
}

/// One-line prompt segment when local tools are on and the snapshot is gone.
/// Null when the index is present or `--no-local-tools` removed codedb —
/// repo_map already orients the tree, and a present index needs no nag.
pub fn segment(io: Io, _: Allocator) ?[]const u8 {
    if (no_local_tools.enabled) return null;
    if (probe(io, ".").present) return null;
    return "\n\nCodedb index: no codedb.snapshot here. `codedb search`/`symbol` need `codedb` run once to index. Folder listing works anyway: codedb list_dir .";
}

test "probe: missing snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const snap = probe(io, buf[0..n]);
    try std.testing.expect(!snap.present);
}

test "probe: present snapshot reports size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(io, .{ .sub_path = snapshot_name, .data = "abcd" }) catch unreachable;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const snap = probe(io, buf[0..n]);
    try std.testing.expect(snap.present);
    try std.testing.expectEqual(@as(u64, 4), snap.bytes);
}

test "render names list_dir in both states" {
    const missing = try render(std.testing.allocator, .{ .present = false });
    defer std.testing.allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "list_dir") != null);
    const present = try render(std.testing.allocator, .{ .present = true, .bytes = 12 });
    defer std.testing.allocator.free(present);
    try std.testing.expect(std.mem.indexOf(u8, present, "12 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, present, "list_dir") != null);
}

test "segment is silent when no-local-tools is on" {
    const saved = no_local_tools.enabled;
    defer no_local_tools.enabled = saved;
    no_local_tools.enabled = true;
    try std.testing.expect(segment(std.testing.io, std.testing.allocator) == null);
}
