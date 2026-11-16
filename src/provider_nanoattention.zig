//! Built-in native Flint endpoint validation and URL resolution.
const std = @import("std");

pub const default_chat_url = "http://127.0.0.1:8080/v1/chat/completions";
pub const default_models_url = "http://127.0.0.1:8080/v1/models";
const chat_suffix = "/v1/chat/completions";
var models_url_buf: [512]u8 = undefined;
pub var url_override: ?[]const u8 = null;

pub fn validEndpoint(url: []const u8) bool {
    if (url.len == 0 or url.len > 512 or std.mem.indexOfAny(u8, url, "?#\\") != null) return false;
    for (url) |c| if (std.ascii.isWhitespace(c) or c < 0x20 or c == 0x7f) return false;
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.port == null or uri.port.? == 0) return false;
    const host_component = uri.host orelse return false;
    const host = switch (host_component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    if (!(std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1"))) return false;
    const authority_start = (std.mem.indexOf(u8, url, "://") orelse return false) + 3;
    const authority_end = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse url.len;
    if (std.mem.indexOfScalar(u8, url[authority_start..authority_end], '@') != null) return false;
    return std.mem.endsWith(u8, url, chat_suffix);
}

pub fn configureUrl(url: []const u8) bool {
    if (!validEndpoint(url)) return false;
    url_override = url;
    return true;
}

pub fn chatUrl(default: []const u8) []const u8 {
    return url_override orelse default;
}

pub fn modelsUrl(default: []const u8) []const u8 {
    const url = url_override orelse return default;
    if (!validEndpoint(url)) return default;
    const origin_end = url.len - chat_suffix.len;
    return std.fmt.bufPrint(&models_url_buf, "{s}/v1/models", .{url[0..origin_end]}) catch default;
}

test "native Flint endpoint is loopback-only and has a valid port and chat path" {
    try std.testing.expect(validEndpoint("http://127.0.0.1:8080/v1/chat/completions"));
    try std.testing.expect(validEndpoint("http://localhost:43123/v1/chat/completions"));
    try std.testing.expect(validEndpoint("http://[::1]:43123/v1/chat/completions"));
    try std.testing.expect(!validEndpoint("https://127.0.0.1:8080/v1/chat/completions"));
    try std.testing.expect(!validEndpoint("http://example.com:8080/v1/chat/completions"));
    try std.testing.expect(!validEndpoint("http://127.0.0.1:0/v1/chat/completions"));
    try std.testing.expect(!validEndpoint("http://127.0.0.1:8080/v1/models"));
    try std.testing.expect(!validEndpoint("http://user@127.0.0.1:8080/v1/chat/completions"));
    try std.testing.expect(!validEndpoint("http://127.0.0.1:8080/v1/chat/completions?redirect=https://example.com"));
}

test "native Flint models URL follows the resolved local endpoint" {
    const old = url_override;
    defer url_override = old;
    url_override = "http://localhost:43123/v1/chat/completions";
    try std.testing.expectEqualStrings("http://localhost:43123/v1/models", modelsUrl(default_models_url));
}
