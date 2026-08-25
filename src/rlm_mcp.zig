//! MCP-inside-rlm: after `load_tool_schemas` unfolds a tool, an rlm script
//! may call that name as a host function (same exec_mod path). Unloaded
//! names are refused. Deferral can only subtract. GRAFF_RLM_MCP=0 restores
//! today's structured-only gap. Does not import schema.zig.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const spec_ptc = @import("spec_ptc.zig");
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const mcp = @import("mcp.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const rlm_spec = @import("rlm_spec.zig");

/// Test / env seam. `applyEnvKnobs` sets this from GRAFF_RLM_MCP.
pub var host_enabled: bool = true;

pub const Prep = union(enum) {
    run: spec_ptc.Call,
    refuse: ToolOutput,
};

pub fn looksMcp(name: []const u8) bool {
    return mcp.Registry.isMcp(name);
}

pub fn resolve(ctx: ToolCtx, name: []const u8) ?[]const u8 {
    if (mcp.Registry.isMcp(name)) return name;
    const reg = ctx.registry orelse return null;
    var hit: ?[]const u8 = null;
    for (reg.tools) |t| {
        if (!std.mem.eql(u8, shortName(t.qualified_name), name)) continue;
        if (hit != null) return null; // ambiguous
        hit = t.qualified_name;
    }
    return hit;
}

fn shortName(qualified: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, qualified, "mcp__")) return qualified;
    const rest = qualified["mcp__".len..];
    const sep = std.mem.indexOf(u8, rest, "__") orelse return qualified;
    return rest[sep + 2 ..];
}

pub fn prepare(ctx: ToolCtx, arena: Allocator, call: spec_ptc.Call) Prep {
    if (!host_enabled) {
        return .{ .refuse = fail(ctx, "rlm: MCP host functions are off (GRAFF_RLM_MCP=0) — use structured MCP calls or drop the env") };
    }
    const qualified = resolve(ctx, call.name) orelse {
        if (looksMcp(call.name))
            return .{ .refuse = fail(ctx, "rlm: unknown MCP tool") };
        return .{ .run = call };
    };
    const reg = ctx.registry orelse {
        return .{ .refuse = fail(ctx, "MCP not available in this context") };
    };
    if (mcp_schema_gate.blocked(reg.tools, qualified)) {
        return .{ .refuse = fail(ctx, "rlm: MCP tool schema is not loaded — call load_tool_schemas first (deferral only; consent is unchanged)") };
    }
    const args = remapArgs(arena, reg, qualified, call.args_json) catch call.args_json;
    return .{ .run = .{ .name = qualified, .args_json = args } };
}

fn fail(ctx: ToolCtx, msg: []const u8) ToolOutput {
    return .{ .text = ctx.gpa.dupe(u8, msg) catch &.{}, .is_error = true };
}

fn remapArgs(arena: Allocator, reg: *mcp.Registry, qualified: []const u8, args_json: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(Value, arena, args_json, .{}) catch return args_json;
    if (parsed.value != .object) return args_json;
    if (parsed.value.object.get("arg") == null) return args_json;
    if (parsed.value.object.count() != 1) return args_json;
    const field = firstField(reg, qualified) orelse return args_json;
    const val = parsed.value.object.get("arg").?;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, field, val);
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(Value{ .object = obj });
    return aw.toOwnedSlice();
}

fn firstField(reg: *mcp.Registry, qualified: []const u8) ?[]const u8 {
    const tool = for (reg.tools) |t| {
        if (std.mem.eql(u8, t.qualified_name, qualified)) break t;
    } else return null;
    if (tool.input_schema != .object) return null;
    if (tool.input_schema.object.get("required")) |req| {
        if (req == .array and req.array.items.len > 0 and req.array.items[0] == .string)
            return req.array.items[0].string;
    }
    if (tool.input_schema.object.get("properties")) |props| {
        if (props == .object) {
            var it = props.object.iterator();
            if (it.next()) |e| return e.key_ptr.*;
        }
    }
    return null;
}

pub const StmtHit = union(enum) { miss, ok, fail: []u8 };

