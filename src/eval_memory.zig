//! Local, run-scoped memory for the predict -> verify -> repair loop.
//!
//! The file is deliberately outside telemetry and trajectory payloads. It is
//! re-injected as append-only user-turn context, so it survives compaction
//! without mutating the cache-heavy system-prompt prefix.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const max_notes_bytes: usize = 16 * 1024;
const dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
const file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
const notes_body =
    \\## CONFIRMED
    \\- Nothing confirmed yet.
    \\
    \\## GUESSES
    \\- None.
    \\
    \\## HYPOTHESES TO TEST
    \\- Establish the current verifier baseline.
    \\
    \\## FACTS
    \\- The harness, not the model, runs the configured verifier.
    \\
    \\## VERIFIER HISTORY
    \\
;
pub const notes_template = "# Predict–Verify Notes\n\nTask class: general\n\n" ++ notes_body;

fn safeRunId(self: anytype) []const u8 {
    const tracer = self.tracer orelse return "session";
    const run_id = tracer.identity.run_id;
    if (run_id.len == 0 or run_id.len > 64) return "session";
    for (run_id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return "session";
    }
    return run_id;
}

fn noteName(self: anytype, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.md", .{safeRunId(self)}) catch "session.md";
}

fn initialNotes(self: anytype) []const u8 {
    if (self.eval_niche.len == 0) return notes_template;
    var class_buf: [64]u8 = undefined;
    const task_class = oneLine(&class_buf, self.eval_niche);
    return std.fmt.allocPrint(
        self.arena,
        "# Predict–Verify Notes\n\nTask class: {s}\n\n{s}",
        .{ if (task_class.len > 0) task_class else "general", notes_body },
    ) catch notes_template;
}

fn openNotesDir(self: anytype, base: Io.Dir) ?Io.Dir {
    base.createDir(self.io, ".graff", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return null,
    };
    const graff = base.openDir(self.io, ".graff", .{ .iterate = true, .follow_symlinks = false }) catch return null;
    defer graff.close(self.io);
    graff.createDir(self.io, "eval-notes", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return null,
    };
    const notes = graff.openDir(self.io, "eval-notes", .{ .iterate = true, .follow_symlinks = false }) catch return null;
    if (builtin.os.tag != .windows) notes.setPermissions(self.io, dir_permissions) catch {
        notes.close(self.io);
        return null;
    };
    return notes;
}

