//! Catalog-wide prompt-cache ratchet: every baked provider's live body
//! writer must pin a cache partition (or Anthropic's prefix breakpoint)
//! from the first request. Root keys stay sticky; children isolate.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const provider_mod = @import("provider.zig");
const http_headers = @import("http_headers.zig");
const effort_route = @import("effort_route.zig");

fn textMessage(arena: std.mem.Allocator, role: []const u8, text: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "role", .{ .string = role });
    try obj.put(arena, "content", .{ .string = text });
    return .{ .object = obj };
}

fn agentFor(arena: std.mem.Allocator, spec: provider_mod.ProviderSpec, label: []const u8, kind: provider_mod.Provider.Kind) !Agent {
    var messages = std.json.Array.init(arena);
    try messages.append(try textMessage(arena, "user", "hello"));
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{
            .id = spec.id,
            .kind = kind,
            .auth = spec.auth,
            .url = spec.url,
            .api_key = "k",
            .model = spec.default_model,
            .context = 256_000,
        },
        .messages = messages,
        .sub = !std.mem.eql(u8, label, "main"),
        .label = label,
        .out = null,
        .sys_normal = "system",
    };
}

fn headerNamed(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.mem.eql(u8, h.name, name)) return h.value;
    return null;
}

fn cacheKeyIn(body: []const u8) ?[]const u8 {
    const needle = "\"prompt_cache_key\":\"";
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const from = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, body, from, '"') orelse return null;
    return body[from..end];
}

fn hasCacheControl(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null;
}

fn wantsKey(id: []const u8, kind: provider_mod.Provider.Kind) bool {
    // Google validates the payload strictly and rejects the entire request on
    // an unknown field, so it is the one openai-wire provider that cannot carry
    // a partition key ("Unknown name \"prompt_cache_key\""). It caches
    // implicitly instead. Every other openai/responses provider still must pin
    // one — this is a named exception, not a relaxed rule.
    if (std.mem.eql(u8, id, "google")) return false;
    return kind == .openai or kind == .responses;
}

fn wantsAnthropicPrefix(id: []const u8, kind: provider_mod.Provider.Kind) bool {
    if (kind != .anthropic) return false;
    return std.mem.eql(u8, id, "anthropic") or std.mem.eql(u8, id, "kimi");
}

test "prompt cache: every baked provider pins a key or Anthropic prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var n: usize = 0;
    for (provider_mod.provider_specs) |spec| {
        n += 1;
        var root = try agentFor(a, spec, "main", spec.kind);
        const first = try root.buildBody(null, false, true, true);
        defer std.testing.allocator.free(first);
        const second = try root.buildBody(null, false, true, true);
        defer std.testing.allocator.free(second);
        var child = try agentFor(a, spec, "sub", spec.kind);
        const kid = try child.buildBody(null, false, true, true);
        defer std.testing.allocator.free(kid);

        if (wantsKey(spec.id, spec.kind)) {
            const k1 = cacheKeyIn(first) orelse {
                std.debug.print("\n{s} ({s}): missing prompt_cache_key\n", .{ spec.id, @tagName(spec.kind) });
                return error.MissingPromptCacheKey;
            };
            const k2 = cacheKeyIn(second) orelse return error.MissingPromptCacheKey;
            const ck = cacheKeyIn(kid) orelse return error.MissingPromptCacheKey;
            if (!std.mem.eql(u8, k1, k2)) {
                std.debug.print("\n{s}: cache key not sticky\n", .{spec.id});
                return error.CacheKeyMoved;
            }
            if (std.mem.eql(u8, k1, ck)) {
                std.debug.print("\n{s}: child reused root cache key\n", .{spec.id});
                return error.ChildNotIsolated;
            }
            if (k1.len == 0) return error.EmptyCacheKey;
            var pkbuf: [96]u8 = undefined;
            const want = http_headers.promptCacheKey(root.io, root.label, &root, &pkbuf);
            if (!std.mem.eql(u8, k1, want)) {
                std.debug.print("\n{s}: cache key is not the project id\n", .{spec.id});
                return error.CacheKeyNotProject;
            }
        } else {
            if (cacheKeyIn(first) != null) {
                std.debug.print("\n{s}: unexpected prompt_cache_key on Anthropic wire\n", .{spec.id});
                return error.UnexpectedPromptCacheKey;
            }
            if (wantsAnthropicPrefix(spec.id, spec.kind) and !hasCacheControl(first)) {
                std.debug.print("\n{s}: missing cache_control prefix\n", .{spec.id});
                return error.MissingCacheControl;
            }
        }
    }
    try std.testing.expectEqual(provider_mod.provider_specs.len, n);
}

test "prompt cache: xAI Responses header and body agree; OpenAI Responses has a key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const spec = provider_mod.specFor("xai").?;
    var root = try agentFor(a, spec, "main", .responses);
    const body = try root.buildBody(null, false, true, true);
    defer std.testing.allocator.free(body);
    const key = cacheKeyIn(body) orelse return error.MissingPromptCacheKey;
    var hbuf: [12]std.http.Header = undefined;
    const hdrs = http_headers.providerHeadersWithConv(root.io, root.provider, "Bearer k", &hbuf, key);
    const hv = blk: {
        for (hdrs) |h| if (std.mem.eql(u8, h.name, "x-grok-conv-id")) break :blk h.value;
        return error.MissingGrokConvId;
    };
    try std.testing.expectEqualStrings(key, hv);

    const oai = provider_mod.specFor("openai").?;
    var oa = try agentFor(a, oai, "main", .responses);
    const ob = try oa.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ob);
    try std.testing.expect(cacheKeyIn(ob) != null);

    const cd = provider_mod.specFor("codex").?;
    var ca = try agentFor(a, cd, "main", .responses);
    const cb = try ca.buildBody(null, false, true, true);
    defer std.testing.allocator.free(cb);
    const body_key = cacheKeyIn(cb) orelse return error.MissingPromptCacheKey;
    var ckbuf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(http_headers.requestCacheKey(ca.io, ca.label, &ca, "codex", &ckbuf), body_key);
    var cbuf: [12]std.http.Header = undefined;
    const ch = http_headers.providerHeadersWithConv(ca.io, ca.provider, "Bearer k", &cbuf, body_key);
    try std.testing.expectEqualStrings(body_key, headerNamed(ch, "session_id") orelse return error.SessionIdHeaderMissing);
}

test "prompt cache: effort is never auto-flipped (prefix stays)" {
    try std.testing.expect(!effort_route.shouldRouteLookupLow(false, true, "what does runEval do?"));
    try std.testing.expect(!effort_route.shouldRouteLookupLow(true, true, "explain the permission gate?"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const spec = provider_mod.specFor("codegraff").?;
    var root = try agentFor(a, spec, "main", .openai);
    const b1 = try root.buildBody(null, false, true, true);
    defer std.testing.allocator.free(b1);
    const b2 = try root.buildBody(null, false, true, true);
    defer std.testing.allocator.free(b2);
    try std.testing.expect(std.mem.indexOf(u8, b1, "\"reasoning_effort\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b2, "\"reasoning_effort\":\"medium\"") != null);
    try std.testing.expectEqualStrings(cacheKeyIn(b1).?, cacheKeyIn(b2).?);
}
