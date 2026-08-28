//! Provider-specific HTTP identity and authorization headers.

const std = @import("std");
const Io = std.Io;
const Provider = @import("provider.zig").Provider;
const root = @import("main.zig");
const kimi_catalog = @import("kimi_catalog.zig");
const cache_affinity = @import("cache_affinity.zig");

var session_id_buf: [36]u8 = undefined;
var session_id_len: usize = 0;
/// Spin-lock, not an Io.Mutex: providerHeaders has no Io handle to reach one
/// with, and the critical section is a single one-time 36-byte format.
var session_id_lock: std.atomic.Value(bool) = .init(false);

/// A UUIDv4 minted once per process. Persisted on the graff session record.
/// Codex's HTTP `session_id` is the prompt-cache key (openai/codex ModelClient
/// defaults `prompt_cache_key` to `session_id`), not this value.
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

/// Conversation affinity for one request. xAI routes `x-grok-conv-id` (Chat
/// Completions) and `prompt_cache_key` (Responses) to the same server — cache
/// entries are per-server, so a sticky id is how prefix hits stay reliable
/// (docs.x.ai prompt-caching / maximizing-cache-hits). Root is the durable
/// project id. Children share four role lanes so sibling scouts with the
/// same system+tools land together; they do **not** reuse the root id
/// (different prefix). `agent` is unused: a pointer suffix would split
/// siblings onto different servers and miss on purpose.
pub fn promptCacheKey(io: Io, label: []const u8, agent: *const anyopaque, buf: []u8) []const u8 {
    _ = agent;
    return promptPrefixCacheKey(io, label, buf);
}

/// OpenAI/Codex cache affinity for requests sharing a stable prompt prefix.
/// Root keeps the durable project id. Children use four deterministic lanes:
/// enough sharing for repeated workflow roles, without pushing one key past
/// OpenAI's documented ~15 requests/minute cache-routing guidance during fanout.
pub fn promptPrefixCacheKey(io: Io, label: []const u8, buf: []u8) []const u8 {
    const base = projectRootId(io);
    if (std.mem.eql(u8, label, "main") or sharesParentCache(label)) return std.fmt.bufPrint(buf, "{s}", .{base}) catch base;
    const lane = std.hash.Wyhash.hash(0, label) & 3;
    return std.fmt.bufPrint(buf, "{s}-child-{d}", .{ base, lane }) catch base;
}

/// Partition for one request. Header (`x-grok-conv-id`) and body
/// (`prompt_cache_key`) must be the same value — xAI treats them as the
/// same sticky-routing id. Role lanes for every provider, including xAI.
pub fn requestCacheKey(io: Io, label: []const u8, agent: *const anyopaque, provider_id: []const u8, buf: []u8) []const u8 {
    _ = provider_id;
    return promptCacheKey(io, label, agent, buf);
}

/// Durable project partition (UUIDv5, no state to persist). Seed is the git
/// root when cwd is inside a repo, else `graff-scratch` — not the leaf cwd
/// (ADR 0011 / rematch 2026-08-28). Worktrees and sibling eval sandboxes
/// under one repo share the bucket so turn 1 can hit a warm system+tools
/// prefix. Different models do not share a cache (the server keys by model).
pub fn projectRootId(io: Io) []const u8 {
    return cache_affinity.rootId(io);
}

/// Side-calls that replay the parent history (`/btw`) share the root
/// partition. Workers use a role lane, not the root id. grok-build's recap
/// does the same as `/btw`: same `prompt_cache_key` as the parent.
pub fn sharesParentCache(label: []const u8) bool {
    return std.mem.eql(u8, label, "btw");
}

pub fn projectCacheKey(io: Io, label: []const u8, agent: *const anyopaque, buf: []u8) []const u8 {
    const base = projectRootId(io);
    if (std.mem.eql(u8, label, "main") or sharesParentCache(label)) {
        if (buf.len >= base.len) {
            @memcpy(buf[0..base.len], base);
            return buf[0..base.len];
        }
        return base;
    }
    return std.fmt.bufPrint(buf, "{s}-{x}", .{ base, @intFromPtr(agent) }) catch base;
}

