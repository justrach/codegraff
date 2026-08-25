//! Muscle memory for tool return shapes (Blacksmith): persist field names +
//! broad types, never values. Shown on the next load_tool_schemas RESULT, not
//! on the always-on catalog prefix (ADR 0011).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;

pub const file_name = "mcp-shapes.json";
pub const rel_path = ".graff/mcp-shapes.json";

const Store = struct {
    mu: Io.Mutex = .init,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    gpa: ?Allocator = null,
};

var store: Store = .{};

pub fn reset(gpa: Allocator, io: Io) void {
    store.mu.lockUncancelable(io);
    defer store.mu.unlock(io);
    clearUnlocked(gpa);
}

fn clearUnlocked(gpa: Allocator) void {
    var it = store.map.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    store.map.deinit(gpa);
    store.map = .empty;
    store.gpa = null;
}

/// Infer a value-free schema from a tool result. Best-effort JSON; anything
/// else is just `{"type":"string"}` so we never persist payload bytes.
pub fn infer(arena: Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return try arena.dupe(u8, "{\"type\":\"string\"}");
    const parsed = std.json.parseFromSlice(Value, arena, trimmed, .{}) catch
        return try arena.dupe(u8, "{\"type\":\"string\"}");
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeShape(arena, &s, parsed.value, 0);
    return aw.toOwnedSlice();
}

fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn writeShape(arena: Allocator, s: *std.json.Stringify, v: Value, depth: u8) anyerror!void {
    try s.beginObject();
    try s.objectField("type");
    try s.write(typeName(v));
    if (depth >= 3) {
        try s.endObject();
        return;
    }
    switch (v) {
        .object => |obj| {
            try s.objectField("keys");
            try s.beginObject();
            var it = obj.iterator();
            while (it.next()) |e| {
                try s.objectField(e.key_ptr.*);
                try writeKeyType(arena, s, e.value_ptr.*, depth + 1);
            }
            try s.endObject();
        },
        .array => |arr| {
            try s.objectField("items");
            if (arr.items.len == 0) {
                try s.write("any");
            } else {
                try writeMergedItems(arena, s, arr.items, depth + 1);
            }
        },
        else => {},
    }
    try s.endObject();
}

fn writeKeyType(arena: Allocator, s: *std.json.Stringify, v: Value, depth: u8) anyerror!void {
    if ((v == .object or v == .array) and depth < 3) return writeShape(arena, s, v, depth);
    try s.write(typeName(v));
}

fn writeMergedItems(arena: Allocator, s: *std.json.Stringify, items: []const Value, depth: u8) anyerror!void {
    const cap = @min(items.len, 4);
    if (items[0] != .object) return writeShape(arena, s, items[0], depth);
    var keys: std.StringHashMapUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        if (items[i] != .object) continue;
        var it = items[i].object.iterator();
        while (it.next()) |e| {
            const t = typeName(e.value_ptr.*);
            if (keys.get(e.key_ptr.*)) |old| {
                if (!std.mem.eql(u8, old, t) and !std.mem.eql(u8, old, "any"))
                    try keys.put(arena, e.key_ptr.*, "any");
            } else {
                try keys.put(arena, e.key_ptr.*, t);
            }
        }
    }
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("keys");
    try s.beginObject();
    var it = keys.iterator();
    while (it.next()) |e| {
        try s.objectField(e.key_ptr.*);
        try s.write(e.value_ptr.*);
    }
    try s.endObject();
    try s.endObject();
}

fn mergeShapes(arena: Allocator, old_s: []const u8, new_s: []const u8) ![]const u8 {
    const old_p = std.json.parseFromSlice(Value, arena, old_s, .{}) catch return new_s;
    const new_p = std.json.parseFromSlice(Value, arena, new_s, .{}) catch return old_s;
    const old_keys = keysOf(old_p.value);
    const new_keys = keysOf(new_p.value);
    if (old_keys == null or new_keys == null) return new_s;
    var merged: std.json.ObjectMap = .empty;
    var it = old_keys.?.iterator();
    while (it.next()) |e| try merged.put(arena, e.key_ptr.*, e.value_ptr.*);
    var it2 = new_keys.?.iterator();
    while (it2.next()) |e| {
        if (merged.get(e.key_ptr.*)) |old_t| {
            if (old_t == .string and e.value_ptr.* == .string and
                !std.mem.eql(u8, old_t.string, e.value_ptr.string))
                try merged.put(arena, e.key_ptr.*, .{ .string = "any" });
        } else try merged.put(arena, e.key_ptr.*, e.value_ptr.*);
    }
    const typ = if (old_p.value == .object) old_p.value.object.get("type") else null;
    var out: std.json.ObjectMap = .empty;
    try out.put(arena, "type", typ orelse .{ .string = "object" });
    if (old_p.value == .object) if (old_p.value.object.get("items")) |_| {
        var items: std.json.ObjectMap = .empty;
        try items.put(arena, "type", .{ .string = "object" });
        try items.put(arena, "keys", .{ .object = merged });
        try out.put(arena, "items", .{ .object = items });
        var aw: Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.write(Value{ .object = out });
        return aw.toOwnedSlice();
    };
    try out.put(arena, "keys", .{ .object = merged });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(Value{ .object = out });
    return aw.toOwnedSlice();
}

fn keysOf(v: Value) ?std.json.ObjectMap {
    if (v != .object) return null;
    if (v.object.get("keys")) |k| if (k == .object) return k.object;
    if (v.object.get("items")) |items| {
        if (items == .object) if (items.object.get("keys")) |k| if (k == .object) return k.object;
    }
    return null;
}

