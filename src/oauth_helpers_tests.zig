//! Unit tests for oauth_helpers.zig, MCP refresh persistence, and provider
//! persist-error reporting, split out to stay well under the 600-line ceiling.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const helpers = @import("oauth_helpers.zig");
const mcp_oauth = @import("mcp_oauth.zig");
const kimi = @import("oauth_kimi.zig");
const oauth = @import("oauth.zig");
const strFieldObj = @import("util.zig").strFieldObj;

test "#402: loadCodexOAuth adopts the token /login wrote instead of minting a new one" {
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    try std.testing.expect(helpers.loadCodexOAuth(io, std.testing.allocator, arena, codex_home, false, null, "") == null);

    try helpers.writeCodexAuthAt(io, arena, codex_home, "", "tok-expired", "refresh-1", "acct-1");
    try std.testing.expectEqualStrings("tok-expired", helpers.loadCodexOAuth(io, std.testing.allocator, arena, codex_home, false, null, "acct-1").?.key);

    try helpers.writeCodexAuthAt(io, arena, codex_home, "", "tok-fresh", "refresh-2", "acct-1");
    const adopted = helpers.loadCodexOAuth(io, std.testing.allocator, arena, codex_home, true, "tok-expired", "acct-1").?;
    try std.testing.expectEqualStrings("tok-fresh", adopted.key);
    try std.testing.expectEqualStrings("acct-1", adopted.account);

    try helpers.writeCodexAuthAt(io, arena, codex_home, "", "tok-fresh", "", "acct-1");
    try std.testing.expectEqualStrings("tok-fresh", helpers.loadCodexOAuth(io, std.testing.allocator, arena, codex_home, true, "tok-fresh", "acct-1").?.key);

    try std.testing.expect(helpers.loadCodexOAuth(io, std.testing.allocator, arena, codex_home, true, "tok-expired", "acct-other") == null);
    try std.testing.expect(helpers.loadCodexOAuth(io, std.testing.allocator, arena, codex_home, false, null, "acct-other") == null);

    try helpers.writeCodexAuthAt(io, arena, codex_home, "", "tok-fresh", "refresh-3", "acct-9");
    const stored = helpers.readCodexAuth(io, arena, codex_home).?;
    try std.testing.expectEqualStrings("refresh-3", stored.refresh);
    try std.testing.expectEqualStrings("acct-9", stored.account);
}

test "#402: permanentRefreshFailure separates a dead refresh_token from a retryable blip" {
    try std.testing.expect(helpers.permanentRefreshFailure("invalid_grant"));
    try std.testing.expect(helpers.permanentRefreshFailure("refresh_token_expired"));
    try std.testing.expect(helpers.permanentRefreshFailure("refresh_token_reused"));
    try std.testing.expect(helpers.permanentRefreshFailure("refresh_token_invalidated"));
    try std.testing.expect(!helpers.permanentRefreshFailure("server_error"));
    try std.testing.expect(!helpers.permanentRefreshFailure("temporarily_unavailable"));
    try std.testing.expect(!helpers.permanentRefreshFailure("slow_down"));
    try std.testing.expect(!helpers.permanentRefreshFailure(""));

    try std.testing.expect(helpers.isTransientHttpStatus(.request_timeout));
    try std.testing.expect(helpers.isTransientHttpStatus(.too_many_requests));
    try std.testing.expect(helpers.isTransientHttpStatus(.bad_gateway));
    try std.testing.expect(helpers.isTransientHttpStatus(.service_unavailable));
    try std.testing.expect(!helpers.isTransientHttpStatus(.bad_request));
    try std.testing.expect(!helpers.isTransientHttpStatus(.unauthorized));
    try std.testing.expect(!helpers.isTransientHttpStatus(.ok));
}