/// /resume adopts the persisted Codex `session_id`. Prompt-cache routing
/// uses `projectRootId` and does not need this. No-op once minted.
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

/// xAI Chat Completions: `x-grok-conv-id` (Responses: `prompt_cache_key`).
/// Same value on both — xAI routes that id to one server so the prefix hits.
pub fn wantsGrokConvId(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "xai");
}

pub fn providerHeaders(io: Io, provider: Provider, bearer: []const u8, buf: *[12]std.http.Header) []const std.http.Header {
    return providerHeadersWithConv(io, provider, bearer, buf, null);
}

/// Same as `providerHeaders`, with an explicit conversation id for xAI.
/// Null falls back to `projectRootId` (one-off posts: title, compact).
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
    // SuperGrok user tokens need the grok-build routing header.
    if (std.mem.eql(u8, provider.id, "xai") and provider.source == .login) {
        buf[count] = .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" };
        count += 1;
    }
    if (provider.kind == .anthropic) {
        buf[count] = .{ .name = "anthropic-version", .value = root.anthropic_version };
        count += 1;
    }
    if (std.mem.eql(u8, provider.id, "kimi")) {
        const identity = kimi_catalog.identityHeaders(buf[count..]);
        count += identity.len;
    }
    // Z.AI docs default the response language this way; omit and some
    // accounts still answer, but the cache examples all send it.
    if (std.mem.eql(u8, provider.id, "zai")) {
        buf[count] = .{ .name = "Accept-Language", .value = "en-US,en" };
        count += 1;
    }
    // Optional app attribution: Vercel AI Gateway and OpenRouter rankings
    // (vercel.com/docs/ai-gateway/ecosystem/app-attribution, openrouter.ai/docs).
    if (std.mem.eql(u8, provider.id, "vercel") or std.mem.eql(u8, provider.id, "openrouter")) {
        buf[count] = .{ .name = "http-referer", .value = "https://codegraff.com" };
        count += 1;
        buf[count] = .{ .name = "x-title", .value = "graff" };
        count += 1;
    }
    // OpenRouter marketplace categories. Max 2 per request; only recognized
    // slugs count — unrecognized values are dropped server-side, silently.
    if (std.mem.eql(u8, provider.id, "openrouter")) {
        buf[count] = .{ .name = "x-openrouter-categories", .value = "cli-agent,programming-app" };
        count += 1;
    }
    // These identify the ChatGPT/Codex backend. The official Platform Responses
    // endpoint needs only normal bearer auth and rejects backend-only identity.
    if (std.mem.eql(u8, provider.id, "codex")) {
        buf[count] = .{ .name = "chatgpt-account-id", .value = provider.account };
        count += 1;
        buf[count] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
        count += 1;
        buf[count] = .{ .name = "originator", .value = "codex_cli_rs" };
        count += 1;
        // openai/codex ModelClient: prompt_cache_key defaults to session_id.
        buf[count] = .{ .name = "session_id", .value = conv_id orelse projectRootId(io) };
        count += 1;
    }
    if (wantsGrokConvId(provider.id)) {
        const root_id = projectRootId(io);
        buf[count] = .{ .name = "x-grok-conv-id", .value = conv_id orelse root_id };
        count += 1;
        // grok-build always sends session + conv. Session stays the durable
        // project id so a child partition still routes onto the same server
        // family; conv-id / prompt_cache_key isolate the prefix itself.
        buf[count] = .{ .name = "x-grok-session-id", .value = root_id };
        count += 1;
    }
    return buf[0..count];
}

