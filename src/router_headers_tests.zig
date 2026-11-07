//! Router-gateway headers (Vercel AI Gateway, OpenRouter), moved off
//! http_headers.zig for the 600-line cap: app attribution and Vercel's
//! session affinity.

const std = @import("std");
const http_headers = @import("http_headers.zig");
const Provider = @import("provider.zig").Provider;

test "Vercel chat sends app attribution and no grok conv headers" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "vercel", .kind = .openai, .auth = .bearer, .url = "https://ai-gateway.vercel.sh/coding-agent/v1/chat/completions", .api_key = "k", .model = "alibaba/qwen3.8-27b", .context = 1_000_000 };
    const headers = http_headers.providerHeaders(io, p, "Bearer k", &buf);
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

test "Vercel chat pins session affinity to the request cache key" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "vercel", .kind = .openai, .auth = .bearer, .url = "https://ai-gateway.vercel.sh/coding-agent/v1/chat/completions", .api_key = "k", .model = "moonshotai/kimi-k3.1-pro", .context = 1_000_000 };
    var kbuf: [96]u8 = undefined;
    var dummy: u8 = 0;
    const key = http_headers.requestCacheKey(io, "main", &dummy, p, &kbuf);
    var affinity: ?[]const u8 = null;
    for (http_headers.providerHeadersWithConv(io, p, "Bearer k", &buf, key)) |h| {
        if (std.mem.eql(u8, h.name, "x-session-affinity")) affinity = h.value;
    }
    try std.testing.expectEqualStrings(key, affinity.?);
    // One-off posts (title, compact) fall back to the durable project id.
    var buf2: [12]std.http.Header = undefined;
    affinity = null;
    for (http_headers.providerHeaders(io, p, "Bearer k", &buf2)) |h| {
        if (std.mem.eql(u8, h.name, "x-session-affinity")) affinity = h.value;
    }
    try std.testing.expectEqualStrings(http_headers.projectRootId(io), affinity.?);
    // Other providers do not get the header.
    var buf3: [12]std.http.Header = undefined;
    const z: Provider = .{ .id = "zai", .kind = .openai, .auth = .bearer, .url = "https://api.z.ai/api/paas/v4/chat/completions", .api_key = "k", .model = "glm-5.3", .context = 1_000_000 };
    for (http_headers.providerHeadersWithConv(io, z, "Bearer k", &buf3, key)) |h| try std.testing.expect(!std.mem.eql(u8, h.name, "x-session-affinity"));
}

test "OpenRouter chat sends app attribution and no grok conv headers" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "openrouter", .kind = .openai, .auth = .bearer, .url = "https://openrouter.ai/api/v1/chat/completions", .api_key = "k", .model = "anthropic/claude-sonnet-4.6", .context = 1_000_000 };
    const headers = http_headers.providerHeaders(io, p, "Bearer k", &buf);
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
