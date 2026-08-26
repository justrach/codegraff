//! Licensed catalog/exec policy: one read/search surface, one edit surface.
//!
//! When codedb-pro is licensed, hide native `read_file` and legacy `codedb`.
//! Companion write tools (edit/patch/create/replace) are omitted always — they
//! bypass /rewind. Native `edit_file`/`write_file` stay. `subagent` stays.
//! webfetch is not hidden here (optional extra, not this change).

const std = @import("std");
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const tools = @import("tools.zig");
const mcp = @import("mcp.zig");

const companion_write = [_][]const u8{
    "edit", "patch", "create", "replace", "byte_delta",
};

const search_bash = [_][]const u8{
    "grep", "rg", "find", "cat", "head", "tail", "sed", "awk", "egrep", "ripgrep",
};

pub fn isSearchBash(first: []const u8) bool {
    for (search_bash) |w| if (std.mem.eql(u8, first, w)) return true;
    return false;
}

pub fn isCompanionWrite(qualified: []const u8) bool {
    const prefixes = [_][]const u8{ "mcp__codedbpro__", "mcp__muonry__" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, qualified, prefix)) continue;
        const bare = qualified[prefix.len..];
        for (companion_write) |w| if (std.mem.eql(u8, bare, w)) return true;
        return false;
    }
    return false;
}

/// MCP names that must not appear in any catalog (companion writes + bundled
/// smolify until opt-in connect actually adds it).
pub fn omitMcp(qualified: []const u8) bool {
    return isCompanionWrite(qualified);
}

/// Built-ins hidden from the advertised catalog. Never hides `subagent`.
pub fn hideBuiltin(name: []const u8) bool {
    if (!main_mod.g_codedbpro_licensed) return false;
    return std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "codedb");
}

pub fn filterSpecs(comptime Spec: type, arena: Allocator, specs: []const Spec) ![]const Spec {
    var drop: usize = 0;
    for (specs) |spec| {
        if (hideBuiltin(spec.name)) drop += 1;
    }
    if (drop == 0) return specs;
    const buf = try arena.alloc(Spec, specs.len - drop);
    var i: usize = 0;
    for (specs) |spec| {
        if (hideBuiltin(spec.name)) continue;
        buf[i] = spec;
        i += 1;
    }
    return buf[0..i];
}

/// Worker MCP: companion read/search only (no writes, no smolify).
pub fn keepWorkerMcp(qualified: []const u8) bool {
    if (omitMcp(qualified)) return false;
    return std.mem.startsWith(u8, qualified, "mcp__codedbpro__") or
        std.mem.startsWith(u8, qualified, "mcp__muonry__");
}

pub fn filterWorkerMcp(arena: Allocator, all: []const mcp.Tool) ![]const mcp.Tool {
    var n: usize = 0;
    for (all) |t| {
        if (keepWorkerMcp(t.qualified_name)) n += 1;
    }
    if (n == all.len) return all;
    const buf = try arena.alloc(mcp.Tool, n);
    var i: usize = 0;
    for (all) |t| {
        if (!keepWorkerMcp(t.qualified_name)) continue;
        buf[i] = t;
        i += 1;
    }
    return buf[0..i];
}

pub const companion_write_refusal =
    "codedb-pro write tools (edit/patch/create/replace) are hidden — they bypass /rewind. Use native edit_file for existing files and write_file for new files.";

pub fn gate(ctx: tools.ToolCtx, call: tools.ToolCall) ?tools.ToolOutput {
    if (!isCompanionWrite(call.name)) return null;
    const text = ctx.gpa.dupe(u8, companion_write_refusal) catch return .{ .text = &.{}, .is_error = true };
    return .{ .text = text, .is_error = true };
}

pub fn smolifyWanted(environ_map: anytype) bool {
    if (environ_map.get("GRAFF_NO_SMOLIFY") != null) return false;
    return environ_map.get("GRAFF_SMOLIFY") != null or environ_map.get("GRAFF_SMOLIFY_ACCESS") != null;
}

