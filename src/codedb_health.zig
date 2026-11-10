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

/// True when `cwd` is a linked git worktree (`.git` is a gitdir pointer file
/// rather than a `.git/` directory) and has no codedb snapshot of its own (#54).
pub fn isUnindexedLinkedWorktree(io: Io, cwd: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = if (cwd.len == 0) "." else cwd;
    const git_path = if (std.mem.eql(u8, target, "."))
        ".git"
    else
        std.fmt.bufPrint(&buf, "{s}/.git", .{target}) catch return false;
    const st = Io.Dir.cwd().statFile(io, git_path, .{}) catch return false;
    if (st.kind != .file) return false;
    return !probe(io, target).present;
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
    const snap = probe(ctx.io, cwd);
    if (!snap.present and countCodeFilesCapped(ctx.io, cwd, min_repo_code_files) < min_repo_code_files) {
        return .{
            .text = try std.fmt.allocPrint(ctx.gpa, "small workspace (<{d} code files) — no codedb index needed yet (switches to codedb automatically at >={d} code files). Use codedb list_dir . and read_file directly.", .{ min_repo_code_files, min_repo_code_files }),
        };
    }
    const text = try render(ctx.gpa, snap);
    return .{ .text = text };
}

pub const min_repo_code_files: usize = 8;

const data_or_text_exts = [_][]const u8{
    ".json", ".jsonl", ".csv",  ".tsv", ".txt", ".md",  ".markdown",
    ".yaml", ".yml",   ".toml", ".ini", ".cfg", ".log", ".xml",
};

const code_exts = [_][]const u8{
    ".zig", ".py",  ".rs",  ".go",    ".ts", ".tsx",  ".js",   ".jsx",
    ".c",   ".h",   ".cpp", ".hpp",   ".cc", ".java", ".kt",   ".swift",
    ".rb",  ".php", ".cs",  ".scala", ".sh", ".lua",  ".lean", ".sql",
};

pub fn isDataOrTextPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    for (data_or_text_exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub fn isCodePath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    for (code_exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// Count code files up to `cap` in `cwd` (1 level deep + top-level subdirectories)
/// in <0.5ms so `codedb` can distinguish tiny 0-2 file tasks from real repos
/// (`ResourceKernel.lean::routeCodedb`).
pub fn countCodeFilesCapped(io: Io, cwd: []const u8, cap: usize) usize {
    const target = if (cwd.len == 0) "." else cwd;
    var root = Io.Dir.cwd().openDir(io, target, .{ .iterate = true }) catch return cap;
    defer root.close(io);
    var count: usize = 0;
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (entry.kind == .file) {
            if (isCodePath(entry.name)) {
                count += 1;
                if (count >= cap) return count;
            }
        } else if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, "node_modules") or std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, "zig-cache") or std.mem.eql(u8, entry.name, "target")) continue;
            var sub = root.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            var sub_it = sub.iterate();
            while (sub_it.next(io) catch null) |sub_e| {
                if (sub_e.name.len == 0 or sub_e.name[0] == '.') continue;
                if (sub_e.kind == .file and isCodePath(sub_e.name)) {
                    count += 1;
                    if (count >= cap) return count;
                } else if (sub_e.kind == .directory) {
                    var sub2 = sub.openDir(io, sub_e.name, .{ .iterate = true }) catch continue;
                    defer sub2.close(io);
                    var sub2_it = sub2.iterate();
                    while (sub2_it.next(io) catch null) |sub2_e| {
                        if (sub2_e.name.len == 0 or sub2_e.name[0] == '.') continue;
                        if (sub2_e.kind == .file and isCodePath(sub2_e.name)) {
                            count += 1;
                            if (count >= cap) return count;
                        }
                    }
                }
            }
        }
    }
    return count;
}

/// One-line prompt segment when local tools are on and the snapshot is gone.
/// Null when the index is present, `--no-local-tools` removed codedb, or the
/// workspace is a tiny (<3 code files) directory that does not need an index.
pub fn segment(io: Io, _: Allocator) ?[]const u8 {
    if (no_local_tools.enabled) return null;
    if (probe(io, ".").present) return null;
    if (countCodeFilesCapped(io, ".", min_repo_code_files) < min_repo_code_files) return null;
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

test "countCodeFilesCapped: dynamically switches from small-workspace mode (<8) to codedb mode (>=8) as files are added" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = abs_buf[0..try tmp.dir.realPathFile(io, ".", &abs_buf)];

    // Start with 3 code files + 2 data files: stays below min_repo_code_files (8).
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = "x = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.py", .data = "y = 2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.py", .data = "z = 3\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.json", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = "# hi\n" });
    try std.testing.expectEqual(@as(usize, 3), countCodeFilesCapped(io, root, min_repo_code_files));
    try std.testing.expect(countCodeFilesCapped(io, root, min_repo_code_files) < min_repo_code_files);
    try std.testing.expect(@import("codedb_guard_scope.zig").exempt(io, root, "grep", "grep x a.py"));

    // Add 5 more code files (reaching 8 total): switches to codedb mode automatically.
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/d.py", .data = "d = 4\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/e.py", .data = "e = 5\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/f.py", .data = "f = 6\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/g.py", .data = "g = 7\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/h.py", .data = "h = 8\n" });
    try std.testing.expectEqual(min_repo_code_files, countCodeFilesCapped(io, root, min_repo_code_files));
    try std.testing.expect(!@import("codedb_guard_scope.zig").exempt(io, root, "grep", "grep x a.py"));
}
