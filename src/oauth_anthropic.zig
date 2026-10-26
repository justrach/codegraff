//! Native Anthropic browser PKCE. Only Graff's own .anthropic credential
//! record is read; Claude CLI and Pi files are never consulted.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const helpers = @import("oauth_helpers.zig");
const store = @import("credential_store.zig");
const util = @import("util.zig");
const callback = @import("oauth_callback.zig");

pub const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const authorize_endpoint = "https://claude.ai/oauth/authorize";
pub const token_endpoint = "https://platform.claude.com/v1/oauth/token";
pub const scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";
pub const provider_dir = ".anthropic";
const refresh_margin_s = 300;
var refresh_mutex: Io.Mutex = .init;

pub const Record = struct { access: []const u8, refresh: []const u8, expires_at: i64 };
pub const Callback = struct { code: []const u8 = "", state: []const u8 = "", err: []const u8 = "" };

pub fn recordPath(arena: Allocator, home: []const u8) []const u8 {
    return store.oauthPath(arena, home, provider_dir);
}

pub fn readRecord(io: Io, arena: Allocator, home: []const u8) ?Record {
    const data = Io.Dir.cwd().readFileAlloc(io, recordPath(arena, home), arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const access = util.strFieldObj(v.object, "access_token") orelse return null;
    if (access.len == 0) return null;
    return .{
        .access = access,
        .refresh = util.strFieldObj(v.object, "refresh_token") orelse "",
        .expires_at = util.intFieldObj(v.object, "expires_at", 0),
    };
}

fn encode(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~')
            try out.append(arena, c)
        else
            try out.appendSlice(arena, &.{ '%', hex[c >> 4], hex[c & 15] });
    }
    return out.items;
}

fn decode(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.BadCallback;
            try out.append(arena, try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16));
            i += 2;
        } else try out.append(arena, if (s[i] == '+') ' ' else s[i]);
    }
    return out.items;
}

pub fn authorizeUrl(arena: Allocator, redirect: []const u8, verifier: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return std.fmt.allocPrint(arena, "{s}?code=true&response_type=code&client_id={s}&redirect_uri={s}&scope={s}&code_challenge_method=S256&code_challenge={s}&state={s}", .{
        authorize_endpoint,             client_id,                   try encode(arena, redirect), try encode(arena, scopes),
        helpers.b64url(arena, &digest), try encode(arena, verifier),
    });
}

pub fn parseCallback(arena: Allocator, line: []const u8) !?Callback {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, parts.next() orelse return null, "GET")) return null;
    const target = parts.next() orelse return null;
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (!std.mem.eql(u8, target[0..q], "/callback")) return null;
    var result: Callback = .{};
    var seen: u8 = 0;
    var pairs = std.mem.splitScalar(u8, if (q < target.len) target[q + 1 ..] else "", '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const bit: u8 = if (std.mem.eql(u8, key, "code")) 1 else if (std.mem.eql(u8, key, "state")) 2 else if (std.mem.eql(u8, key, "error")) 4 else continue;
        if (seen & bit != 0) return error.BadCallback;
        seen |= bit;
        const value = try decode(arena, pair[eq + 1 ..]);
        switch (bit) {
            1 => result.code = value,
            2 => result.state = value,
            4 => result.err = value,
            else => unreachable,
        }
    }
    return result;
}

pub const CallbackPolicy = enum { stale, finish };

/// A wrong-state tab must not end a newer sign-in. Matching-state denial
/// belongs to this attempt and is terminal, just like a successful code.
pub fn callbackPolicy(cb: Callback, verifier: []const u8) CallbackPolicy {
    return if (verifier.len > 0 and std.mem.eql(u8, cb.state, verifier)) .finish else .stale;
}

pub fn validateCallback(cb: Callback, verifier: []const u8) !void {
    if (callbackPolicy(cb, verifier) == .stale) return error.OAuthStateMismatch;
    if (std.mem.eql(u8, cb.err, "access_denied")) return error.OAuthDenied;
    if (cb.err.len > 0) return error.OAuthRejected;
    if (cb.code.len == 0) return error.MissingOAuthCode;
}

fn json(arena: Allocator, value: anytype) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(value);
    return aw.writer.buffered();
}

fn post(io: Io, gpa: Allocator, arena: Allocator, endpoint: []const u8, body: []const u8, previous_refresh: []const u8) !Record {
    return postWithDeadline(io, gpa, arena, endpoint, body, previous_refresh, .fromSeconds(20));
}

fn delay(io: Io, duration: Io.Duration) void {
    io.sleep(duration, .awake) catch {};
}