/// deepwiki / mobbin stay out of the default unauthenticated catalog unless
/// an explicit opt-in env names them.
pub fn skipOptionalServer(name: []const u8, environ_map: anytype) bool {
    if (std.mem.eql(u8, name, "deepwiki")) return !optionalAllowed("deepwiki", environ_map);
    if (std.mem.eql(u8, name, "mobbin")) return !optionalAllowed("mobbin", environ_map);
    return false;
}

fn optionalAllowed(name: []const u8, environ_map: anytype) bool {
    if (environ_map.get("GRAFF_MCP_OPTIONAL")) |v| {
        var it = std.mem.tokenizeAny(u8, v, ", ");
        while (it.next()) |tok| if (std.mem.eql(u8, tok, name)) return true;
    }
    if (std.mem.eql(u8, name, "deepwiki") and environ_map.get("GRAFF_DEEPWIKI") != null) return true;
    if (std.mem.eql(u8, name, "mobbin") and environ_map.get("GRAFF_MOBBIN") != null) return true;
    return false;
}

test "companion writes are omitted; reads are not" {
    try std.testing.expect(isCompanionWrite("mcp__codedbpro__edit"));
    try std.testing.expect(isCompanionWrite("mcp__codedbpro__patch"));
    try std.testing.expect(isCompanionWrite("mcp__codedbpro__create"));
    try std.testing.expect(isCompanionWrite("mcp__muonry__replace"));
    try std.testing.expect(!isCompanionWrite("mcp__codedbpro__read"));
    try std.testing.expect(!isCompanionWrite("mcp__codedbpro__faster_search"));
    try std.testing.expect(!omitMcp("mcp__smolify__search_docs"));
    try std.testing.expect(!omitMcp("mcp__codedbpro__read"));
    try std.testing.expect(keepWorkerMcp("mcp__codedbpro__read"));
    try std.testing.expect(!keepWorkerMcp("mcp__codedbpro__edit"));
}

test "hideBuiltin drops read_file/codedb only when licensed; never subagent" {
    const saved = main_mod.g_codedbpro_licensed;
    defer main_mod.g_codedbpro_licensed = saved;
    main_mod.g_codedbpro_licensed = false;
    try std.testing.expect(!hideBuiltin("read_file"));
    try std.testing.expect(!hideBuiltin("codedb"));
    try std.testing.expect(!hideBuiltin("subagent"));
    try std.testing.expect(!hideBuiltin("edit_file"));
    main_mod.g_codedbpro_licensed = true;
    try std.testing.expect(hideBuiltin("read_file"));
    try std.testing.expect(hideBuiltin("codedb"));
    try std.testing.expect(!hideBuiltin("subagent"));
    try std.testing.expect(!hideBuiltin("edit_file"));
    try std.testing.expect(!hideBuiltin("write_file"));
    try std.testing.expect(!hideBuiltin("webfetch"));
}

test "isSearchBash covers the licensed first-token list" {
    try std.testing.expect(isSearchBash("grep"));
    try std.testing.expect(isSearchBash("rg"));
    try std.testing.expect(isSearchBash("find"));
    try std.testing.expect(isSearchBash("cat"));
    try std.testing.expect(isSearchBash("head"));
    try std.testing.expect(isSearchBash("tail"));
    try std.testing.expect(isSearchBash("sed"));
    try std.testing.expect(isSearchBash("awk"));
    try std.testing.expect(isSearchBash("egrep"));
    try std.testing.expect(isSearchBash("ripgrep"));
    try std.testing.expect(!isSearchBash("git"));
    try std.testing.expect(!isSearchBash("zig"));
}

const FakeSpec = struct { name: []const u8 };
test "filterSpecs drops hidden builtins and leaves the rest" {
    const saved = main_mod.g_codedbpro_licensed;
    defer main_mod.g_codedbpro_licensed = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const specs = [_]FakeSpec{
        .{ .name = "bash" },
        .{ .name = "read_file" },
        .{ .name = "edit_file" },
        .{ .name = "codedb" },
        .{ .name = "subagent" },
    };
    main_mod.g_codedbpro_licensed = false;
    const all = try filterSpecs(FakeSpec, arena_state.allocator(), &specs);
    try std.testing.expectEqual(@as(usize, 5), all.len);
    main_mod.g_codedbpro_licensed = true;
    const filtered = try filterSpecs(FakeSpec, arena_state.allocator(), &specs);
    try std.testing.expectEqual(@as(usize, 3), filtered.len);
    try std.testing.expectEqualStrings("bash", filtered[0].name);
    try std.testing.expectEqualStrings("edit_file", filtered[1].name);
    try std.testing.expectEqualStrings("subagent", filtered[2].name);
}