fn readNotes(self: anytype, dir: Io.Dir, name: []const u8) ![]u8 {
    const file = try dir.openFile(self.io, name, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(self.io);
    const stat = try file.stat(self.io);
    if (stat.kind != .file) return error.InvalidNotesFile;
    if (builtin.os.tag != .windows) try file.setPermissions(self.io, file_permissions);
    var reader = file.reader(self.io, &.{});
    return reader.interface.allocRemaining(self.arena, .limited(max_notes_bytes));
}

fn writeNotes(self: anytype, dir: Io.Dir, name: []const u8, text: []const u8) !void {
    var atomic = try dir.createFileAtomic(self.io, name, .{
        .permissions = file_permissions,
        .replace = true,
    });
    defer atomic.deinit(self.io);
    try atomic.file.writeStreamingAll(self.io, text);
    try atomic.file.sync(self.io);
    try atomic.replace(self.io);
}

fn loadAt(self: anytype, base: Io.Dir) []const u8 {
    if (self.eval_cmd == null) return "";
    const initial = initialNotes(self);
    const dir = openNotesDir(self, base) orelse return initial;
    defer dir.close(self.io);
    var name_buf: [72]u8 = undefined;
    const name = noteName(self, &name_buf);
    return readNotes(self, dir, name) catch {
        writeNotes(self, dir, name, initial) catch {};
        return initial;
    };
}

/// Return bounded local notes, creating the fixed template on first use.
pub fn load(self: anytype) []const u8 {
    return loadAt(self, Io.Dir.cwd());
}

fn recordAt(self: anytype, base: Io.Dir, note: []const u8, score: ?f64, exit_code: i32, met: bool) void {
    if (self.eval_cmd == null) return;
    const existing = loadAt(self, base);
    var note_buf: [512]u8 = undefined;
    const clean_note = oneLine(&note_buf, note);
    var line_buf: [768]u8 = undefined;
    const line = if (score) |value|
        std.fmt.bufPrint(&line_buf, "- eval #{d}: score={d:.2}, target={d}, exit={d}, met={s}; change={s}\n", .{
            self.eval_iter,
            value,
            self.eval_target,
            exit_code,
            if (met) "yes" else "no",
            if (clean_note.len > 0) clean_note else "(not supplied)",
        }) catch return
    else
        std.fmt.bufPrint(&line_buf, "- eval #{d}: score=unparsed, target={d}, exit={d}, met=no; change={s}\n", .{
            self.eval_iter,
            self.eval_target,
            exit_code,
            if (clean_note.len > 0) clean_note else "(not supplied)",
        }) catch return;

    var aw: Io.Writer.Allocating = .init(self.arena);
    const keep = if (existing.len + line.len <= max_notes_bytes) existing else initialNotes(self);
    aw.writer.writeAll(keep) catch return;
    if (keep.len > 0 and keep[keep.len - 1] != '\n') aw.writer.writeByte('\n') catch return;
    aw.writer.writeAll(line) catch return;
    const dir = openNotesDir(self, base) orelse return;
    defer dir.close(self.io);
    var name_buf: [72]u8 = undefined;
    writeNotes(self, dir, noteName(self, &name_buf), aw.writer.buffered()) catch {};
}

const TestTracer = struct {
    identity: struct { run_id: []const u8 },
};

test "eval notes are private, atomic, and do not follow symlinks" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var state = .{
        .arena = arena_state.allocator(),
        .io = io,
        .eval_cmd = @as(?[]const u8, "verify"),
        .tracer = @as(?*TestTracer, null),
        .eval_iter = @as(u32, 1),
        .eval_target = @as(u8, 90),
        .eval_niche = "",
    };
    try std.testing.expectEqualStrings(notes_template, loadAt(&state, tmp.dir));
    recordAt(&state, tmp.dir, "fixed\nsecret", 100, 0, true);

    const graff = try tmp.dir.openDir(io, ".graff", .{});
    defer graff.close(io);
    const notes = try graff.openDir(io, "eval-notes", .{});
    defer notes.close(io);
    try std.testing.expectEqual(@as(u32, 0), (try notes.stat(io)).permissions.toMode() & 0o077);
    const file = try notes.openFile(io, "session.md", .{ .follow_symlinks = false });
    defer file.close(io);
    try std.testing.expectEqual(@as(u32, 0), (try file.stat(io)).permissions.toMode() & 0o077);
    const content = try notes.readFileAlloc(io, "session.md", std.testing.allocator, .limited(max_notes_bytes));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "fixed secret") != null);

    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "do not overwrite" });
    try notes.deleteFile(io, "session.md");
    try notes.symLink(io, "../../outside", "session.md", .{});
    _ = loadAt(&state, tmp.dir);
    const outside = try tmp.dir.readFileAlloc(io, "outside", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(outside);
    try std.testing.expectEqualStrings("do not overwrite", outside);
}

fn oneLine(buf: []u8, value: []const u8) []const u8 {
    const source = value[0..@min(value.len, buf.len)];
    for (source, 0..) |ch, index| {
        buf[index] = if (ch < 0x20 or ch == 0x7f) ' ' else ch;
    }
    return std.mem.trim(u8, buf[0..source.len], " ");
}

/// Append one prompt-safe verifier fact. Command output and paths are never
/// copied here; only the model's bounded note plus numeric verifier state.
pub fn record(self: anytype, note: []const u8, score: ?f64, exit_code: i32, met: bool) void {
    recordAt(self, Io.Dir.cwd(), note, score, exit_code, met);
}
