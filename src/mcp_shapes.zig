//! Muscle memory for tool return shapes (Blacksmith): persist field names +
//! broad types, never values. Shown on the next load_tool_schemas RESULT, not
//! on the always-on catalog prefix (ADR 0011).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const tool_handle = @import("tool_handle.zig");
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

/// Session teardown (#1196): free the cache with the allocator that filled it,
/// before main()'s leak check. A no-op when nothing was stored.
pub fn shutdown(io: Io) void {
    store.mu.lockUncancelable(io);
    defer store.mu.unlock(io);
    clearUnlocked(store.gpa orelse return);
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

/// Fat enough that dumping the bind is the token problem C/D/F hit.
pub const slim_min_bytes: usize = 800;

const identity_keys = [_][]const u8{ "id", "identifier", "title", "name" };

/// Learnt projection: identity keys on issue-like rows; comments fold to
/// `{n, latest_author}`. Values of `description`/`body` never survive. An
/// each() bind (one whole result per item, ADR 0238) is cut item by item.
/// Returns null when the payload is small, not a JSON array of objects, or
/// has nothing to cut. Caller owns a non-null result.
pub fn slim(alloc: Allocator, payload: []const u8) ?[]u8 {
    if (payload.len < slim_min_bytes) return null;
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    const parsed = std.json.parseFromSlice(Value, alloc, trimmed, .{}) catch return null;
    defer parsed.deinit();
    const items = arrayItems(parsed.value) orelse return null;
    if (items.len == 0) return null;
    if (items[0] == .array or wrapsRows(items[0])) return slimEach(alloc, items);
    if (items[0] != .object) return null;
    return slimRows(alloc, items);
}

/// An each() item that is a whole `{"comments": [...]}`-style result, not a row.
fn wrapsRows(v: Value) bool {
    if (v != .object or hasIdentity(v.object) or looksLikeComments(v.object)) return false;
    return arrayItems(v) != null;
}

fn slimRows(alloc: Allocator, items: []const Value) ?[]u8 {
    if (items.len == 0 or items[0] != .object) return null;
    if (looksLikeComments(items[0].object)) return slimComments(alloc, items);
    return slimIdentity(alloc, items);
}

/// ADR 0238: print() of an each() bind shows each item's own cut, the view
/// the per-item slim used to bind. Null when no item had anything to cut.
fn slimEach(alloc: Allocator, items: []const Value) ?[]u8 {
    var aw: Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var cut_any = false;
    aw.writer.writeByte('[') catch return null;
    for (items, 0..) |item, i| {
        if (i > 0) aw.writer.writeByte(',') catch return null;
        if (slimRows(alloc, arrayItems(item) orelse &[_]Value{})) |cut| {
            defer alloc.free(cut);
            aw.writer.writeAll(cut) catch return null;
            cut_any = true;
            continue;
        }
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.write(item) catch return null;
    }
    aw.writer.writeByte(']') catch return null;
    if (!cut_any) return null;
    return aw.toOwnedSlice() catch null;
}

/// ADR 0238: project(x, "n" | "latest_author") over an each() bind reads a
/// comment list through its fold, so the printed view's fields stay
/// projectable. Null for any other field or a list that is not comments.
pub fn foldField(item: Value, field: []const u8) ?Value {
    const items = arrayItems(item) orelse return null;
    if (items.len > 0 and (items[0] != .object or !looksLikeComments(items[0].object))) return null;
    if (std.mem.eql(u8, field, "n")) return .{ .integer = @intCast(items.len) };
    if (!std.mem.eql(u8, field, "latest_author")) return null;
    if (items.len == 0) return .null;
    return .{ .string = authorName(items[latestIndex(items)]) orelse "" };
}

/// ADR 0240: the field names of a list result's first row (or of an each()
/// bind's first item's first row), comma-separated and capped, so a slim view
/// names what the whole value holds. Null when the payload has no object rows.
pub fn fieldList(alloc: Allocator, payload: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(Value, alloc, std.mem.trim(u8, payload, " \t\r\n"), .{}) catch return null;
    defer parsed.deinit();
    var items = arrayItems(parsed.value) orelse return null;
    if (items.len > 0 and items[0] != .object) items = arrayItems(items[0]) orelse return null;
    if (items.len == 0 or items[0] != .object) return null;
    var aw: Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var it = items[0].object.iterator();
    var n: usize = 0;
    while (it.next()) |e| : (n += 1) {
        if (n == 24 or aw.writer.buffered().len > 280) {
            aw.writer.writeAll(", ...") catch return null;
            break;
        }
        if (n > 0) aw.writer.writeAll(", ") catch return null;
        aw.writer.writeAll(e.key_ptr.*) catch return null;
    }
    return aw.toOwnedSlice() catch null;
}

/// Remember the fat payload, then replace it with the learnt cut when one
/// exists. `text` is owned by `gpa`.
pub fn takeSlim(gpa: Allocator, text: []u8) []u8 {
    const cut = slim(gpa, text) orelse return text;
    gpa.free(text);
    return cut;
}

/// ADR 0225: `takeSlim`, lossless. With `keep_in` the full payload is kept as
/// a tool-result handle that the slim result names, so a dropped field is one
/// read_tool_result away. Null or a failed write returns the plain cut. An
/// rlm bind never comes here: it keeps the whole result (ADR 0238).
pub fn takeSlimKept(gpa: Allocator, keep_in: ?tool_handle.Target, text: []u8) []u8 {
    const cut = slim(gpa, text) orelse return text;
    defer gpa.free(text);
    const target = keep_in orelse return cut;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const path = tool_handle.keep(arena_state.allocator(), target, text) orelse return cut;
    const fields = fieldList(gpa, text);
    defer if (fields) |f| gpa.free(f);
    const out = std.fmt.allocPrint(gpa, "{s}\n[slimmed from {d} bytes{s}{s}; the full result is handle {s} (read_tool_result reads any dropped field; in rlm, x = read_tool_result(\"{s}\") binds it whole for project() or write_file())]", .{ cut, text.len, if (fields != null) "; fields: " else "", fields orelse "", tool_handle.idOf(path), tool_handle.idOf(path) }) catch return cut;
    gpa.free(cut);
    return out;
}

fn arrayItems(v: Value) ?[]const Value {
    if (v == .array) return v.array.items;
    if (v != .object) return null;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .array) return e.value_ptr.array.items;
    }
    return null;
}

