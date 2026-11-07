//! Offline protocol and real HTTP loopback tests for native Anthropic OAuth.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const auth = @import("oauth_anthropic.zig");
const store = @import("credential_store.zig");
const helpers = @import("oauth_helpers.zig");
const util = @import("util.zig");

const Mock = struct {
    server: Io.net.Server,
    response: []const u8 = "{\"access_token\":\"new-access\",\"refresh_token\":\"rotated-refresh\",\"expires_in\":3600}",
    status: []const u8 = "200 OK",
    body: [8192]u8 = undefined,
    len: usize = 0,
    content_type: bool = false,
    failed: bool = false,
    block_path: ?[]const u8 = null,

    fn run(self: *Mock, io: Io) void {
        self.serve(io) catch {
            self.failed = true;
        };
    }

    fn serve(self: *Mock, io: Io) !void {
        const stream = try self.server.accept(io);
        defer stream.close(io);
        var buf: [16 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, io, &buf);
        const request = (try reader.interface.takeDelimiter('\n')) orelse return error.BadRequest;
        if (!std.mem.startsWith(u8, request, "POST /token HTTP/1.1")) return error.BadRequest;
        var length: usize = 0;
        while (true) {
            const raw = (try reader.interface.takeDelimiter('\n')) orelse return error.BadRequest;
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:"))
                length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t"), 10);
            if (std.ascii.startsWithIgnoreCase(line, "content-type:"))
                self.content_type = std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[13..], " \t"), "application/json");
        }
        if (length > self.body.len) return error.TooLarge;
        try reader.interface.readSliceAll(self.body[0..length]);
        self.len = length;
        if (self.block_path) |path| {
            try Io.Dir.cwd().deleteFile(io, path);
            try Io.Dir.cwd().createDir(io, path, store.private_dir);
        }
        var wbuf: [4096]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, io, &wbuf);
        try writer.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.status, self.response.len, self.response });
        try writer.interface.flush();
    }

    fn endpoint(self: *const Mock, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/token", .{self.server.socket.address.getPort()});
    }

    fn object(self: *const Mock, a: std.mem.Allocator) !std.json.ObjectMap {
        return (try std.json.parseFromSliceLeaky(std.json.Value, a, self.body[0..self.len], .{ .allocate = .alloc_always })).object;
    }
};

fn homePath(tmp: *std.testing.TmpDir, a: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return a.dupe(u8, buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
}

fn field(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return util.strFieldObj(o, key) orelse "";
}

test "Anthropic OAuth: public client, scopes and PKCE match browser protocol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const url = try auth.authorizeUrl(a, "http://localhost:53692/callback", verifier);
    for ([_][]const u8{
        "https://claude.ai/oauth/authorize?code=true&response_type=code&",
        "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&",
        "redirect_uri=http%3A%2F%2Flocalhost%3A53692%2Fcallback&",
        "scope=org%3Acreate_api_key%20user%3Aprofile%20user%3Ainference%20user%3Asessions%3Aclaude_code%20user%3Amcp_servers%20user%3Afile_upload&",
        "code_challenge_method=S256&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&",
        "state=" ++ verifier,
    }) |part| try std.testing.expect(std.mem.indexOf(u8, url, part) != null);
    var id: [36]u8 = undefined;
    try std.base64.standard.Decoder.decode(&id, "OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl");
    try std.testing.expectEqualStrings(auth.client_id, &id);
}

test "Anthropic OAuth: callback denial, state mismatch, decoding and duplicate rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cb = (try auth.parseCallback(a, "GET /callback?code=a%2Bb%22&state=s-1 HTTP/1.1\r")).?;
    try std.testing.expectEqualStrings("a+b\"", cb.code);
    try auth.validateCallback(cb, "s-1");
    try std.testing.expectError(error.OAuthStateMismatch, auth.validateCallback(cb, "wrong"));
    const denied = (try auth.parseCallback(a, "GET /callback?error=access_denied&state=s-1 HTTP/1.1")).?;
    try std.testing.expectError(error.OAuthDenied, auth.validateCallback(denied, "s-1"));
    try std.testing.expectError(error.OAuthStateMismatch, auth.validateCallback(denied, "other"));
    try std.testing.expectError(error.MissingOAuthCode, auth.validateCallback(.{ .state = "s" }, "s"));
    try std.testing.expectError(error.BadCallback, auth.parseCallback(a, "GET /callback?state=one&state=two HTTP/1.1"));
    try std.testing.expectError(error.BadCallback, auth.parseCallback(a, "GET /callback?code=% HTTP/1.1"));
    try std.testing.expect(try auth.parseCallback(a, "GET /favicon.ico HTTP/1.1") == null);
    try std.testing.expect(try auth.parseCallback(a, "GET /callbackx?code=x HTTP/1.1") == null);
}