/// `each(arr, tool, field)` — map a JSON array through one host tool.
/// Smallest control flow that makes `for issue in list_issues(): list_comments(id)` honest.
pub fn evalEach(
    ctx: ToolCtx,
    arena: Allocator,
    stmt: []const u8,
    binds: []const rlm_spec.Binding,
    bind_out: *std.ArrayList(rlm_spec.Binding),
    run: *const fn (ToolCtx, spec_ptc.Call) ToolOutput,
) !StmtHit {
    const parsed = parseEach(arena, stmt) orelse return .miss;
    const arr_text = resolveBind(binds, parsed.arr) orelse parsed.arr;
    const tool = stripQuotes(parsed.tool);
    const field = stripQuotes(parsed.field);
    const items = jsonArray(arena, arr_text) catch {
        return .{ .fail = try std.fmt.allocPrint(ctx.gpa, "rlm: each() needs a JSON array (got {s})", .{arr_text}) };
    };
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(arena, ',');
        const val = fieldValue(arena, item, field) catch {
            return .{ .fail = try std.fmt.allocPrint(ctx.gpa, "rlm: each() item missing field {s}", .{field}) };
        };
        const args = try std.fmt.allocPrint(arena, "{{\"arg\":{s}}}", .{val});
        const call: spec_ptc.Call = .{ .name = tool, .args_json = args };
        const ready = switch (prepare(ctx, arena, call)) {
            .refuse => |r| return .{ .fail = r.text },
            .run => |c| c,
        };
        const got = run(ctx, ready);
        defer ctx.gpa.free(got.text);
        if (got.is_error) return .{ .fail = try ctx.gpa.dupe(u8, got.text) };
        const piece = jsonOrString(arena, got.text);
        try out.appendSlice(arena, piece);
    }
    try out.append(arena, ']');
    const text = try out.toOwnedSlice(arena);
    if (parsed.assign) |nm| try bind_out.append(arena, .{ .name = try arena.dupe(u8, nm), .text = try arena.dupe(u8, text) });
    return .ok;
}

const Each = struct { assign: ?[]const u8, arr: []const u8, tool: []const u8, field: []const u8 };

fn parseEach(arena: Allocator, stmt: []const u8) ?Each {
    const trimmed = std.mem.trim(u8, stmt, " \t");
    var rest = trimmed;
    var assign: ?[]const u8 = null;
    const paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, trimmed[0..paren], '=')) |eq| {
        const lhs = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (lhs.len == 0) return null;
        assign = lhs;
        rest = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    }
    if (!std.mem.startsWith(u8, rest, "each(") or rest[rest.len - 1] != ')') return null;
    const inner = rest["each(".len .. rest.len - 1];
    const parts = spec_ptc.splitTopLevel(arena, inner, ',') catch return null;
    if (parts.len != 3) return null;
    return .{ .assign = assign, .arr = parts[0], .tool = parts[1], .field = parts[2] };
}

fn resolveBind(binds: []const rlm_spec.Binding, name: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, name, " \t");
    var i = binds.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, binds[i].name, t)) return binds[i].text;
    }
    return null;
}

fn stripQuotes(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

fn jsonArray(arena: Allocator, text: []const u8) ![]const Value {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const parsed = try std.json.parseFromSlice(Value, arena, trimmed, .{});
    if (parsed.value == .array) return parsed.value.array.items;
    if (parsed.value == .object) {
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .array) return e.value_ptr.array.items;
        }
    }
    return error.NotArray;
}

fn fieldValue(arena: Allocator, item: Value, field: []const u8) ![]const u8 {
    if (item != .object) return error.NotObject;
    const v = item.object.get(field) orelse return error.Missing;
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(v);
    return aw.toOwnedSlice();
}

fn jsonOrString(arena: Allocator, text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.json.parseFromSlice(Value, arena, trimmed, .{})) |_| {
        return trimmed;
    } else |_| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.write(trimmed) catch return trimmed;
        return aw.toOwnedSlice() catch trimmed;
    }
}