test "#402: ONE resolver — the login writer and the mid-turn refresh cannot target different files" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{base});
    const home_codex = try std.fmt.allocPrint(arena, "{s}/.codex", .{home});
    const custom = try std.fmt.allocPrint(arena, "{s}/custom-codex-home", .{base});

    const saved = helpers.g_codex_home;
    defer helpers.g_codex_home = saved;

    helpers.g_codex_home = "";
    helpers.initCodexHome(arena, null, home);
    try std.testing.expectEqualStrings(home_codex, helpers.codexHomeDir(arena, home).?);
    try helpers.writeCodexAuth(io, arena, home, "", "home-tok", "r", "a");
    try std.testing.expectEqualStrings("home-tok", helpers.readCodexAuth(io, arena, helpers.codexHomeDir(arena, home).?).?.access);

    helpers.g_codex_home = "";
    helpers.initCodexHome(arena, custom, home);
    try std.testing.expectEqualStrings(custom, helpers.codexHomeDir(arena, home).?);
    try helpers.writeCodexAuth(io, arena, home, "", "env-tok", "r", "a");
    try std.testing.expectEqualStrings("env-tok", helpers.readCodexAuth(io, arena, helpers.codexHomeDir(arena, home).?).?.access);
    try std.testing.expectEqualStrings("home-tok", helpers.readCodexAuth(io, arena, home_codex).?.access);

    helpers.g_codex_home = "";
    helpers.initCodexHome(arena, "", home);
    try std.testing.expectEqualStrings(home_codex, helpers.g_codex_home);
    helpers.g_codex_home = "";
    try std.testing.expect(helpers.codexHomeDir(arena, "") == null);
}

test "#402: a refresh that cannot be persisted is reported, not swallowed" {
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    const blocker = try std.fmt.allocPrint(arena, "{s}/not-a-dir", .{base});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = blocker, .data = "x" });
    helpers.persist_error = null;
    const blocked_home = try std.fmt.allocPrint(arena, "{s}/codex", .{blocker});
    helpers.persistRefreshed(io, arena, blocked_home, "id", "new", "rotated", "acct");
    try std.testing.expect(helpers.takePersistError() != null);
    try std.testing.expect(helpers.takePersistError() == null);

    kimi.persistAuth(io, arena, blocked_home, "k-new", "k-rot", 9999, "");
    try std.testing.expect(helpers.takePersistError() != null);
    oauth.persistXaiAuth(io, arena, blocked_home, "x-new", "x-rot", 9999);
    try std.testing.expect(helpers.takePersistError() != null);

    helpers.persistRefreshed(io, arena, base, "id", "new", "rotated", "acct");
    try std.testing.expect(helpers.takePersistError() == null);
    try std.testing.expectEqualStrings("new", helpers.readCodexAuth(io, arena, base).?.access);
}

test "#402: a refresh write preserves the fields the codex CLI owns" {
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try helpers.codexAuthPath(arena, codex_home),
        .data =
        \\{"OPENAI_API_KEY":"sk-user-key","auth_mode":"chatgpt","agent_identity":"ai","tokens":{"access_token":"old","refresh_token":"r0","account_id":"acct-1","personal_access_token":"pat"},"last_refresh":"2026-01-02T03:04:05Z"}
        ,
    });

    try helpers.writeCodexAuthAt(io, arena, codex_home, "id2", "new", "r1", "acct-1");
    const raw = try Io.Dir.cwd().readFileAlloc(io, try helpers.codexAuthPath(arena, codex_home), arena, .limited(64 * 1024));
    const v = try std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always });
    try std.testing.expectEqualStrings("sk-user-key", strFieldObj(v.object, "OPENAI_API_KEY").?);
    try std.testing.expectEqualStrings("ai", strFieldObj(v.object, "agent_identity").?);
    const tokens = v.object.get("tokens").?.object;
    try std.testing.expectEqualStrings("pat", strFieldObj(tokens, "personal_access_token").?);
    try std.testing.expectEqualStrings("new", strFieldObj(tokens, "access_token").?);
    try std.testing.expectEqualStrings("r1", strFieldObj(tokens, "refresh_token").?);
    const stamp = strFieldObj(v.object, "last_refresh").?;
    try std.testing.expectEqual(@as(usize, 20), stamp.len);
    try std.testing.expect(stamp[10] == 'T' and stamp[19] == 'Z');

    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("2026-08-05T12:34:56Z", helpers.rfc3339Utc(&buf, 1_785_933_296_000));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", helpers.rfc3339Utc(&buf, 0));

    var dir = try Io.Dir.cwd().openDir(io, codex_home, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var names: usize = 0;
    while (try it.next(io)) |entry| {
        try std.testing.expectEqualStrings("auth.json", entry.name);
        names += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), names);
}