test "session_id is a stable per-process UUIDv4, not a shared constant" {
    const io = std.testing.io;
    const a = sessionId(io);
    try std.testing.expectEqual(@as(usize, 36), a.len);
    // Codex session_id must not collapse to the old shared constant.
    try std.testing.expect(!std.mem.eql(u8, a, "00000000-0000-0000-0000-000000000001"));
    for ([_]usize{ 8, 13, 18, 23 }) |i| try std.testing.expectEqual(@as(u8, '-'), a[i]);
    try std.testing.expectEqual(@as(u8, '4'), a[14]); // version nibble
    try std.testing.expect(a[19] == '8' or a[19] == '9' or a[19] == 'a' or a[19] == 'b'); // variant
    for (a, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    try std.testing.expectEqualStrings(a, sessionId(io));

    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6", .context = 272_000, .account = "acct" };
    const headers = providerHeaders(io, p, "Bearer k", &buf);
    try std.testing.expectEqualStrings(projectRootId(io), headerValue(headers, "session_id") orelse return error.SessionIdHeaderMissing);
    try std.testing.expect(!std.mem.eql(u8, a, headerValue(headers, "session_id").?));
}

test "official OpenAI Responses uses Platform headers, not ChatGPT backend identity" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "https://api.openai.com/v1/responses", .api_key = "k", .model = "gpt-5.6", .context = 272_000 };
    const headers = providerHeaders(io, p, "Bearer k", &buf);
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("authorization", headers[0].name);
    try std.testing.expectEqualStrings("Bearer k", headers[0].value);
}

test "Z.AI chat sends Accept-Language and no grok conv headers" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "zai", .kind = .openai, .auth = .bearer, .url = "https://api.z.ai/api/paas/v4/chat/completions", .api_key = "k", .model = "glm-5.3", .context = 1_000_000 };
    const headers = providerHeaders(io, p, "Bearer k", &buf);
    var saw_lang = false;
    for (headers) |h| {
        try std.testing.expect(!std.mem.eql(u8, h.name, "x-grok-conv-id"));
        if (std.mem.eql(u8, h.name, "Accept-Language")) {
            saw_lang = true;
            try std.testing.expectEqualStrings("en-US,en", h.value);
        }
    }
    try std.testing.expect(saw_lang);
}

test "Vercel chat sends app attribution and no grok conv headers" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "vercel", .kind = .openai, .auth = .bearer, .url = "https://ai-gateway.vercel.sh/coding-agent/v1/chat/completions", .api_key = "k", .model = "alibaba/qwen3.8-27b", .context = 1_000_000 };
    const headers = providerHeaders(io, p, "Bearer k", &buf);
    var saw_ref = false;
    var saw_title = false;
    for (headers) |h| {
        try std.testing.expect(!std.mem.eql(u8, h.name, "x-grok-conv-id"));
        if (std.mem.eql(u8, h.name, "http-referer")) {
            saw_ref = true;
            try std.testing.expectEqualStrings("https://codegraff.com", h.value);
        }
        if (std.mem.eql(u8, h.name, "x-title")) {
            saw_title = true;
            try std.testing.expectEqualStrings("graff", h.value);
        }
    }
    try std.testing.expect(saw_ref);
    try std.testing.expect(saw_title);
}

test "OpenRouter chat sends app attribution and no grok conv headers" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "openrouter", .kind = .openai, .auth = .bearer, .url = "https://openrouter.ai/api/v1/chat/completions", .api_key = "k", .model = "anthropic/claude-sonnet-4.6", .context = 1_000_000 };
    const headers = providerHeaders(io, p, "Bearer k", &buf);
    var saw_ref = false;
    var saw_title = false;
    var saw_categories = false;
    for (headers) |h| {
        try std.testing.expect(!std.mem.eql(u8, h.name, "x-grok-conv-id"));
        if (std.mem.eql(u8, h.name, "http-referer")) {
            saw_ref = true;
            try std.testing.expectEqualStrings("https://codegraff.com", h.value);
        }
        if (std.mem.eql(u8, h.name, "x-title")) {
            saw_title = true;
            try std.testing.expectEqualStrings("graff", h.value);
        }
        if (std.mem.eql(u8, h.name, "x-openrouter-categories")) {
            saw_categories = true;
            try std.testing.expectEqualStrings("cli-agent,programming-app", h.value);
        }
    }
    try std.testing.expect(saw_ref);
    try std.testing.expect(saw_title);
    try std.testing.expect(saw_categories);
}

