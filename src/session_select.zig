//! `--session-id <id>` and `-c`/`--continue`: two ways to pick the durable
//! session at launch without spelling out `--resume <name>`.
//!
//!   - `--session-id <id>` lets the caller assign the save basename. If
//!     `.graff/sessions/<id>.session.json` already exists here, the launch is
//!     a plain `--resume <id>`; otherwise a fresh session autosaves as `<id>`.
//!   - `-c`/`--continue` resumes the most recently updated save in this
//!     workspace: the first local row of the `/resume` picker (the newest
//!     `updated_ms` in cwd's `.graff/sessions`). Nothing saved is an error,
//!     not a silent fresh start, so a scripted `-c -p` never drops context.
//!
//! Both resolve into `Flags.resume_flag` (or the fresh-session name) once the
//! cwd is final (after `-w`), so every later resume path — line REPL,
//! one-shot, and `graff acp`, whose session/new reports the root session
//! name — stays the existing `--resume` plumbing.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const session_index = @import("session_index.zig");

/// Longest caller-assigned id (the same cap `validSessionName` uses).
pub const max_id_len = 128;

pub const IdError = error{ EmptyId, IdTooLong, IdBadStart, IdBadChar, IdReserved };

/// A caller-assigned id is a save basename, so it is held to safe filename
/// characters: ASCII letters, digits, `.`, `_`, `-`, starting with a letter or
/// digit (no hidden files, no `..`, nothing that reads as a flag). The
/// `session-` prefix is reserved: auto-named saves carry it and are renamed to
/// their AI title, which would silently drop the caller's id.
pub fn validateId(id: []const u8) IdError!void {
    if (id.len == 0) return error.EmptyId;
    if (id.len > max_id_len) return error.IdTooLong;
    if (!std.ascii.isAlphanumeric(id[0])) return error.IdBadStart;
    for (id) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return error.IdBadChar;
    }
    if (std.mem.startsWith(u8, id, "session-")) return error.IdReserved;
}

pub fn idErrorText(err: IdError) []const u8 {
    return switch (err) {
        error.EmptyId => "is empty",
        error.IdTooLong => "is longer than 128 characters",
        error.IdBadStart => "must start with a letter or digit",
        error.IdBadChar => "may only contain letters, digits, '.', '_' and '-'",
        error.IdReserved => "uses the reserved 'session-' prefix of auto-named sessions (use --resume to reopen one)",
    };
}

/// The flag combination that cannot work, or null. `--session-id` and
/// `--continue` each already choose the session, so neither combines with
/// `--resume`, with each other, or with the fresh-start `--new`/`--no-resume`.
/// `--continue --branch <dest>` is allowed: it forks the newest save.
pub fn conflict(flags: *const args.Flags) ?[]const u8 {
    const id = flags.session_id_flag != null;
    const cont = flags.continue_flag;
    if (id and cont) return "--session-id and --continue each pick the session; use one";
    if (id and flags.resume_flag != null) return "--session-id and --resume each pick the session; use one";
    if (cont and flags.resume_flag != null) return "--continue and --resume each pick the session; use one";
    if ((id or cont) and (flags.new_session_flag or flags.no_resume_flag))
        return if (id) "--session-id cannot be combined with --new or --no-resume" else "--continue cannot be combined with --new or --no-resume";
    if (id and flags.branch_flag != null) return "--session-id cannot be combined with --branch (use --resume <source> --branch <id>)";
    return null;
}

/// Base name of the most recently updated save in `dir` (a
/// `.graff/sessions` directory), or null when it holds none.
pub fn newestIn(io: Io, arena: Allocator, dir: Io.Dir) ?[]const u8 {
    const entries = session_index.listFromDir(io, arena, dir, ".", true);
    var best: ?session_index.SessionEntry = null;
    for (entries.items) |e| {
        if (best == null or e.updated_ms > best.?.updated_ms) best = e;
    }
    return if (best) |b| b.base else null;
}

fn existsIn(io: Io, arena: Allocator, dir: Io.Dir, id: []const u8) bool {
    const file = std.fmt.allocPrint(arena, "{s}{s}", .{ id, session_index.session_ext }) catch return false;
    return (dir.statFile(io, file, .{}) catch null) != null;
}

/// What the selection flags resolve to against one sessions directory.
pub const Choice = union(enum) { keep, resume_name: []const u8, fresh_name: []const u8, nothing_to_continue };

pub fn choose(io: Io, arena: Allocator, dir: ?Io.Dir, flags: *const args.Flags) Choice {
    if (flags.session_id_flag) |id| {
        if (dir) |d| if (existsIn(io, arena, d, id)) return .{ .resume_name = id };
        return .{ .fresh_name = id };
    }
    if (flags.continue_flag) {
        const d = dir orelse return .nothing_to_continue;
        return if (newestIn(io, arena, d)) |name| .{ .resume_name = name } else .nothing_to_continue;
    }
    return .keep;
}

