//! Provider-specific HTTP identity and authorization headers.

const std = @import("std");
const Io = std.Io;
const Provider = @import("provider.zig").Provider;
const root = @import("main.zig");
const kimi_catalog = @import("kimi_catalog.zig");

var session_id_buf: [36]u8 = undefined;
var session_id_len: usize = 0;
/// Spin-lock, not an Io.Mutex: providerHeaders has no Io handle to reach one
/// with, and the critical section is a single one-time 36-byte format.
var session_id_lock: std.atomic.Value(bool) = .init(false);

/// A UUIDv4 minted once per process, matching what openai/codex generates per
/// session. It rides two places: the `session_id` header and `prompt_cache_key`
/// on the Responses body, which is what the backend partitions its prompt cache
/// on. This was a single hardcoded constant shared by every graff user on every
/// machine, which is the worst case for that partition: one key carrying all
/// traffic overflows and DEGRADES hit rate, so the full histories we resend
/// each turn had no affinity to land on.
pub fn sessionId(io: Io) []const u8 {
    while (session_id_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer session_id_lock.store(false, .release);
    if (session_id_len == 0) {
        var raw: [16]u8 = undefined;
        io.random(&raw);
        raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
        raw[8] = (raw[8] & 0x3f) | 0x80; // variant 1
        const hex = std.fmt.bytesToHex(raw, .lower);
        @memcpy(session_id_buf[0..8], hex[0..8]);
        session_id_buf[8] = '-';
        @memcpy(session_id_buf[9..13], hex[8..12]);
        session_id_buf[13] = '-';
        @memcpy(session_id_buf[14..18], hex[12..16]);
        session_id_buf[18] = '-';
        @memcpy(session_id_buf[19..23], hex[16..20]);
        session_id_buf[23] = '-';
        @memcpy(session_id_buf[24..36], hex[20..32]);
        session_id_len = 36;
    }
    return session_id_buf[0..session_id_len];
}

/// The cache-affinity partition for one agent. opencode keys per session for
/// the same reason: every agent in the process used to share the session id,
/// so interleaved root/sub requests — different prefixes under one key —
/// evicted each other (root cache_read measured ~35% in benchmarks). Root
/// ("main") keeps the bare session id; every other agent gets a unique suffix.
pub fn promptCacheKey(io: Io, label: []const u8, agent: *const anyopaque, buf: []u8) []const u8 {
    const base = sessionId(io);
    if (std.mem.eql(u8, label, "main")) return base;
    return std.fmt.bufPrint(buf, "{s}-{x}", .{ base, @intFromPtr(agent) }) catch base;
}

/// Kimi-only: a DURABLE per-project cache partition, derived from the cwd
/// (UUIDv5-style, no state to persist). The kimi backend keys its prompt
/// cache on prompt_cache_key, and a per-process random key made every new
/// session's first call a cold partition — measured cache_read=0 on every
/// first call in the k3 benchmark, where kimi-cli's fresh sessions hit ~19k.
/// A per-project key lets the first call of a new session land on the warm
/// shared system-prompt prefix (~2-4s). Same-project sessions share the
/// partition: conversation tails evict each other, the expensive prefix still
/// hits. Subagents keep a per-agent suffix (the eviction reasoning above).
pub fn projectCacheKey(io: Io, label: []const u8, agent: *const anyopaque, buf: []u8) []const u8 {
    var raw: [16]u8 = undefined;
    {
        var cwd_buf: [4096]u8 = undefined;
        const n = Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch blk: {
            @memcpy(cwd_buf[0..1], ".");
            break :blk 1;
        };
        const cwd = cwd_buf[0..n];
        var digest: [32]u8 = undefined;
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("graff-kimi-project-cache-v1");
        h.update(cwd);
        h.final(&digest);
        @memcpy(&raw, digest[0..16]);
        raw[6] = (raw[6] & 0x0f) | 0x50; // version 5: name-derived
        raw[8] = (raw[8] & 0x3f) | 0x80; // variant 1
    }
    const hex = std.fmt.bytesToHex(raw, .lower);
    const base = std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    if (std.mem.eql(u8, label, "main")) return base;
    const suffix = std.fmt.bufPrint(buf[base.len..], "-{x}", .{@intFromPtr(agent)}) catch return base;
    return buf[0 .. base.len + suffix.len];
}

/// /resume adopts the persisted key so k3/codex prompt-cache affinity survives
/// the process boundary — both upstreams key the cache on the durable
/// conversation id (kimi-code's sessionContext.sessionId; codex's ModelClient
/// default), not a per-process UUID. No-op once this process has minted its own.
pub fn adoptSessionId(id: []const u8) void {
    if (id.len != 36) return;
    while (session_id_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer session_id_lock.store(false, .release);
    if (session_id_len != 0) return;
    @memcpy(session_id_buf[0..36], id[0..36]);
    session_id_len = 36;
}

pub fn userAgent(provider: Provider) std.http.Client.Request.Headers.Value {
    if (std.mem.eql(u8, provider.id, "kimi")) {
        return .{ .override = root.kimi_user_agent };
    }
    return .default;
}

/// xAI Chat Completions + Responses: the official cache-routing header.
/// `promptCacheKey` is the same sticky id used as Responses `prompt_cache_key`.
pub fn wantsGrokConvId(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "xai");
}

pub fn providerHeaders(io: Io, provider: Provider, bearer: []const u8, buf: *[12]std.http.Header) []const std.http.Header {
    return providerHeadersWithConv(io, provider, bearer, buf, null);
}

/// Same as `providerHeaders`, with an explicit conversation id for xAI.
/// Null falls back to the process session id (one-off posts: title, compact).
pub fn providerHeadersWithConv(io: Io, provider: Provider, bearer: []const u8, buf: *[12]std.http.Header, conv_id: ?[]const u8) []const std.http.Header {
    var count: usize = 0;
    switch (provider.auth) {
        .x_api_key => {
            buf[count] = .{ .name = "x-api-key", .value = provider.api_key };
            count += 1;
        },
        .bearer => {
            buf[count] = .{ .name = "authorization", .value = bearer };
            count += 1;
        },
    }
    if (provider.kind == .anthropic) {
        buf[count] = .{ .name = "anthropic-version", .value = root.anthropic_version };
        count += 1;
    }
    if (std.mem.eql(u8, provider.id, "kimi")) {
        const identity = kimi_catalog.identityHeaders(buf[count..]);
        count += identity.len;
    }
    // The ChatGPT-backend identity headers are codex-only: another Responses
    // provider (xAI, #502) authenticates with the bearer alone and must not
    // impersonate codex_cli_rs.
    if (provider.kind == .responses and std.mem.eql(u8, provider.id, "codex")) {
        buf[count] = .{ .name = "chatgpt-account-id", .value = provider.account };
        count += 1;
        buf[count] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
        count += 1;
        buf[count] = .{ .name = "originator", .value = "codex_cli_rs" };
        count += 1;
        buf[count] = .{ .name = "session_id", .value = sessionId(io) };
        count += 1;
    }
    if (wantsGrokConvId(provider.id)) {
        buf[count] = .{ .name = "x-grok-conv-id", .value = conv_id orelse sessionId(io) };
        count += 1;
    }
    return buf[0..count];
}

test "session_id is a stable per-process UUIDv4, not a shared constant" {
    const io = std.testing.io;
    const a = sessionId(io);
    try std.testing.expectEqual(@as(usize, 36), a.len);
    // The value the backend partitions its prompt cache on used to be this
    // constant, identical for every session and every graff user.
    try std.testing.expect(!std.mem.eql(u8, a, "00000000-0000-0000-0000-000000000001"));
    for ([_]usize{ 8, 13, 18, 23 }) |i| try std.testing.expectEqual(@as(u8, '-'), a[i]);
    try std.testing.expectEqual(@as(u8, '4'), a[14]); // version nibble
    try std.testing.expect(a[19] == '8' or a[19] == '9' or a[19] == 'a' or a[19] == 'b'); // variant
    for (a, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // Stable within the process: the header and prompt_cache_key must agree,
    // and the key must not move turn to turn or it partitions nothing.
    try std.testing.expectEqualStrings(a, sessionId(io));

    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6", .context = 272_000, .account = "acct" };
    const headers = providerHeaders(io, p, "Bearer k", &buf);
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "session_id")) {
            try std.testing.expectEqualStrings(a, h.value);
            return;
        }
    }
    return error.SessionIdHeaderMissing;
}

