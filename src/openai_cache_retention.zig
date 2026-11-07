//! Retention probe bodies for OpenAI's 12-hour prompt cache.
//!
//! Builds the request through `Agent.buildBody` (the real OpenAI provider
//! path). The operator script posts those bytes; this module never logs keys.

const std = @import("std");
const Io = std.Io;
const cache = @import("openai_prompt_cache.zig");
const bodies = @import("agent_request_body_responses.zig");

pub const pinned_key = "graff-openai-cache-retention-v1";
pub const default_model = "gpt-5.6";
pub const default_state = "bench/openai-cache-retention-state.json";
pub const default_log = "bench/openai-cache-retention.json";
pub const tools_json =
    \\[{"type":"function","name":"probe_echo","description":"Echo a short acknowledgement. Used only to put a tool definition on the cached prefix.","parameters":{"type":"object","properties":{"note":{"type":"string"}},"additionalProperties":false}}]
;

pub const Case = struct {
    name: []const u8,
    ttl: cache.Ttl,
};

pub const cases = [_]Case{
    .{ .name = "12h", .ttl = .twelve_h },
    .{ .name = "30m", .ttl = .thirty_m },
};

pub fn nonceOf(kind: []const u8, stamp: []const u8) [96]u8 {
    var out: [96]u8 = undefined;
    const n = std.fmt.bufPrint(&out, "graff-{s}-{s}", .{ kind, stamp }) catch unreachable;
    @memset(out[n.len..], 0);
    return out;
}

pub fn stablePrefix(allocator: std.mem.Allocator, nonce: []const u8) ![]u8 {
    const line = "Stable operating instructions for the OpenAI prompt-cache retention probe. ";
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("nonce={s}\n", .{nonce});
    var i: usize = 0;
    while (i < 80) : (i += 1) try aw.writer.writeAll(line);
    return aw.toOwnedSlice();
}

pub fn buildProbeBody(arena: std.mem.Allocator, model: []const u8, ttl: cache.Ttl, nonce: []const u8) ![]u8 {
    cache.setOverride(ttl);
    defer cache.clearOverride();
    const prefix = try stablePrefix(arena, nonce);
    var agent = try bodies.testAgentFor(arena, "openai", .responses, model);
    agent.sys_normal = prefix;
    agent.reasoning = .low;
    const raw = try agent.buildBody(tools_json, false, true, true);
    defer std.testing.allocator.free(raw);
    return pinBody(arena, raw);
}

fn pinBody(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    const streamed = try std.mem.replaceOwned(u8, arena, raw, "\"stream\":true", "\"stream\":false");
    const prefix = "\"prompt_cache_key\":\"";
    const start = std.mem.indexOf(u8, streamed, prefix) orelse return error.MissingCacheKey;
    const val_start = start + prefix.len;
    const val_end = std.mem.indexOfPos(u8, streamed, val_start, "\"") orelse return error.MissingCacheKey;
    const keyed = try std.mem.concat(arena, u8, &.{ streamed[0..val_start], pinned_key, streamed[val_end..] });
    if (keyed.len == 0 or keyed[keyed.len - 1] != '}') return keyed;
    return std.mem.concat(arena, u8, &.{ keyed[0 .. keyed.len - 1], ",\"max_output_tokens\":16}" });
}

pub fn hasBreakpointTtl(body: []const u8, ttl: []const u8) bool {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"prompt_cache_breakpoint\":{{\"mode\":\"explicit\",\"ttl\":\"{s}\"}}", .{ttl}) catch return false;
    return std.mem.indexOf(u8, body, needle) != null;
}