fn looksLikeComments(obj: std.json.ObjectMap) bool {
    return obj.get("body") != null and obj.get("author") != null;
}

fn latestIndex(items: []const Value) usize {
    var latest_i: usize = items.len - 1;
    var latest_at: []const u8 = "";
    for (items, 0..) |item, i| {
        if (item != .object) continue;
        const at = if (item.object.get("createdAt")) |c| (if (c == .string) c.string else "") else "";
        if (at.len == 0) continue;
        if (latest_at.len == 0 or std.mem.order(u8, at, latest_at) == .gt) {
            latest_at = at;
            latest_i = i;
        }
    }
    return latest_i;
}

fn slimComments(alloc: Allocator, items: []const Value) ?[]u8 {
    var aw: Io.Writer.Allocating = .init(alloc);
    writeCommentFold(&aw.writer, items) catch {
        aw.deinit();
        return null;
    };
    return aw.toOwnedSlice() catch null;
}

/// `{issue?, n, latest_author}`. `issue` is the parent every row names: the
/// fold otherwise loses which issue a list belongs to, and a model pairing
/// parallel results by position credited counts to the wrong issue.
fn writeCommentFold(w: *Io.Writer, items: []const Value) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    if (sharedParent(items)) |parent| {
        try s.objectField("issue");
        try s.write(parent);
    }
    try s.objectField("n");
    try s.write(items.len);
    try s.objectField("latest_author");
    try s.write(authorName(items[latestIndex(items)]) orelse "");
    try s.endObject();
}

/// The one parent id every row carries (`issueId`, `issue_id`, or a nested
/// `issue.identifier` / `issue.id`), or null when rows disagree or omit it.
fn sharedParent(items: []const Value) ?[]const u8 {
    for ([_][2][]const u8{ .{ "issueId", "" }, .{ "issue_id", "" }, .{ "issue", "identifier" }, .{ "issue", "id" } }) |path| {
        var shared: ?[]const u8 = null;
        for (items) |item| {
            const v = parentField(item, path[0], path[1]) orelse break;
            if (shared) |prev| if (!std.mem.eql(u8, prev, v)) break;
            shared = v;
        } else if (shared) |v| return v;
    }
    return null;
}

fn parentField(item: Value, key: []const u8, sub: []const u8) ?[]const u8 {
    if (item != .object) return null;
    var v = item.object.get(key) orelse return null;
    if (sub.len > 0) v = if (v == .object) (v.object.get(sub) orelse return null) else return null;
    return if (v == .string) v.string else null;
}