test "browserArgv opens the default browser on every platform" {
    var buf: [4][]const u8 = undefined;
    const url = "https://codegraff.com/cli/auth?code=AB12-CD34&x=1";
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "rundll32.exe", "url.dll,FileProtocolHandler", url }), helpers.browserArgv(.windows, null, url, &buf));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "open", url }), helpers.browserArgv(.macos, null, url, &buf));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "xdg-open", url }), helpers.browserArgv(.linux, null, url, &buf));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "open", "-a", "Safari", url }), helpers.browserArgv(.macos, "Safari", url, &buf));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "firefox", url }), helpers.browserArgv(.windows, "firefox", url, &buf));
}

test "#1612: rotated Codex credential survives transient write failure in memory and flushes when writable" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    const Mock = struct {
        var calls: usize = 0;
        var mode: enum { transient, rotate } = .transient;
        fn post(_: Io, _: Allocator, arena: Allocator, _: []const u8, body: []const u8) !std.json.ObjectMap {
            calls += 1;
            if (mode == .transient) return error.TransientOAuthStatus;
            // Must spend r0, never replay r0 a second time.
            try std.testing.expect(std.mem.indexOf(u8, body, "refresh_token=r0&") != null);
            const v = try std.json.parseFromSliceLeaky(Value, arena, "{\"access_token\":\"tok-rotated\",\"refresh_token\":\"r1\"}", .{ .allocate = .alloc_always });
            return v.object;
        }
    };
    Mock.calls = 0;
    Mock.mode = .transient;

    {
        var a1 = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a1.deinit();
        try helpers.writeCodexAuthAt(io, a1.allocator(), codex_home, "id0", "tok-old", "r0", "acct-1");
        // Transient 5xx/offline error preserves r0 without marking it dead.
        const stay = helpers.loadCodexOAuthWithPost(io, std.testing.allocator, a1.allocator(), codex_home, true, "tok-old", "acct-1", Mock.post).?;
        try std.testing.expectEqualStrings("tok-old", stay.key);
        try std.testing.expectEqual(@as(usize, 1), Mock.calls);
    }

    // Make codex_home read-only so auth.json can be read, while atomic staging write fails.
    const dir_ro = try Io.Dir.cwd().openDir(io, codex_home, .{ .iterate = true });
    try dir_ro.setPermissions(io, @fromBackingInt(@intCast(0o500)));
    dir_ro.close(io);
    errdefer {
        if (Io.Dir.cwd().openDir(io, codex_home, .{ .iterate = true })) |d| {
            d.setPermissions(io, @fromBackingInt(@intCast(0o700))) catch {};
            d.close(io);
        } else |_| {}
    }

    Mock.mode = .rotate;
    {
        var a2 = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a2.deinit();
        const got = helpers.loadCodexOAuthWithPost(io, std.testing.allocator, a2.allocator(), codex_home, true, "tok-old", "acct-1", Mock.post).?;
        try std.testing.expectEqualStrings("tok-rotated", got.key);
        try std.testing.expectEqual(@as(usize, 2), Mock.calls);
        try std.testing.expect(helpers.takePersistError() != null);
    }

    // Arena a2 is now freed! Next turn while still read-only still gets tok-rotated from PendingSlot with zero network POSTs.
    {
        var a3 = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a3.deinit();
        const cached = helpers.loadCodexOAuthWithPost(io, std.testing.allocator, a3.allocator(), codex_home, false, null, "acct-1", Mock.post).?;
        try std.testing.expectEqualStrings("tok-rotated", cached.key);
        try std.testing.expectEqual(@as(usize, 2), Mock.calls);
    }

    // Restore write permission: next call flushes r1 to disk automatically!
    const dir_rw = try Io.Dir.cwd().openDir(io, codex_home, .{ .iterate = true });
    try dir_rw.setPermissions(io, @fromBackingInt(@intCast(0o700)));
    dir_rw.close(io);
    {
        var a4 = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a4.deinit();
        const flushed = helpers.loadCodexOAuthWithPost(io, std.testing.allocator, a4.allocator(), codex_home, false, null, "acct-1", Mock.post).?;
        try std.testing.expectEqualStrings("tok-rotated", flushed.key);
        const on_disk = helpers.readCodexAuth(io, a4.allocator(), codex_home).?;
        try std.testing.expectEqualStrings("tok-rotated", on_disk.access);
        try std.testing.expectEqualStrings("r1", on_disk.refresh);
    }
}