test "projectCacheKey is a durable per-project v5 UUID, stable across calls" {
    var fake: usize = 0;
    const agent: *const anyopaque = @ptrCast(&fake);
    var buf: [96]u8 = undefined;
    const a = projectCacheKey(std.testing.io, "main", agent, &buf);
    try std.testing.expectEqual(@as(usize, 36), a.len);
    try std.testing.expectEqual(@as(u8, '5'), a[14]); // version nibble: name-derived
    var buf2: [96]u8 = undefined;
    const b = projectCacheKey(std.testing.io, "main", agent, &buf2);
    try std.testing.expectEqualStrings(a, b); // durable: no per-process randomness
    // Subagents get a per-agent suffix off the same partition (eviction rule).
    var buf3: [96]u8 = undefined;
    const sub = projectCacheKey(std.testing.io, "sub", agent, &buf3);
    try std.testing.expect(std.mem.startsWith(u8, sub, a));
}

test "adoptSessionId validates length and never overwrites a minted id" {
    const io = std.testing.io;
    const before = sessionId(io); // minted by whichever test ran first
    adoptSessionId("too-short");
    adoptSessionId("00000000-0000-4000-8000-000000000000");
    try std.testing.expectEqualStrings(before, sessionId(io));
}

fn headerValue(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.mem.eql(u8, h.name, name)) return h.value;
    return null;
}