test "project and prefix cache keys preserve conversation and sharing boundaries" {
    var fake: usize = 0;
    var sibling_fake: usize = 1;
    const agent: *const anyopaque = @ptrCast(&fake);
    const sibling: *const anyopaque = @ptrCast(&sibling_fake);
    var buf: [96]u8 = undefined;
    const a = projectCacheKey(std.testing.io, "main", agent, &buf);
    try std.testing.expectEqual(@as(usize, 36), a.len);
    try std.testing.expectEqual(@as(u8, '5'), a[14]); // version nibble: name-derived
    var buf2: [96]u8 = undefined;
    const b = projectCacheKey(std.testing.io, "main", agent, &buf2);
    try std.testing.expectEqualStrings(a, b); // durable: no per-process randomness
    try std.testing.expectEqualStrings(a, projectRootId(std.testing.io));
    try std.testing.expect(!std.mem.eql(u8, a, sessionId(std.testing.io)));

    // Live keys (promptCacheKey) share a role lane — xAI cache is per-server
    // and prefix-matched; a unique suffix per sibling is a forced miss.
    var buf3: [96]u8 = undefined;
    var buf4: [96]u8 = undefined;
    const sub = promptCacheKey(std.testing.io, "sub", agent, &buf3);
    const sibling_sub = promptCacheKey(std.testing.io, "sub", sibling, &buf4);
    try std.testing.expectEqualStrings(sub, sibling_sub);
    try std.testing.expect(!std.mem.eql(u8, sub, a));

    var btw_buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(a, projectCacheKey(std.testing.io, "btw", sibling, &btw_buf));

    // OpenAI/Codex prefix affinity is stable for a workflow role, but spreads
    // different roles over four lanes to stay below the per-key traffic guide.
    var pbuf1: [96]u8 = undefined;
    var pbuf2: [96]u8 = undefined;
    const prefix1 = promptPrefixCacheKey(std.testing.io, "implement", &pbuf1);
    const prefix2 = promptPrefixCacheKey(std.testing.io, "implement", &pbuf2);
    try std.testing.expectEqualStrings(prefix1, prefix2);
    try std.testing.expect(std.mem.startsWith(u8, prefix1, a));
    try std.testing.expect(!std.mem.eql(u8, prefix1, a));

    // OpenAI and xAI scouts share a role lane (header and body use this).
    var oai1: [96]u8 = undefined;
    var oai2: [96]u8 = undefined;
    const oai_lane = requestCacheKey(std.testing.io, "implement", agent, "openai", &oai1);
    try std.testing.expectEqualStrings(oai_lane, requestCacheKey(std.testing.io, "implement", sibling, "openai", &oai2));
    var xai1: [96]u8 = undefined;
    var xai2: [96]u8 = undefined;
    const xai_lane = requestCacheKey(std.testing.io, "implement", agent, "xai", &xai1);
    try std.testing.expectEqualStrings(xai_lane, requestCacheKey(std.testing.io, "implement", sibling, "xai", &xai2));
    try std.testing.expectEqualStrings(oai_lane, xai_lane);

    // rlm's subagent("task") defaults description to "subagent" — siblings
    // share one prefix lane on every provider, including xAI.
    var rlm1: [96]u8 = undefined;
    var rlm2: [96]u8 = undefined;
    const rlm_lane = requestCacheKey(std.testing.io, "subagent", agent, "xai", &rlm1);
    try std.testing.expectEqualStrings(rlm_lane, requestCacheKey(std.testing.io, "subagent", sibling, "xai", &rlm2));
    try std.testing.expect(std.mem.indexOf(u8, rlm_lane, "-child-") != null);
}