fn authorName(item: Value) ?[]const u8 {
    if (item != .object) return null;
    const author = item.object.get("author") orelse return null;
    if (author == .string) return author.string;
    if (author != .object) return null;
    const n = author.object.get("name") orelse return null;
    return if (n == .string) n.string else null;
}

fn slimIdentity(alloc: Allocator, items: []const Value) ?[]u8 {
    // #1426: a row known only by an opaque id (a transcript message) is all
    // content; a cut down to its ids would stand in for nothing readable.
    if (!hasLabel(items[0].object) or items[0].object.get("role") != null) return null;
    var aw: Io.Writer.Allocating = .init(alloc);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.beginArray() catch {
        aw.deinit();
        return null;
    };
    for (items) |item| {
        if (item != .object) continue;
        s.beginObject() catch {
            aw.deinit();
            return null;
        };
        for (identity_keys) |k| {
            const v = item.object.get(k) orelse continue;
            s.objectField(k) catch {
                aw.deinit();
                return null;
            };
            s.write(v) catch {
                aw.deinit();
                return null;
            };
        }
        s.endObject() catch {
            aw.deinit();
            return null;
        };
    }
    s.endArray() catch {
        aw.deinit();
        return null;
    };
    return aw.toOwnedSlice() catch null;
}

fn hasIdentity(obj: std.json.ObjectMap) bool {
    for (identity_keys) |k| if (obj.get(k) != null) return true;
    return false;
}

fn hasLabel(obj: std.json.ObjectMap) bool {
    for (identity_keys[1..]) |k| if (obj.get(k) != null) return true;
    return false;
}

/// Splice stored shapes onto a load_tool_schemas / search RESULT. Never call
/// this from catalog render (ADR 0011 prefix must stay byte-stable).
pub fn annotate(gpa: Allocator, arena: Allocator, io: Io, cwd: ?[]const u8, text: []const u8) ![]const u8 {
    store.mu.lockUncancelable(io);
    defer store.mu.unlock(io);
    loadUnlocked(gpa, io, cwd);
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll(text);
    try aw.writer.writeAll(slim_rule);
    if (store.map.count() == 0) return aw.toOwnedSlice();
    try aw.writer.writeAll("\nreturn_shapes (field names + broad types, never values):\n");
    var it = store.map.iterator();
    while (it.next()) |e| {
        try aw.writer.print("  {s}: {s}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
    if (store.map.count() >= 2) {
        try aw.writer.writeAll(
            "# muscle: fat MCP print() auto-slims rows (id/identifier/title/name; use row.id for \"id\" fields) and comment lists ({issue, n, latest_author}): issues=list_issues(); comments=each(issues,\"list_comments\",\"id\"); print(issues, comments)\n",
        );
    }
    return aw.toOwnedSlice();
}

/// ADR 0225: what `slim` (exec.zig) does to every large list result, said
/// where the model first meets the tools. Unsaid, the model wrote code for
/// the full rows, failed on the first missing field, and spent calls finding
/// the real shape. ADR 0238: rlm binds keep every field; only print() slims.
/// ADR 0240: computing over the results happens in the same script.
pub const slim_rule = "\nLarge list results from these tools are shown slimmed: rows keep only id/identifier/title/name, and a comment list becomes {\"issue\": its issue when the comments name one, \"n\": count, \"latest_author\": name}. A direct call's result names a handle holding the full result. In rlm a bind keeps every field: print() shows the slim view, project(x, field) reads any field, and write_file(\"f.json\", x) saves the whole result for a script. To compute over results in the same call, save them and run the computation inside the script: issues = tool(); write_file(\"issues.json\", issues); r = bash(\"python3 - <<'EOF'\\n...\\nEOF\"); print(r).";

pub fn lookup(io: Io, name: []const u8) ?[]const u8 {
    store.mu.lockUncancelable(io);
    defer store.mu.unlock(io);
    return store.map.get(name);
}

test "shutdown frees a filled cache and is a no-op when empty (#1196)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    shutdown(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    store.mu.lockUncancelable(io);
    putUnlocked(gpa, arena_state.allocator(), "linear_issues", "{\"type\":\"object\"}");
    store.mu.unlock(io);
    try std.testing.expectEqual(@as(usize, 1), store.map.count());
    shutdown(io); // testing.allocator fails the test on anything left behind
    try std.testing.expectEqual(@as(usize, 0), store.map.count());
    try std.testing.expect(store.gpa == null);
    shutdown(io);
}