test "#1612: sibling CLI rotation during in-flight refresh_token_reused is adopted instead of poisoned" {
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    try helpers.writeCodexAuthAt(io, arena, codex_home, "id0", "tok-stale", "r-shared", "acct-1");

    const Race = struct {
        var home: []const u8 = "";
        fn post(post_io: Io, _: Allocator, post_arena: Allocator, _: []const u8, _: []const u8) !std.json.ObjectMap {
            // Sibling `codex` CLI won the race and wrote new tokens while our POST was in flight.
            try helpers.writeCodexAuthAt(post_io, post_arena, home, "id1", "tok-sibling", "r-sibling", "acct-1");
            const v = try std.json.parseFromSliceLeaky(Value, post_arena, "{\"error\":\"refresh_token_reused\"}", .{ .allocate = .alloc_always });
            return v.object;
        }
    };
    Race.home = codex_home;
    const recovered = helpers.loadCodexOAuthWithPost(io, std.testing.allocator, arena, codex_home, true, "tok-stale", "acct-1", Race.post).?;
    try std.testing.expectEqualStrings("tok-sibling", recovered.key);
    try std.testing.expectEqualStrings("acct-1", recovered.account);
}

test "#1612: MCP loadAccessTokenWithPost persists rotated refresh_token without optional discovery fields" {
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const resource = "https://mcp.example/api";

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(resource, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const dir = try std.fmt.allocPrint(arena, "{s}/.simple-harness-mcp", .{home});
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ dir, &hex });
    // Stored credential omits issuer / authorization_endpoint / registration_endpoint.
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "{\"resource\":\"https://mcp.example/api\",\"token_endpoint\":\"https://idp.example/token\",\"client_id\":\"c1\",\"access_token\":\"mcp-old\",\"refresh_token\":\"mcp-r0\",\"expires_at_ms\":1}",
    });

    const MockMcp = struct {
        fn post(_: Io, _: Allocator, post_arena: Allocator, _: []const u8, _: []const u8) !std.json.ObjectMap {
            const v = try std.json.parseFromSliceLeaky(Value, post_arena, "{\"access_token\":\"mcp-new\",\"refresh_token\":\"mcp-r1\",\"expires_in\":3600}", .{ .allocate = .alloc_always });
            return v.object;
        }
    };
    const tok = mcp_oauth.loadAccessTokenWithPost(io, std.testing.allocator, arena, home, resource, MockMcp.post).?;
    try std.testing.expectEqualStrings("mcp-new", tok);
    const saved = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"refresh_token\":\"mcp-r1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"access_token\":\"mcp-new\"") != null);
}