test "unloaded MCP name is refused; loaded name is prepared for exec" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    mcp_schema_gate.reset();
    defer mcp_schema_gate.reset();
    mcp_schema_gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };
    const all = try @import("mcp_schema_gate_tests.zig").fixture(arena, "fat", 2, 200);
    var registry = mcp.Registry.empty(gpa, io);
    defer registry.deinit();
    registry.tools = all;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const ctx: ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &dummy_client,
        .provider = undefined,
        .registry = &registry,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
    const saved = host_enabled;
    defer host_enabled = saved;
    host_enabled = true;
    const call: spec_ptc.Call = .{ .name = "mcp__fat__t0", .args_json = "{}" };
    switch (prepare(ctx, arena, call)) {
        .refuse => |r| {
            defer gpa.free(r.text);
            try std.testing.expect(r.is_error);
            try std.testing.expect(std.mem.indexOf(u8, r.text, "load_tool_schemas") != null);
        },
        .run => return error.ShouldRefuseUnloaded,
    }
    const req = try std.json.parseFromSliceLeaky(Value, arena, "{\"tools\":[\"mcp__fat__t0\"]}", .{ .allocate = .alloc_always });
    _ = try mcp_schema_gate.loadInto(arena, all, req);
    try std.testing.expect(mcp_schema_gate.isLoaded("mcp__fat__t0"));
    switch (prepare(ctx, arena, call)) {
        .run => |c| try std.testing.expectEqualStrings("mcp__fat__t0", c.name),
        .refuse => return error.ShouldDispatchLoaded,
    }
    host_enabled = false;
    switch (prepare(ctx, arena, call)) {
        .refuse => |r| {
            defer gpa.free(r.text);
            try std.testing.expect(std.mem.indexOf(u8, r.text, "GRAFF_RLM_MCP") != null);
        },
        .run => return error.ShouldRefuseWhenOff,
    }
}

test "short name resolves when unique and loaded; consent/deferral still block" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    mcp_schema_gate.reset();
    defer mcp_schema_gate.reset();
    mcp_schema_gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };
    const all = try @import("mcp_schema_gate_tests.zig").fixture(arena, "fat", 1, 200);
    var registry = mcp.Registry.empty(gpa, io);
    defer registry.deinit();
    registry.tools = all;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const ctx: ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &dummy_client,
        .provider = undefined,
        .registry = &registry,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
    try std.testing.expectEqualStrings("mcp__fat__t0", resolve(ctx, "t0").?);
    try std.testing.expect(mcp_schema_gate.blocked(all, "mcp__fat__t0"));
    const req = try std.json.parseFromSliceLeaky(Value, arena, "{\"tools\":[\"mcp__fat__t0\"]}", .{ .allocate = .alloc_always });
    _ = try mcp_schema_gate.loadInto(arena, all, req);
    try std.testing.expect(!mcp_schema_gate.blocked(all, "mcp__fat__t0"));
}

test "each() maps a JSON array through a host function" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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
    };
    const binds = [_]rlm_spec.Binding{.{ .name = "issues", .text = "[{\"id\":\"A\"},{\"id\":\"B\"}]" }};
    var bind_out: std.ArrayList(rlm_spec.Binding) = .empty;
    const run = struct {
        fn go(_: ToolCtx, call: spec_ptc.Call) ToolOutput {
            const g = std.testing.allocator;
            if (std.mem.indexOf(u8, call.args_json, "A") != null)
                return .{ .text = g.dupe(u8, "{\"n\":1}") catch &.{} };
            return .{ .text = g.dupe(u8, "{\"n\":2}") catch &.{} };
        }
    }.go;
    const hit = try evalEach(ctx, arena, "out = each(issues, \"echo\", \"id\")", &binds, &bind_out, run);
    try std.testing.expect(hit == .ok);
    try std.testing.expectEqual(@as(usize, 1), bind_out.items.len);
    try std.testing.expect(std.mem.indexOf(u8, bind_out.items[0].text, "\"n\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bind_out.items[0].text, "\"n\":2") != null);
}
