//! Scope, migration, and fail-closed regressions for issue #789.

const std = @import("std");
const Io = std.Io;

const Agent = @import("agent.zig").Agent;
const playbook = @import("playbook.zig");
const glue = @import("playbook_glue.zig");

fn inScratch(comptime body: fn (Io, std.mem.Allocator) anyerror!void) !void {
    if (@import("builtin").os.tag == .windows) return;
    const saved_inject = playbook.g_root_inject;
    defer playbook.g_root_inject = saved_inject;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try body(io, arena_state.allocator());
}

fn seedRaw(io: Io, raw: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, playbook.dir);
    const f = try Io.Dir.cwd().createFile(io, playbook.path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, raw, 0);
}

fn rootStub(arena: std.mem.Allocator, out: *Io.Writer) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "issue-789-test",
        .out = out,
        .session_name = "",
    };
}

fn call(arena: std.mem.Allocator, text: []const u8, scope: ?[]const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "text", .{ .string = text });
    if (scope) |s| try object.put(arena, "scope", .{ .string = s });
    return .{ .object = object };
}

test "#789 note_constraint writes only an exact explicit project rule" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.named_work_task = "For this task, do not add dots. Never delete generated files unless regeneration was explicitly requested. Never add telemetry in this project.";

            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "For this task, do not add dots.", null)).is_error);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "For this task, do not add dots.", "task")).is_error);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "do not add dots.", "project")).is_error);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "Never delete generated files", "project")).is_error);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "Never add any tracking anywhere.", "project")).is_error);
            try std.testing.expectEqual(@as(usize, 0), playbook.load(io, arena).len);

            const result = glue.noteConstraint(&root, try call(arena, "Never add telemetry in this project.", "project"));
            try std.testing.expect(!result.is_error);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "recorded project constraint") != null);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "scope=project") != null);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "origin=current user message") != null);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "/never rm <unique text>") != null);
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 1), items.len);
            try std.testing.expectEqual(playbook.Scope.project, items[0].scope);
            try std.testing.expectEqualStrings("Never add telemetry in this project.", items[0].text);
        }
    }.body);
}

test "#789 exact legacy and learned matches are promoted to user project policy" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            const legacy_text = "Keep generated snapshots stable.";
            var idbuf: [11]u8 = undefined;
            const legacy_id = try arena.dupe(u8, playbook.idFor(&idbuf, legacy_text));
            const raw = try std.fmt.allocPrint(arena, "{{\"v\":1,\"op\":\"add\",\"id\":\"{s}\",\"text\":\"{s}\",\"source\":\"user\",\"provenance\":\"user:1\",\"created_at\":1}}\n", .{ legacy_id, legacy_text });
            try seedRaw(io, raw);

            const learned_text = "Prefer deterministic fixtures.";
            const learned = playbook.add(io, arena, learned_text, .learned, "run:1");
            try std.testing.expect(learned.ok);

            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.named_work_task = legacy_text;
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, legacy_text, "project")).is_error);
            const promoted_legacy = playbook.find(playbook.load(io, arena), legacy_id).?;
            try std.testing.expectEqual(playbook.Source.user, promoted_legacy.source);
            try std.testing.expectEqual(playbook.Scope.project, promoted_legacy.scope);
            try std.testing.expectEqualStrings(legacy_text, promoted_legacy.text);

            root.named_work_task = learned_text;
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, learned_text, "project")).is_error);
            const promoted_learned = playbook.find(playbook.load(io, arena), learned.id).?;
            try std.testing.expectEqual(playbook.Source.user, promoted_learned.source);
            try std.testing.expectEqual(playbook.Scope.project, promoted_learned.scope);
            try std.testing.expectEqualStrings(learned_text, promoted_learned.text);
        }
    }.body);
}

test "#789 normalized id collisions never claim different exact text was recorded" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.named_work_task = "Use C in project builds.";
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, root.named_work_task, "project")).is_error);

            root.named_work_task = "Use C++ in project builds.";
            const collision = glue.noteConstraint(&root, try call(arena, root.named_work_task, "project"));
            try std.testing.expect(collision.is_error);
            try std.testing.expect(std.mem.indexOf(u8, collision.text, "collision") != null);
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 1), items.len);
            try std.testing.expectEqualStrings("Use C in project builds.", items[0].text);
        }
    }.body);
}

test "#789 overlong automatic capture is rejected instead of truncating qualifiers" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            const text = try arena.alloc(u8, playbook.max_text + 1);
            @memset(text, 'x');
            root.named_work_task = text;
            const result = glue.noteConstraint(&root, try call(arena, text, "project"));
            try std.testing.expect(result.is_error);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "240-byte") != null);
            try std.testing.expectEqual(@as(usize, 0), playbook.load(io, arena).len);
        }
    }.body);
}

test "#789 storage preserves meaningful leading flags and trailing globs verbatim" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            try std.testing.expect(playbook.add(io, arena, "  --no-telemetry must be passed in this project.  ", .user, "user:1").ok);
            try std.testing.expect(playbook.add(io, arena, "Never modify generated-*", .user, "user:2").ok);
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 2), items.len);
            try std.testing.expectEqualStrings("--no-telemetry must be passed in this project.", items[0].text);
            try std.testing.expectEqualStrings("Never modify generated-*", items[1].text);
        }
    }.body);
}

test "#789 v1 user records are legacy unscoped and visibly require review" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = playbook.parse(arena,
        \\{"v":1,"op":"add","id":"pb-legacy01","text":"do not add dots right now","source":"user","provenance":"user:1","created_at":1}
    );
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(playbook.Scope.legacy_unscoped, items[0].scope);
    const block = playbook.blockFrom(arena, items);
    try std.testing.expect(std.mem.indexOf(u8, block, playbook.legacy_header) != null);
    try std.testing.expect(std.mem.indexOf(u8, block, playbook.user_header) == null);
    const state = try playbook.recordedState(arena, items);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"scope\":\"legacy_unscoped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, playbook.authority_note, "require user review with /never") != null);
}