test "#1612: cross-process advisory lock serializes Codex OAuth refreshers and adopts disk without double-spending" {
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    try helpers.writeCodexAuthAt(io, arena, codex_home, "id0", "tok-0", "r-0", "acct-1");

    const Mock = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn post(post_io: Io, _: Allocator, post_arena: Allocator, _: []const u8, body: []const u8) !std.json.ObjectMap {
            const n = calls.fetchAdd(1, .acq_rel);
            try post_io.sleep(.fromMilliseconds(40), .awake);
            if (n > 0) return error.DoubleSpentRefreshToken;
            if (std.mem.indexOf(u8, body, "refresh_token=r-ext") == null) return error.WrongRefreshToken;
            const v = try std.json.parseFromSliceLeaky(Value, post_arena, "{\"access_token\":\"tok-r2\",\"refresh_token\":\"r-2\",\"id_token\":\"id2\"}", .{ .allocate = .alloc_always });
            return v.object;
        }
    };
    Mock.calls.store(0, .release);

    const Caller = struct {
        home: []const u8,
        out: [64]u8 = undefined,
        len: usize = 0,
        fn run(self: *@This(), cio: Io) void {
            var local = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer local.deinit();
            if (helpers.loadCodexOAuthWithPost(cio, std.testing.allocator, local.allocator(), self.home, true, null, "acct-1", Mock.post)) |fk| {
                @memcpy(self.out[0..fk.key.len], fk.key);
                self.len = fk.key.len;
            }
        }
    };

    // Phase 1: another OS process holds auth.json.lock while rotating tok-0 -> tok-ext.
    const lock_path = try std.fmt.allocPrint(arena, "{s}/auth.json.lock", .{codex_home});
    const ext_lock = try Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive });
    var c1: Caller = .{ .home = codex_home };
    var c2: Caller = .{ .home = codex_home };
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Caller.run, .{ &c1, io });
        try group.concurrent(io, Caller.run, .{ &c2, io });
        try io.sleep(.fromMilliseconds(30), .awake);
        try helpers.writeCodexAuthAt(io, arena, codex_home, "id1", "tok-ext", "r-ext", "acct-1");
        ext_lock.close(io);
        try group.await(io);
    }
    try std.testing.expectEqual(@as(usize, 0), Mock.calls.load(.acquire));
    try std.testing.expectEqualStrings("tok-ext", c1.out[0..c1.len]);
    try std.testing.expectEqualStrings("tok-ext", c2.out[0..c2.len]);

    // Phase 2: two concurrent forced refreshes race on tok-ext/r-ext; only one POSTs.
    var c3: Caller = .{ .home = codex_home };
    var c4: Caller = .{ .home = codex_home };
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Caller.run, .{ &c3, io });
        try group.concurrent(io, Caller.run, .{ &c4, io });
        try group.await(io);
    }
    try std.testing.expectEqual(@as(usize, 1), Mock.calls.load(.acquire));
    try std.testing.expectEqualStrings("tok-r2", c3.out[0..c3.len]);
    try std.testing.expectEqualStrings("tok-r2", c4.out[0..c4.len]);
}

