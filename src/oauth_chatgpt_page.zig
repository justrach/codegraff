//! The page the ChatGPT sign-in's loopback callback answers with (ADR 0221):
//! codegraff.com's paper, ink, coral and cobalt, in light and dark, one
//! template with five states. The images are embedded, so the page makes no
//! network request while the authorization code is in the address bar, and
//! its script swaps that URL for /auth/done once it loads.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const State = enum { first, ok, noplan, denied, @"error" };

const template_gz = @embedFile("chatgpt_callback.gz");
const emblem = @embedFile("oauth_page/codegraff-emblem-96.webp");
const art = @embedFile("oauth_page/auth-handoff-760.webp");

fn dataUri(arena: Allocator, mime: []const u8, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try arena.alloc(u8, enc.calcSize(bytes.len));
    return std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ mime, enc.encode(buf, bytes) });
}

fn escapeHtml(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(arena, "&amp;"),
        '<' => try out.appendSlice(arena, "&lt;"),
        '>' => try out.appendSlice(arena, "&gt;"),
        '"' => try out.appendSlice(arena, "&quot;"),
        '\'' => try out.appendSlice(arena, "&#39;"),
        else => try out.append(arena, c),
    };
    return out.items;
}

/// The page body for one outcome. `account` is the signed-in email, shown in
/// the states that have one.
pub fn render(arena: Allocator, state: State, account: []const u8) ![]const u8 {
    var page: []const u8 = try @import("update_archive.zig").gunzip(arena, template_gz);
    page = try std.mem.replaceOwned(u8, arena, page, "{{state}}", @tagName(state));
    page = try std.mem.replaceOwned(u8, arena, page, "{{account}}", try escapeHtml(arena, account));
    page = try std.mem.replaceOwned(u8, arena, page, "{{emblem}}", try dataUri(arena, "image/webp", emblem));
    return std.mem.replaceOwned(u8, arena, page, "{{art}}", try dataUri(arena, "image/webp", art));
}

/// The whole HTTP response: not cached, no referrer, connection closed.
pub fn response(arena: Allocator, state: State, account: []const u8) ![]const u8 {
    const body = try render(arena, state, account);
    return std.fmt.allocPrint(arena, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
}

pub const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

test "ChatGPT callback page: every state renders complete, escaped and self-contained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]State{ .first, .ok, .noplan, .denied, .@"error" }) |state| {
        const page = try render(a, state, "you@example.com");
        const attr = try std.fmt.allocPrint(a, "data-state=\"{s}\"", .{@tagName(state)});
        try std.testing.expect(std.mem.indexOf(u8, page, attr) != null);
        try std.testing.expect(std.mem.indexOf(u8, page, "{{") == null);
        // No network fetch while the code is in the address bar.
        try std.testing.expect(std.mem.indexOf(u8, page, "src=\"http") == null);
        try std.testing.expect(std.mem.indexOf(u8, page, "data:image/webp;base64,") != null);
    }
    const hostile = try render(a, .ok, "<script>x</script>@example.com");
    try std.testing.expect(std.mem.indexOf(u8, hostile, "<script>x") == null);
    try std.testing.expect(std.mem.indexOf(u8, hostile, "&lt;script&gt;x") != null);
    const resp = try response(a, .first, "you@example.com");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Cache-Control: no-store\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Referrer-Policy: no-referrer\r\n") != null);
}