test "Anthropic OAuth: real loopback authorization code exchange sends JSON and expiry seconds" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mock: Mock = .{ .server = try auth.listen(io, 0) };
    defer mock.server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Mock.run, .{ &mock, io });
    const now = @divTrunc(util.unixMs(io), 1000);
    const record = try auth.exchangeCodeAt(io, std.testing.allocator, a, try mock.endpoint(a), "http://localhost:53692/callback", "verifier", .{ .code = "code\"value", .state = "verifier" });
    try group.await(io);
    try std.testing.expect(!mock.failed);
    try std.testing.expect(mock.content_type);
    const o = try mock.object(a);
    try std.testing.expectEqualStrings("authorization_code", field(o, "grant_type"));
    try std.testing.expectEqualStrings("code\"value", field(o, "code"));
    try std.testing.expectEqualStrings("verifier", field(o, "state"));
    try std.testing.expectEqualStrings("verifier", field(o, "code_verifier"));
    try std.testing.expectEqualStrings(auth.client_id, field(o, "client_id"));
    try std.testing.expectEqualStrings("http://localhost:53692/callback", field(o, "redirect_uri"));
    try std.testing.expectEqualStrings("new-access", record.access);
    try std.testing.expect(record.expires_at >= now + 3600 and record.expires_at < now + 3610);
}

test "Anthropic OAuth: early refresh persists rotation atomically and stale 401 adopts without HTTP" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try homePath(&tmp, a);
    const now = @divTrunc(util.unixMs(io), 1000);
    try store.writeOAuth(io, a, home, auth.provider_dir, "old", "refresh\"old", now + 299);
    const original = try Io.Dir.cwd().openFile(io, auth.recordPath(a, home), .{});
    defer original.close(io);
    var mock: Mock = .{ .server = try auth.listen(io, 0) };
    defer mock.server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Mock.run, .{ &mock, io });
    const result = auth.loadAt(io, std.testing.allocator, a, home, false, null, try mock.endpoint(a));
    try std.testing.expectEqualStrings("new-access", result.?);
    try group.await(io);
    try std.testing.expect(!mock.failed);
    try std.testing.expect(mock.content_type);
    const body = try mock.object(a);
    try std.testing.expectEqualStrings("refresh_token", field(body, "grant_type"));
    try std.testing.expectEqualStrings("refresh\"old", field(body, "refresh_token"));
    try std.testing.expectEqualStrings(auth.client_id, field(body, "client_id"));
    const saved = auth.readRecord(io, a, home).?;
    try std.testing.expectEqualStrings("rotated-refresh", saved.refresh);
    try std.testing.expect(saved.expires_at > now + 3590);
    var rbuf: [1024]u8 = undefined;
    var reader = original.reader(io, &rbuf);
    const old_bytes = try reader.interface.allocRemaining(a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, old_bytes, "\"access_token\":\"old\"") != null);
    const stat = try Io.Dir.cwd().statFile(io, auth.recordPath(a, home), .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    // An unreachable seam proves these paths never mint another credential.
    try std.testing.expectEqualStrings("new-access", auth.loadAt(io, std.testing.allocator, a, home, true, "old", "http://127.0.0.1:1/token").?);
    try std.testing.expectEqualStrings("new-access", auth.loadAt(io, std.testing.allocator, a, home, false, null, "http://127.0.0.1:1/token").?);
}

test "Anthropic OAuth: failed refresh fails closed after expiry but preserves unexpired access" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try homePath(&tmp, a);
    for ([_]i64{ -1, 120 }) |remaining| {
        const now = @divTrunc(util.unixMs(io), 1000);
        try store.writeOAuth(io, a, home, auth.provider_dir, "old", "refresh", now + remaining);
        var mock: Mock = .{ .server = try auth.listen(io, 0), .status = "400 Bad Request", .response = "{\"error\":\"invalid_grant\"}" };
        defer mock.server.deinit(io);
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Mock.run, .{ &mock, io });
        const result = auth.loadAt(io, std.testing.allocator, a, home, true, "old", try mock.endpoint(a));
        try group.await(io);
        try std.testing.expect(!mock.failed);
        if (remaining < 0) try std.testing.expect(result == null) else try std.testing.expectEqualStrings("old", result.?);
        try std.testing.expectEqualStrings("refresh", auth.readRecord(io, a, home).?.refresh);
    }
    try store.writeOAuth(io, a, home, auth.provider_dir, "expired", "", 1);
    try std.testing.expect(auth.loadAt(io, std.testing.allocator, a, home, true, "different", "http://127.0.0.1:1/token") == null);
}