test "licensed root catalog drops read_file and codedb, keeps subagent and edit_file" {
    const schema = @import("schema.zig");
    const saved = main_mod.g_codedbpro_licensed;
    defer main_mod.g_codedbpro_licensed = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    main_mod.g_codedbpro_licensed = false;
    const off = try schema.effectiveRootSpecs(a);
    var saw_read = false;
    var saw_sub = false;
    for (off) |t| {
        if (std.mem.eql(u8, t.name, "read_file")) saw_read = true;
        if (std.mem.eql(u8, t.name, "subagent")) saw_sub = true;
    }
    try std.testing.expect(saw_read);
    try std.testing.expect(saw_sub);

    main_mod.g_codedbpro_licensed = true;
    const on = try schema.effectiveRootSpecs(a);
    var saw_edit = false;
    var saw_sub2 = false;
    for (on) |t| {
        try std.testing.expect(!std.mem.eql(u8, t.name, "read_file"));
        try std.testing.expect(!std.mem.eql(u8, t.name, "codedb"));
        if (std.mem.eql(u8, t.name, "edit_file")) saw_edit = true;
        if (std.mem.eql(u8, t.name, "subagent")) saw_sub2 = true;
        if (std.mem.eql(u8, t.name, "write_file")) {}
    }
    try std.testing.expect(saw_edit);
    try std.testing.expect(saw_sub2);
}

test "smolifyWanted and skipOptionalServer are opt-in" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(!smolifyWanted(env));
    try std.testing.expect(skipOptionalServer("deepwiki", env));
    try std.testing.expect(skipOptionalServer("mobbin", env));
    try std.testing.expect(!skipOptionalServer("codedbpro", env));
    try env.put("GRAFF_SMOLIFY", "1");
    try std.testing.expect(smolifyWanted(env));
    try env.put("GRAFF_MCP_OPTIONAL", "deepwiki,mobbin");
    try std.testing.expect(!skipOptionalServer("deepwiki", env));
    try std.testing.expect(!skipOptionalServer("mobbin", env));
}

test "worker specs drop read_file/codedb; worker MCP keeps reads not writes" {
    const schema = @import("schema.zig");
    const saved = main_mod.g_codedbpro_licensed;
    defer main_mod.g_codedbpro_licensed = saved;
    main_mod.g_codedbpro_licensed = true;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const specs = try filterSpecs(@TypeOf(schema.base_specs[0]), a, schema.base_specs[0..]);
    var saw_edit = false;
    for (specs) |t| {
        try std.testing.expect(!std.mem.eql(u8, t.name, "read_file"));
        try std.testing.expect(!std.mem.eql(u8, t.name, "codedb"));
        try std.testing.expect(!std.mem.eql(u8, t.name, "subagent"));
        if (std.mem.eql(u8, t.name, "edit_file")) saw_edit = true;
    }
    try std.testing.expect(saw_edit);
    const fake = [_]mcp.Tool{
        .{ .server_index = 0, .original_name = "read", .qualified_name = "mcp__codedbpro__read", .description = "d", .input_schema = .null },
        .{ .server_index = 0, .original_name = "edit", .qualified_name = "mcp__codedbpro__edit", .description = "d", .input_schema = .null },
    };
    const kept = try filterWorkerMcp(a, &fake);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("mcp__codedbpro__read", kept[0].qualified_name);
    const mcp_gate = @import("mcp_schema_gate.zig");
    const saved_policy = mcp_gate.g_policy;
    defer mcp_gate.g_policy = saved_policy;
    mcp_gate.g_policy = .{ .eager = &.{"codedbpro"} };
    const json = try schema.renderRootTools(a, .openai, specs, kept);
    try std.testing.expect(std.mem.indexOf(u8, json, "mcp__codedbpro__read") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "read_file") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "mcp__codedbpro__edit") == null);
}