test "xAI Chat Completions headers carry a stable per-conversation x-grok-conv-id" {
    const io = std.testing.io;
    var root_ptr: usize = 1;
    var child_ptr: usize = 2;
    const root_agent: *const anyopaque = @ptrCast(&root_ptr);
    const child_agent: *const anyopaque = @ptrCast(&child_ptr);
    var root_buf: [96]u8 = undefined;
    var child_buf: [96]u8 = undefined;
    const root_id = promptCacheKey(io, "main", root_agent, &root_buf);
    const again_buf = promptCacheKey(io, "main", root_agent, root_buf[0..]);
    _ = again_buf;
    var root_buf2: [96]u8 = undefined;
    try std.testing.expectEqualStrings(root_id, promptCacheKey(io, "main", root_agent, &root_buf2));
    const child_id = promptCacheKey(io, "sub", child_agent, &child_buf);
    try std.testing.expect(!std.mem.eql(u8, root_id, child_id));

    const xai: Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 256_000 };
    var buf: [12]std.http.Header = undefined;
    const first = providerHeadersWithConv(io, xai, "Bearer k", &buf, root_id);
    try std.testing.expectEqualStrings(root_id, headerValue(first, "x-grok-conv-id") orelse return error.MissingGrokConvId);
    var buf2: [12]std.http.Header = undefined;
    const second = providerHeadersWithConv(io, xai, "Bearer k", &buf2, root_id);
    try std.testing.expectEqualStrings(root_id, headerValue(second, "x-grok-conv-id").?);
    var buf3: [12]std.http.Header = undefined;
    const child_headers = providerHeadersWithConv(io, xai, "Bearer k", &buf3, child_id);
    try std.testing.expectEqualStrings(child_id, headerValue(child_headers, "x-grok-conv-id").?);

    const anth: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude", .context = 200_000 };
    var abuf: [12]std.http.Header = undefined;
    const ah = providerHeadersWithConv(io, anth, "", &abuf, root_id);
    try std.testing.expect(headerValue(ah, "x-grok-conv-id") == null);
}