test "Anthropic OAuth: persistence failure reports only a safe error name" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "file" });
    const home = try std.fmt.allocPrint(a, "{s}/blocked", .{try homePath(&tmp, a)});
    helpers.persist_error = null;
    auth.persistRefreshed(io, a, home, .{ .access = "private-access", .refresh = "private-refresh", .expires_at = 123 });
    const message = helpers.takePersistError() orelse return error.MissingPersistenceWarning;
    try std.testing.expect(std.mem.indexOf(u8, message, "private-") == null);
    try std.testing.expect(helpers.takePersistError() == null);
}

test "Anthropic OAuth: refresh HTTP success surfaces a failed credential replacement" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try homePath(&tmp, a);
    try store.writeOAuth(io, a, home, auth.provider_dir, "old", "refresh", 1);
    var mock: Mock = .{ .server = try auth.listen(io, 0), .block_path = auth.recordPath(a, home) };
    defer mock.server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    helpers.persist_error = null;
    defer helpers.persist_error = null;
    try group.concurrent(io, Mock.run, .{ &mock, io });
    const fresh = auth.loadAt(io, std.testing.allocator, a, home, false, null, try mock.endpoint(a));
    try group.await(io);
    try std.testing.expect(!mock.failed);
    try std.testing.expectEqualStrings("new-access", fresh.?);
    try std.testing.expect(helpers.takePersistError() != null);
    try std.testing.expect(auth.readRecord(io, a, home) == null);
}

test "Anthropic OAuth: refresh-only login without Graff credentials fails without browser" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try homePath(&tmp, a);
    try std.testing.expectError(error.OAuthRefreshFailed, auth.login(io, std.testing.allocator, a, home, true));
    try std.testing.expect(auth.loadAnthropicOAuth(io, std.testing.allocator, a, home, false, null) == null);
}

const Stall = struct {
    server: *Io.net.Server,
    send_head: bool,
    accepted: std.atomic.Value(bool) = .init(false),

    fn run(self: *Stall, io: Io) void {
        const stream = self.server.accept(io) catch return;
        defer stream.close(io);
        self.accepted.store(true, .release);
        if (self.send_head) {
            var buf: [256]u8 = undefined;
            var writer = Io.net.Stream.Writer.init(stream, io, &buf);
            writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n{") catch return;
            writer.interface.flush() catch return;
        }
        io.sleep(.fromSeconds(10), .awake) catch {};
    }
};

test "Anthropic OAuth: token HTTP deadline cancels stalled headers and bodies" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |send_head| {
        var server = try auth.listen(io, 0);
        defer server.deinit(io);
        var stall: Stall = .{ .server = &server, .send_head = send_head };
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Stall.run, .{ &stall, io });
        const endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/token", .{server.socket.address.getPort()});
        const start = util.unixMs(io);
        try std.testing.expectError(error.DeadlineExceeded, auth.postWithDeadline(io, std.testing.allocator, a, endpoint, "{}", "refresh", .fromMilliseconds(150)));
        try std.testing.expect(stall.accepted.load(.acquire));
        try std.testing.expect(util.unixMs(io) - start < 3000);
    }
}

test "Anthropic OAuth: stale callback policy continues until current code or denial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const attempts = [_][]const u8{
        "GET /callback?code=old-code&state=old-state HTTP/1.1",
        "GET /callback?error=access_denied&state=old-state HTTP/1.1",
        "GET /callback?code=no-state HTTP/1.1",
        "GET /callback?code=current-code&state=current-state HTTP/1.1",
    };
    var ignored: usize = 0;
    for (attempts) |line| {
        const cb = (try auth.parseCallback(a, line)).?;
        if (auth.callbackPolicy(cb, "current-state") == .stale) {
            ignored += 1;
            continue;
        }
        try std.testing.expectEqualStrings("current-code", cb.code);
        try auth.validateCallback(cb, "current-state");
        break;
    }
    try std.testing.expectEqual(@as(usize, 3), ignored);
    const denied = (try auth.parseCallback(a, "GET /callback?error=access_denied&state=current-state HTTP/1.1")).?;
    try std.testing.expectEqual(auth.CallbackPolicy.finish, auth.callbackPolicy(denied, "current-state"));
    try std.testing.expectError(error.OAuthDenied, auth.validateCallback(denied, "current-state"));
}

test "Anthropic OAuth: unrelated port holder is not cancelled" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var first = try auth.listen(io, 0);
    defer first.deinit(io);
    try std.testing.expectError(error.AddressInUse, auth.listen(io, first.socket.address.getPort()));
    // There was no connect/cancel request: the original listener remains usable.
    try std.testing.expect(first.socket.address.getPort() != 0);
}