test "retention probe bodies use the OpenAI Responses provider path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const stamp = "unit";
    var n12 = nonceOf("12h", stamp);
    var n30 = nonceOf("30m", stamp);
    const b12 = try buildProbeBody(a, default_model, .twelve_h, std.mem.sliceTo(&n12, 0));
    const b30 = try buildProbeBody(a, default_model, .thirty_m, std.mem.sliceTo(&n30, 0));
    try std.testing.expect(std.mem.indexOf(u8, b12, "\"prompt_cache_key\":\"graff-openai-cache-retention-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b30, "\"prompt_cache_key\":\"graff-openai-cache-retention-v1\"") != null);
    try std.testing.expect(hasBreakpointTtl(b12, "12h"));
    try std.testing.expect(!hasBreakpointTtl(b30, "12h"));
    try std.testing.expect(std.mem.indexOf(u8, b30, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, b12, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, b12, "probe_echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, b12, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b12, "\"content\":\"hello\",\"prompt_cache_breakpoint\"") == null);
    try std.testing.expect(b12.len > 2000);
}

test "openai cache retention materialize" {
    const mode = std.c.getenv("GRAFF_OPENAI_CACHE_RETENTION") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(mode), "materialize") and !std.mem.eql(u8, std.mem.span(mode), "write")) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const model = if (std.c.getenv("GRAFF_OPENAI_CACHE_RETENTION_MODEL")) |m| std.mem.span(m) else default_model;
    const stamp = if (std.c.getenv("GRAFF_OPENAI_CACHE_RETENTION_STAMP")) |s| std.mem.span(s) else "local";
    const path = if (std.c.getenv("GRAFF_OPENAI_CACHE_RETENTION_STATE")) |s| std.mem.span(s) else default_state;
    var root: std.json.ObjectMap = .empty;
    try root.put(a, "model", .{ .string = model });
    try root.put(a, "prompt_cache_key", .{ .string = pinned_key });
    try root.put(a, "api", .{ .string = "responses" });
    try root.put(a, "url", .{ .string = "https://api.openai.com/v1/responses" });
    try root.put(a, "status", .{ .string = "materialized" });
    var case_map: std.json.ObjectMap = .empty;
    for (cases) |c| {
        var nonce = nonceOf(c.name, stamp);
        const n = try a.dupe(u8, std.mem.sliceTo(&nonce, 0));
        const body = try buildProbeBody(a, model, c.ttl, n);
        const request = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always });
        var one: std.json.ObjectMap = .empty;
        try one.put(a, "nonce", .{ .string = n });
        try one.put(a, "ttl", .{ .string = c.ttl.label() });
        try one.put(a, "request", request);
        try case_map.put(a, c.name, .{ .object = one });
    }
    try root.put(a, "cases", .{ .object = case_map });
    const n12 = case_map.get("12h").?.object.get("nonce").?.string;
    const n30 = case_map.get("30m").?.object.get("nonce").?.string;
    if (std.mem.eql(u8, n12, n30)) return error.NonceCollision;
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.write(std.json.Value{ .object = root });
    const io = std.testing.io;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.writer.buffered() });
}

test "openai cache retention live" {
    const mode = std.c.getenv("GRAFF_OPENAI_CACHE_RETENTION") orelse return error.SkipZigTest;
    const span = std.mem.span(mode);
    if (!(std.mem.eql(u8, span, "write") or std.mem.eql(u8, span, "check"))) return error.SkipZigTest;
    if (std.c.getenv("OPENAI_API_KEY") == null) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const stamp = if (std.c.getenv("GRAFF_OPENAI_CACHE_RETENTION_STAMP")) |s| std.mem.span(s) else "live";
    var n12 = nonceOf("12h", stamp);
    var n30 = nonceOf("30m", stamp);
    const b12 = try buildProbeBody(a, default_model, .twelve_h, std.mem.sliceTo(&n12, 0));
    const b30 = try buildProbeBody(a, default_model, .thirty_m, std.mem.sliceTo(&n30, 0));
    try std.testing.expect(hasBreakpointTtl(b12, "12h"));
    try std.testing.expect(!hasBreakpointTtl(b30, "12h"));
}