test "x-grok-conv-id with no explicit conv still uses the project root id" {
    const io = std.testing.io;
    const xai: Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 500_000 };
    var buf: [12]std.http.Header = undefined;
    const headers = providerHeadersWithConv(io, xai, "Bearer k", &buf, null);
    try std.testing.expectEqualStrings(projectRootId(io), headerValue(headers, "x-grok-conv-id") orelse return error.MissingGrokConvId);
    try std.testing.expectEqualStrings(projectRootId(io), headerValue(headers, "x-grok-session-id") orelse return error.MissingGrokSessionId);
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

    const xai: Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 500_000 };
    var buf: [12]std.http.Header = undefined;
    const first = providerHeadersWithConv(io, xai, "Bearer k", &buf, root_id);
    try std.testing.expectEqualStrings(root_id, headerValue(first, "x-grok-conv-id") orelse return error.MissingGrokConvId);
    try std.testing.expectEqualStrings(root_id, headerValue(first, "x-grok-session-id") orelse return error.MissingGrokSessionId);
    var buf2: [12]std.http.Header = undefined;
    const second = providerHeadersWithConv(io, xai, "Bearer k", &buf2, root_id);
    try std.testing.expectEqualStrings(root_id, headerValue(second, "x-grok-conv-id").?);
    try std.testing.expectEqualStrings(root_id, headerValue(second, "x-grok-session-id").?);
    var buf3: [12]std.http.Header = undefined;
    const child_headers = providerHeadersWithConv(io, xai, "Bearer k", &buf3, child_id);
    try std.testing.expectEqualStrings(child_id, headerValue(child_headers, "x-grok-conv-id").?);
    try std.testing.expectEqualStrings(root_id, headerValue(child_headers, "x-grok-session-id").?);

    const anth: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude", .context = 200_000 };
    var abuf: [12]std.http.Header = undefined;
    const ah = providerHeadersWithConv(io, anth, "", &abuf, root_id);
    try std.testing.expect(headerValue(ah, "x-grok-conv-id") == null);
    try std.testing.expect(headerValue(ah, "x-grok-session-id") == null);
}

test "xai login tokens send X-XAI-Token-Auth; API keys do not" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const login: Provider = .{
        .id = "xai",
        .kind = .openai,
        .auth = .bearer,
        .url = "",
        .api_key = "oauth-tok",
        .model = "grok-4.3",
        .context = 256_000,
        .source = .login,
    };
    const login_headers = providerHeaders(io, login, "Bearer oauth-tok", &buf);
    var saw_token_auth = false;
    for (login_headers) |h| {
        if (std.mem.eql(u8, h.name, "X-XAI-Token-Auth")) {
            try std.testing.expectEqualStrings("xai-grok-cli", h.value);
            saw_token_auth = true;
        }
    }
    try std.testing.expect(saw_token_auth);

    const env_key: Provider = .{
        .id = "xai",
        .kind = .openai,
        .auth = .bearer,
        .url = "",
        .api_key = "xai-api-key",
        .model = "grok-4.3",
        .context = 256_000,
        .source = .environment,
    };
    const env_headers = providerHeaders(io, env_key, "Bearer xai-api-key", &buf);
    for (env_headers) |h| {
        try std.testing.expect(!std.mem.eql(u8, h.name, "X-XAI-Token-Auth"));
    }
}

test "Kimi chat sends graff identity and kimi-code device headers (#617)" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "k3", .context = 256_000 };
    const headers = providerHeaders(io, p, "Bearer k", &buf);
    try std.testing.expectEqualStrings("kimi_code_cli", headerValue(headers, "X-Msh-Platform").?);
    try std.testing.expect(headerValue(headers, "X-Msh-Device-Name").?.len > 0);
    try std.testing.expect(!std.mem.eql(u8, headerValue(headers, "X-Msh-Device-Name").?, "unknown"));
    const model = headerValue(headers, "X-Msh-Device-Model").?;
    const prefix = switch (@import("builtin").os.tag) {
        .windows => "Windows ",
        .macos => "macOS ",
        .linux => "Linux ",
        else => "",
    };
    if (prefix.len != 0) try std.testing.expect(std.mem.startsWith(u8, model, prefix));
    try std.testing.expect(!std.mem.eql(u8, headerValue(headers, "X-Msh-Os-Version").?, @tagName(@import("builtin").os.tag)));
}