fn fetchToken(client: *std.http.Client, endpoint: []const u8, body: []const u8, writer: *Io.Writer) !std.http.Status {
    // Use the request API: fetch's bodyErr().? panics on a cancelled body read.
    var req = try client.request(.POST, try std.Uri.parse(endpoint), .{
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    defer req.deinit();
    defer if (req.connection) |conn| {
        conn.closing = true;
    };
    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();
    var response = try req.receiveHead(&.{});
    // Neither redirects nor provider error bodies cross this boundary.
    if (response.head.status != .ok) return response.head.status;
    const gpa = client.allocator;
    const dbuf: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (dbuf.len != 0) gpa.free(dbuf);
    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, dbuf);
    _ = reader.streamRemaining(writer) catch |err| {
        if (err == error.WriteFailed) return error.ResponseTooLarge;
        return err;
    };
    return response.head.status;
}

/// Request-local deadline seam. Both workers are cancelled and joined before
/// their client/buffers are released, including on stalled headers or bodies.
/// Production code exchange and refresh both use the same 20-second bound.
pub fn postWithDeadline(io: Io, gpa: Allocator, arena: Allocator, endpoint: []const u8, body: []const u8, previous_refresh: []const u8, deadline: Io.Duration) !Record {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const buf = try arena.alloc(u8, 64 * 1024);
    var writer: Io.Writer = .fixed(buf);
    const Done = union(enum) { fetched: anyerror!std.http.Status, timeout: void };
    var done: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &done);
    select.concurrent(.timeout, delay, .{ io, deadline }) catch return error.DeadlineUnavailable;
    select.concurrent(.fetched, fetchToken, .{ &client, endpoint, body, &writer }) catch {
        select.cancelDiscard();
        return error.TransportUnavailable;
    };
    const first = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.cancelDiscard();
    const status = switch (first) {
        .fetched => |result| try result,
        .timeout => return error.DeadlineExceeded,
    };
    if (status != .ok) return error.OAuthTokenRejected;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, writer.buffered(), .{ .allocate = .alloc_always });
    if (v != .object or v.object.contains("error")) return error.BadOAuthResponse;
    const access = util.strFieldObj(v.object, "access_token") orelse return error.BadOAuthResponse;
    const refresh = util.strFieldObj(v.object, "refresh_token") orelse previous_refresh;
    const duration = util.intFieldObj(v.object, "expires_in", 0);
    if (access.len == 0 or refresh.len == 0 or duration <= 0) return error.BadOAuthResponse;
    const expires = std.math.add(i64, @divTrunc(util.unixMs(io), 1000), duration) catch return error.BadOAuthResponse;
    return .{ .access = access, .refresh = refresh, .expires_at = expires };
}

/// Endpoint seam for real loopback tests; production always supplies HTTPS.
pub fn exchangeCodeAt(io: Io, gpa: Allocator, arena: Allocator, endpoint: []const u8, redirect: []const u8, verifier: []const u8, cb: Callback) !Record {
    try validateCallback(cb, verifier);
    return post(io, gpa, arena, endpoint, try json(arena, .{
        .grant_type = "authorization_code",
        .code = cb.code,
        .state = cb.state,
        .client_id = client_id,
        .redirect_uri = redirect,
        .code_verifier = verifier,
    }), "");
}

fn save(io: Io, arena: Allocator, home: []const u8, r: Record) !void {
    try store.writeOAuth(io, arena, home, provider_dir, r.access, r.refresh, r.expires_at);
}

/// Preserve the shared warning channel: never print a token response.
pub fn persistRefreshed(io: Io, arena: Allocator, home: []const u8, r: Record) void {
    save(io, arena, home, r) catch save(io, arena, home, r) catch |err| {
        helpers.persist_error = @errorName(err);
    };
}

fn valid(r: Record, now: i64) ?[]const u8 {
    return if (r.expires_at > now) r.access else null;
}

fn lockRecord(io: Io, arena: Allocator, home: []const u8) !Io.File {
    const path = try std.fmt.allocPrint(arena, "{s}.lock", .{recordPath(arena, home)});
    return Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive, .permissions = store.private_file });
}