test "#1612: mid-flight task cancelation does not abort Codex OAuth token exchange or persistence" {
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    try helpers.writeCodexAuthAt(io, arena, codex_home, "id0", "tok-before", "r-before", "acct-1");

    const SlowPost = struct {
        var in_flight: std.atomic.Value(bool) = .init(false);
        fn post(post_io: Io, _: Allocator, post_arena: Allocator, _: []const u8, _: []const u8) !std.json.ObjectMap {
            in_flight.store(true, .release);
            try post_io.sleep(.fromMilliseconds(60), .awake);
            const v = try std.json.parseFromSliceLeaky(Value, post_arena, "{\"access_token\":\"tok-shielded\",\"refresh_token\":\"r-shielded\",\"id_token\":\"id-s\"}", .{ .allocate = .alloc_always });
            return v.object;
        }
    };
    SlowPost.in_flight.store(false, .release);

    const Runner = struct {
        home: []const u8,
        key_buf: [64]u8 = undefined,
        key_len: usize = 0,
        cancel_preserved: bool = false,

        fn run(self: *@This(), rio: Io) void {
            var local = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer local.deinit();
            if (helpers.loadCodexOAuthWithPost(rio, std.testing.allocator, local.allocator(), self.home, true, "tok-before", "acct-1", SlowPost.post)) |fk| {
                @memcpy(self.key_buf[0..fk.key.len], fk.key);
                self.key_len = fk.key.len;
            }
            rio.checkCancel() catch |err| switch (err) {
                error.Canceled => self.cancel_preserved = true,
            };
        }
    };

    var runner: Runner = .{ .home = codex_home };
    var future = try io.concurrent(Runner.run, .{ &runner, io });
    while (!SlowPost.in_flight.load(.acquire)) {
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    future.cancel(io);

    try std.testing.expectEqualStrings("tok-shielded", runner.key_buf[0..runner.key_len]);
    try std.testing.expect(runner.cancel_preserved);
    const saved = helpers.readCodexAuth(io, arena, codex_home).?;
    try std.testing.expectEqualStrings("tok-shielded", saved.access);
    try std.testing.expectEqualStrings("r-shielded", saved.refresh);
}

test "#1612: concurrent MCP and Kimi refreshers serialize and adopt rotated disk credentials" {
    const io = std.testing.io;
    defer helpers.clearStateForTest(io);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const resource = "https://mcp.example/concurrent";

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(resource, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const mcp_dir = try std.fmt.allocPrint(arena, "{s}/.simple-harness-mcp", .{home});
    try Io.Dir.cwd().createDirPath(io, mcp_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ mcp_dir, &hex }),
        .data = "{\"resource\":\"https://mcp.example/concurrent\",\"token_endpoint\":\"https://idp.example/token\",\"client_id\":\"c1\",\"access_token\":\"mcp-0\",\"refresh_token\":\"mcp-r0\",\"expires_at_ms\":1}",
    });
    try kimi.writeAuth(io, arena, home, "kimi-0", "kimi-r0", 1, kimi.Region.global.host());

    const MockBoth = struct {
        var mcp_calls: std.atomic.Value(usize) = .init(0);
        var kimi_calls: std.atomic.Value(usize) = .init(0);
        fn postMcp(pio: Io, _: Allocator, pa: Allocator, _: []const u8, _: []const u8) !std.json.ObjectMap {
            if (mcp_calls.fetchAdd(1, .acq_rel) > 0) return error.McpDoubleSpent;
            try pio.sleep(.fromMilliseconds(30), .awake);
            return (try std.json.parseFromSliceLeaky(Value, pa, "{\"access_token\":\"mcp-1\",\"refresh_token\":\"mcp-r1\",\"expires_in\":3600}", .{ .allocate = .alloc_always })).object;
        }
        fn postKimi(pio: Io, _: Allocator, pa: Allocator, _: []const u8, _: []const u8) !std.json.ObjectMap {
            if (kimi_calls.fetchAdd(1, .acq_rel) > 0) return error.KimiDoubleSpent;
            try pio.sleep(.fromMilliseconds(30), .awake);
            return (try std.json.parseFromSliceLeaky(Value, pa, "{\"access_token\":\"kimi-1\",\"refresh_token\":\"kimi-r1\",\"expires_in\":3600}", .{ .allocate = .alloc_always })).object;
        }
    };
    MockBoth.mcp_calls.store(0, .release);
    MockBoth.kimi_calls.store(0, .release);

    const Task = struct {
        home: []const u8,
        res: []const u8,
        mcp_ok: bool = false,
        kimi_ok: bool = false,
        fn run(self: *@This(), tio: Io) void {
            var local = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer local.deinit();
            if (mcp_oauth.loadAccessTokenWithPost(tio, std.testing.allocator, local.allocator(), self.home, self.res, MockBoth.postMcp)) |t|
                self.mcp_ok = std.mem.eql(u8, t, "mcp-1");
            if (kimi.loadWithPost(tio, std.testing.allocator, local.allocator(), self.home, false, null, MockBoth.postKimi)) |k|
                self.kimi_ok = std.mem.eql(u8, k, "kimi-1");
        }
    };
    var t1: Task = .{ .home = home, .res = resource };
    var t2: Task = .{ .home = home, .res = resource };
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Task.run, .{ &t1, io });
        try group.concurrent(io, Task.run, .{ &t2, io });
        try group.await(io);
    }
    try std.testing.expectEqual(@as(usize, 1), MockBoth.mcp_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), MockBoth.kimi_calls.load(.acquire));
    try std.testing.expect(t1.mcp_ok and t2.mcp_ok);
    try std.testing.expect(t1.kimi_ok and t2.kimi_ok);
}
