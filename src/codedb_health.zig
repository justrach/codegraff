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

/// 16-hex-character Wyhash(0, canonical_cwd) directory key used by `codedb`
/// under `~/.codedb/projects/<hash>/`.
pub fn projectHashHex(canonical_cwd: []const u8, out: *[16]u8) []const u8 {
    const h = std.hash.Wyhash.hash(0, canonical_cwd);
    return std.fmt.bufPrint(out, "{x:0>16}", .{h}) catch "";
}

fn posixHome() ?[]const u8 {
    if (comptime @import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return null;
    const raw = std.c.getenv("HOME") orelse return null;
    const s = std.mem.span(raw);
    return if (s.len > 0) s else null;
}

pub fn probe(io: Io, cwd: []const u8) Snapshot {
    return probeWithHome(io, cwd, posixHome());
}

pub fn probeWithHome(io: Io, cwd: []const u8, home: ?[]const u8) Snapshot {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = if (cwd.len == 0) "." else cwd;
    const local_path = if (std.mem.eql(u8, target, "."))
        snapshot_name
    else
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ target, snapshot_name }) catch return .{ .present = false };
    if (Io.Dir.cwd().statFile(io, local_path, .{})) |st| {
        if (st.kind == .file) return .{ .present = true, .bytes = st.size };
    } else |_| {}

    const h_dir = home orelse return .{ .present = false };
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = Io.Dir.cwd().realPathFile(io, target, &abs_buf) catch return .{ .present = false };
    var hex_buf: [16]u8 = undefined;
    const hex = projectHashHex(abs_buf[0..abs_len], &hex_buf);
    if (hex.len != 16) return .{ .present = false };
    var proj_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proj_snap = std.fmt.bufPrint(&proj_buf, "{s}/.codedb/projects/{s}/{s}", .{ h_dir, hex, snapshot_name }) catch return .{ .present = false };
    const st = Io.Dir.cwd().statFile(io, proj_snap, .{}) catch return .{ .present = false };
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

test "probeWithHome: resolves ~/.codedb/projects/<wyhash>/codedb.snapshot when cwd has no local snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = abs_buf[0..try tmp.dir.realPathFile(io, ".", &abs_buf)];
    var hex_buf: [16]u8 = undefined;
    const hex = projectHashHex(root, &hex_buf);
    try std.testing.expectEqual(@as(usize, 16), hex.len);

    var rel_buf: [256]u8 = undefined;
    const proj_dir = try std.fmt.bufPrint(&rel_buf, ".codedb/projects/{s}", .{hex});
    try tmp.dir.createDirPath(io, proj_dir);
    var snap_buf: [256]u8 = undefined;
    const snap_rel = try std.fmt.bufPrint(&snap_buf, "{s}/{s}", .{ proj_dir, snapshot_name });
    try tmp.dir.writeFile(io, .{ .sub_path = snap_rel, .data = "0123456789" });

    const snap = probeWithHome(io, root, root);
    try std.testing.expect(snap.present);
    try std.testing.expectEqual(@as(u64, 10), snap.bytes);
}