/// Serializes within the process AND across Graff processes. Re-read only
/// after acquiring the file lock so a rotated refresh token is never replayed.
pub fn loadAt(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, force: bool, stale: ?[]const u8, endpoint: []const u8) ?[]const u8 {
    refresh_mutex.lockUncancelable(io);
    defer refresh_mutex.unlock(io);
    const before = readRecord(io, arena, home) orelse return null;
    const now = @divTrunc(util.unixMs(io), 1000);
    const due = before.expires_at <= now + refresh_margin_s;
    if (helpers.supersededToken(force, before.access, stale) and !due) return valid(before, now);
    if (!force and !due) return valid(before, now);
    const lock = lockRecord(io, arena, home) catch return valid(before, now);
    defer lock.close(io);
    const current = readRecord(io, arena, home) orelse return null;
    const now_locked = @divTrunc(util.unixMs(io), 1000);
    if ((!std.mem.eql(u8, current.access, before.access) or !std.mem.eql(u8, current.refresh, before.refresh)) and current.expires_at > now_locked)
        return current.access;
    if (helpers.supersededToken(force, current.access, stale) and current.expires_at > now_locked) return current.access;
    if (current.refresh.len == 0) return valid(current, now_locked);
    const body = json(arena, .{ .grant_type = "refresh_token", .refresh_token = current.refresh, .client_id = client_id }) catch return valid(current, now_locked);
    const next = post(io, gpa, arena, endpoint, body, current.refresh) catch return valid(current, @divTrunc(util.unixMs(io), 1000));
    persistRefreshed(io, arena, home, next);
    return valid(next, @divTrunc(util.unixMs(io), 1000));
}

pub fn loadAnthropicOAuth(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, force: bool, stale: ?[]const u8) ?[]const u8 {
    return loadAt(io, gpa, arena, home, force, stale, token_endpoint);
}

/// A direct bind, NEVER oauth_callback.listen (which cancels a port holder).
/// Failing rather than changing the registered redirect keeps it consistent.
pub fn listen(io: Io, port: u16) !Io.net.Server {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    return address.listen(io, .{});
}

fn saveLogin(io: Io, arena: Allocator, home: []const u8, r: Record) !void {
    refresh_mutex.lockUncancelable(io);
    defer refresh_mutex.unlock(io);
    // No secret is written until writeOAuth applies the private directory modes.
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(recordPath(arena, home)) orelse return error.BadPathName);
    const lock = try lockRecord(io, arena, home);
    defer lock.close(io);
    try save(io, arena, home, r);
}

pub fn login(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, refresh_only: bool) !void {
    var obuf: [2048]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;
    if (refresh_only) {
        const before = readRecord(io, arena, home) orelse return error.OAuthRefreshFailed;
        const token = loadAnthropicOAuth(io, gpa, arena, home, true, before.access) orelse return error.OAuthRefreshFailed;
        const after = readRecord(io, arena, home) orelse return error.OAuthRefreshFailed;
        if (std.mem.eql(u8, token, before.access) and std.mem.eql(u8, after.refresh, before.refresh) and after.expires_at <= before.expires_at)
            return error.OAuthRefreshFailed;
        try out.writeAll("Anthropic sign-in refreshed.\n");
        return out.flush();
    }
    var server = try listen(io, 53692);
    defer server.deinit(io);
    const redirect = "http://localhost:53692/callback";
    var random: [32]u8 = undefined;
    io.random(&random);
    const verifier = helpers.b64url(arena, &random);
    if (verifier.len == 0) return error.OutOfMemory;
    const url = try authorizeUrl(arena, redirect, verifier);
    try out.print("\nSign in with Anthropic (your browser should open it):\n\n{s}\n", .{url});
    try @import("signin_link.zig").offer(io, out, url);
    try out.writeAll("\nWaiting for sign-in…\n");
    try out.flush();
    @import("signin_link.zig").open(io, url);
    while (true) {
        const stream = try server.accept(io);
        defer stream.close(io);
        var rbuf: [16 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, io, &rbuf);
        const line = (reader.interface.takeDelimiter('\n') catch null) orelse continue;
        const cb = parseCallback(arena, line) catch {
            callback.answer(io, stream, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            continue;
        } orelse {
            callback.answer(io, stream, callback.not_found);
            continue;
        };
        if (callbackPolicy(cb, verifier) == .stale) {
            callback.answer(io, stream, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nThis callback belongs to an earlier sign-in. Finish the newest sign-in.\n");
            continue;
        }
        const record = exchangeCodeAt(io, gpa, arena, token_endpoint, redirect, verifier, cb) catch |err| {
            callback.answer(io, stream, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nSign-in failed or was denied. Start sign-in again.\n");
            return err;
        };
        saveLogin(io, arena, home, record) catch |err| {
            helpers.persist_error = @errorName(err);
            callback.answer(io, stream, "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\nSign-in could not be saved.\n");
            return err;
        };
        callback.answer(io, stream, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nSigned in to Anthropic. You may close this tab.\n");
        try out.writeAll("Signed in to Anthropic.\n");
        return out.flush();
    }
}

test {
    _ = @import("oauth_anthropic_tests.zig");
}