/// Resolve `--session-id`/`--continue` against cwd's `.graff/sessions`.
/// Call once the cwd is final (after `-w`) and before the root session is
/// named. Fatal when `--continue` finds nothing to continue.
pub fn resolve(io: Io, arena: Allocator, flags: *args.Flags) void {
    if (flags.session_id_flag == null and !flags.continue_flag) return;
    var opened: ?Io.Dir = Io.Dir.cwd().openDir(io, session_index.sessions_dir, .{ .iterate = true }) catch null;
    defer if (opened) |*d| d.close(io);
    switch (choose(io, arena, opened, flags)) {
        .keep => {},
        .resume_name => |name| flags.resume_flag = name,
        .fresh_name => {}, // session_run names the fresh root from session_id_flag
        .nothing_to_continue => std.process.fatal("--continue: no saved session in this workspace ({s}) — start one with plain graff", .{session_index.sessions_dir}),
    }
}

test "validateId accepts safe filename ids and names each rejection" {
    const long: [max_id_len + 1]u8 = @splat('x');
    for ([_][]const u8{ "a", "build-42", "ci_run.7", "Z9", long[0..max_id_len] }) |ok| try validateId(ok);
    try std.testing.expectError(error.EmptyId, validateId(""));
    try std.testing.expectError(error.IdTooLong, validateId(&long));
    for ([_][]const u8{ ".hidden", "..", "-flag", "_x" }) |bad| try std.testing.expectError(error.IdBadStart, validateId(bad));
    for ([_][]const u8{ "a/b", "a\\b", "a b", "a\x00", "aé", "a:b" }) |bad| try std.testing.expectError(error.IdBadChar, validateId(bad));
    try std.testing.expectError(error.IdReserved, validateId("session-123-4"));
    try std.testing.expectEqualStrings("is empty", idErrorText(error.EmptyId));
}

test "conflict: session-id and continue exclude resume, each other and fresh starts" {
    try std.testing.expect(conflict(&.{}) == null);
    try std.testing.expect(conflict(&.{ .session_id_flag = "a" }) == null);
    try std.testing.expect(conflict(&.{ .continue_flag = true }) == null);
    try std.testing.expect(conflict(&.{ .continue_flag = true, .branch_flag = "dest" }) == null);
    try std.testing.expect(conflict(&.{ .resume_flag = "r", .branch_flag = "dest" }) == null);
    try std.testing.expect(conflict(&.{ .session_id_flag = "a", .continue_flag = true }) != null);
    try std.testing.expect(conflict(&.{ .session_id_flag = "a", .resume_flag = "r" }) != null);
    try std.testing.expect(conflict(&.{ .continue_flag = true, .resume_flag = "r" }) != null);
    try std.testing.expect(conflict(&.{ .continue_flag = true, .new_session_flag = true }) != null);
    try std.testing.expect(conflict(&.{ .session_id_flag = "a", .no_resume_flag = true }) != null);
    try std.testing.expect(conflict(&.{ .session_id_flag = "a", .branch_flag = "b" }) != null);
}

fn writeSave(io: Io, dir: Io.Dir, name: []const u8, updated_ms: i64) !void {
    var buf: [256]u8 = undefined;
    const file = try std.fmt.bufPrint(&buf, "{s}{s}", .{ name, session_index.session_ext });
    var body: [128]u8 = undefined;
    const data = try std.fmt.bufPrint(&body, "{{\"title\":\"t\",\"updated_ms\":{d},\"messages\":[]}}", .{updated_ms});
    try dir.writeFile(io, .{ .sub_path = file, .data = data });
}

test "choose: continue picks the newest save; session-id resumes an existing id or names a fresh one" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.testing.expectEqual(Choice.nothing_to_continue, choose(io, a, tmp.dir, &.{ .continue_flag = true }));
    try std.testing.expectEqual(Choice.nothing_to_continue, choose(io, a, null, &.{ .continue_flag = true }));
    try writeSave(io, tmp.dir, "older", 100);
    try writeSave(io, tmp.dir, "newest", 300);
    try writeSave(io, tmp.dir, "middle", 200);
    try tmp.dir.writeFile(io, .{ .sub_path = "newest.transcript.jsonl", .data = "" });

    try std.testing.expectEqualStrings("newest", choose(io, a, tmp.dir, &.{ .continue_flag = true }).resume_name);
    try std.testing.expectEqualStrings("middle", choose(io, a, tmp.dir, &.{ .session_id_flag = "middle" }).resume_name);
    try std.testing.expectEqualStrings("brand-new", choose(io, a, tmp.dir, &.{ .session_id_flag = "brand-new" }).fresh_name);
    try std.testing.expectEqualStrings("brand-new", choose(io, a, null, &.{ .session_id_flag = "brand-new" }).fresh_name);
    try std.testing.expectEqual(Choice.keep, choose(io, a, tmp.dir, &.{}));
}

test "--help documents --continue and --session-id" {
    const usage = @import("cli_text_source.zig").usage_text;
    try std.testing.expect(std.mem.indexOf(u8, usage, "-c, --continue") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--session-id <id>") != null);
}
