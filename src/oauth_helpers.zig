//! Codex callback parsing and common browser helpers used by OAuth login flows.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const credential_store = @import("credential_store.zig");

pub fn b64url(arena: Allocator, bytes: []const u8) []const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = arena.alloc(u8, enc.calcSize(bytes.len)) catch return "";
    return enc.encode(buf, bytes);
}

/// Pull chatgpt_account_id out of an id_token's claims (base64url middle segment).
pub fn accountFromIdToken(arena: Allocator, id_token: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, id_token, '.');
    _ = it.next();
    const payload = it.next() orelse return "";
    const dec = std.base64.url_safe_no_pad.Decoder;
    const n = dec.calcSizeForSlice(payload) catch return "";
    const buf = arena.alloc(u8, n) catch return "";
    dec.decode(buf, payload) catch return "";
    const v = std.json.parseFromSliceLeaky(Value, arena, buf, .{ .allocate = .alloc_always }) catch return "";
    if (v != .object) return "";
    const auth = v.object.get("https://api.openai.com/auth") orelse return "";
    if (auth != .object) return "";
    const account = auth.object.get("chatgpt_account_id") orelse return "";
    return if (account == .string) account.string else "";
}

pub fn writeCodexAuth(io: Io, arena: Allocator, home: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/.codex/auth.json", .{home});
    var tokens: std.json.ObjectMap = .empty;
    try tokens.put(arena, "id_token", .{ .string = id_token });
    try tokens.put(arena, "access_token", .{ .string = access });
    try tokens.put(arena, "refresh_token", .{ .string = refresh });
    try tokens.put(arena, "account_id", .{ .string = account });
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "auth_mode", .{ .string = "chatgpt" });
    try object.put(arena, "tokens", .{ .object = tokens });
    try object.put(arena, "last_refresh", .{ .string = "harness-login" });
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(Value{ .object = object });
    try credential_store.replaceFile(io, Io.Dir.cwd(), path, aw.writer.buffered(), .default_file);
}

/// The page the Codex OAuth callback tab lands on after a successful login.
/// A branded, dark-mode-aware confirmation card; the local server writes this
/// back, then reads the ?code out of the same request for the token exchange.
pub const codex_login_page_html =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>graff — logged in</title>
    \\<style>
    \\:root{color-scheme:light dark}
    \\html,body{height:100%;margin:0}
    \\body{display:flex;align-items:center;justify-content:center;
    \\font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    \\background:#fafafa;color:#18181b}
    \\.card{text-align:center;padding:2.5rem 3rem;border-radius:16px;background:#fff;
    \\border:1px solid #e4e4e7;box-shadow:0 8px 30px rgba(0,0,0,.06);max-width:22rem}
    \\.mark{font-size:1.25rem;font-weight:700;letter-spacing:-.02em}
    \\.mark b{color:#6d28d9}
    \\h1{font-size:1.35rem;margin:1rem 0 .5rem;font-weight:650}
    \\.check{color:#16a34a}
    \\p{margin:0;color:#52525b;line-height:1.55}
    \\@media(prefers-color-scheme:dark){
    \\body{background:#09090b;color:#fafafa}
    \\.card{background:#18181b;border-color:#27272a;box-shadow:0 8px 30px rgba(0,0,0,.4)}
    \\p{color:#a1a1aa}.mark b{color:#a78bfa}}
    \\</style></head>
    \\<body><div class="card">
    \\<div class="mark">graff <b>◆</b></div>
    \\<h1>You're all set <span class="check">✓</span></h1>
    \\<p>Codex is connected. You can close this tab and return to graff.</p>
    \\</div></body></html>
;

/// Extract a query-string parameter from an HTTP request line ("GET /p?k=v…").
pub fn queryParam(req_line: []const u8, key: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, req_line, '?') orelse return null;
    const request_end = std.mem.indexOfScalarPos(u8, req_line, query_start, ' ') orelse req_line.len;
    var pairs = std.mem.tokenizeScalar(u8, req_line[query_start + 1 .. request_end], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], key)) return pair[equals + 1 ..];
    }
    return null;
}

pub fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "open", url }
    else
        &.{ "xdg-open", url };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}