pub fn remember(ctx: ToolCtx, name: []const u8, text: []const u8) void {
    if (name.len == 0 or text.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shape = infer(arena, text) catch return;
    store.mu.lockUncancelable(ctx.io);
    defer store.mu.unlock(ctx.io);
    loadUnlocked(ctx.gpa, ctx.io, ctx.agent_cwd);
    putUnlocked(ctx.gpa, arena, name, shape);
    persistUnlocked(ctx.gpa, ctx.io, ctx.agent_cwd);
}

fn putUnlocked(gpa: Allocator, arena: Allocator, name: []const u8, shape: []const u8) void {
    const merged = if (store.map.get(name)) |old|
        mergeShapes(arena, old, shape) catch shape
    else
        shape;
    const owned_shape = gpa.dupe(u8, merged) catch return;
    if (store.map.getPtr(name)) |slot| {
        gpa.free(slot.*);
        slot.* = owned_shape;
        return;
    }
    const owned_name = gpa.dupe(u8, name) catch {
        gpa.free(owned_shape);
        return;
    };
    store.map.put(gpa, owned_name, owned_shape) catch {
        gpa.free(owned_name);
        gpa.free(owned_shape);
        return;
    };
    store.gpa = gpa;
}

fn loadUnlocked(gpa: Allocator, io: Io, cwd: ?[]const u8) void {
    if (store.map.count() > 0) return;
    const opened = openBase(io, cwd) orelse return;
    defer closeBase(io, opened, cwd);
    const raw = opened.dir.readFileAlloc(io, rel_path, gpa, .limited(64 * 1024)) catch return;
    defer gpa.free(raw);
    const parsed = std.json.parseFromSlice(Value, gpa, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object and e.value_ptr.* != .string) continue;
        var aw: Io.Writer.Allocating = .init(gpa);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.write(e.value_ptr.*) catch {
            aw.deinit();
            continue;
        };
        const shape = aw.toOwnedSlice() catch continue;
        const name = gpa.dupe(u8, e.key_ptr.*) catch {
            gpa.free(shape);
            continue;
        };
        store.map.put(gpa, name, shape) catch {
            gpa.free(name);
            gpa.free(shape);
        };
    }
    store.gpa = gpa;
}

fn persistUnlocked(gpa: Allocator, io: Io, cwd: ?[]const u8) void {
    const opened = openBase(io, cwd) orelse return;
    defer closeBase(io, opened, cwd);
    opened.dir.createDir(io, ".graff", .default_dir) catch {};
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.beginObject() catch return;
    var it = store.map.iterator();
    while (it.next()) |e| {
        s.objectField(e.key_ptr.*) catch return;
        const parsed = std.json.parseFromSlice(Value, gpa, e.value_ptr.*, .{}) catch continue;
        defer parsed.deinit();
        s.write(parsed.value) catch return;
    }
    s.endObject() catch return;
    opened.dir.writeFile(io, .{ .sub_path = rel_path, .data = aw.writer.buffered() }) catch {};
}

const Opened = struct { dir: Io.Dir, owned: bool };

fn openBase(io: Io, cwd: ?[]const u8) ?Opened {
    if (cwd) |p| {
        const d = Io.Dir.cwd().openDir(io, p, .{}) catch return null;
        return .{ .dir = d, .owned = true };
    }
    return .{ .dir = Io.Dir.cwd(), .owned = false };
}

fn closeBase(io: Io, opened: Opened, _: ?[]const u8) void {
    if (opened.owned) {
        var d = opened.dir;
        d.close(io);
    }
}

/// Splice stored shapes onto a load_tool_schemas / search RESULT. Never call
/// this from catalog render (ADR 0011 prefix must stay byte-stable).
pub fn annotate(gpa: Allocator, arena: Allocator, io: Io, cwd: ?[]const u8, text: []const u8) ![]const u8 {
    store.mu.lockUncancelable(io);
    defer store.mu.unlock(io);
    loadUnlocked(gpa, io, cwd);
    if (store.map.count() == 0) return text;
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll(text);
    try aw.writer.writeAll("\nreturn_shapes (field names + broad types, never values):\n");
    var it = store.map.iterator();
    while (it.next()) |e| {
        try aw.writer.print("  {s}: {s}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
    return aw.toOwnedSlice();
}

pub fn lookup(io: Io, name: []const u8) ?[]const u8 {
    store.mu.lockUncancelable(io);
    defer store.mu.unlock(io);
    return store.map.get(name);
}

test "infer strips values and keeps keys plus broad types" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const shape = try infer(a,
        \\[{"id":"ISS-1","title":"Login","n":3,"ok":true,"meta":{"x":1},"tags":["a"]}]
    );
    try std.testing.expect(std.mem.indexOf(u8, shape, "ISS-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "Login") == null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "string") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "number") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "bool") != null);
}

test "remember merges keys; annotate splices shapes; prefix text is untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..n];
    reset(gpa, io);
    defer reset(gpa, io);
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const ctx: ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &dummy_client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = dir,
    };
    remember(ctx, "mcp__linear__list_issues", "[{\"id\":\"A\",\"title\":\"t\"}]");
    remember(ctx, "mcp__linear__list_issues", "[{\"id\":\"B\",\"state\":\"open\"}]");
    const hit = lookup(io, "mcp__linear__list_issues") orelse return error.MissingShape;
    try std.testing.expect(std.mem.indexOf(u8, hit, "\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "\"A\"") == null);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const annotated = try annotate(gpa, arena_state.allocator(), io, dir, "1 tool schema(s) below\nmcp__linear__list_issues");
    try std.testing.expect(std.mem.indexOf(u8, annotated, "return_shapes") != null);
    try std.testing.expect(std.mem.indexOf(u8, annotated, "mcp__linear__list_issues") != null);
    try std.testing.expect(std.mem.indexOf(u8, @import("mcp_schema_gate.zig").tool_desc, "return_shapes") == null);
}
