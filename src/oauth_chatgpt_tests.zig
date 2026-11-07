//! Tests for oauth_chatgpt.zig (ADR 0221), split out for the 600-line cap.
//! Everything here is offline: no browser, no token endpoint.

const std = @import("std");
const chatgpt = @import("oauth_chatgpt.zig");
const credential_store = @import("credential_store.zig");

const host = "urn:uuid:00000000-0000-4000-8000-000000000000";

test "ChatGPT sign-in: a first registration names Graff and sends every required parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const url = try chatgpt.authorizeUrl(arena.allocator(), .{
        .client_id = chatgpt.dynamic_client,
        .redirect = "http://127.0.0.1:1455/auth/callback",
        .state = "st",
        .nonce = "no",
        .challenge = "ch",
        .host_id = host,
    });
    try std.testing.expect(std.mem.startsWith(u8, url, "https://auth.openai.com/api/accounts/authorize?client_id=dynamic_agent_client&"));
    for ([_][]const u8{
        "response_type=code",
        "redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback",
        "scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct",
        "resource=https%3A%2F%2Fapi.openai.com%2Fv1",
        "state=st",
        "nonce=no",
        "code_challenge=ch",
        "code_challenge_method=S256",
        "ext_agent_host_id=urn%3Auuid%3A00000000-0000-4000-8000-000000000000",
        "agent_name_hint=Graff",
    }) |part| try std.testing.expect(std.mem.indexOf(u8, url, part) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "id_token_hint") == null);
}

test "ChatGPT sign-in: a returning sign-in reuses the issued app id with account hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const url = try chatgpt.authorizeUrl(arena.allocator(), .{
        .client_id = "oaiapp_x",
        .redirect = "http://127.0.0.1:1456/auth/callback",
        .state = "st",
        .nonce = "no",
        .challenge = "ch",
        .host_id = host,
        .login_hint = "you@example.com",
    });
    for ([_][]const u8{ "client_id=oaiapp_x&", "login_hint=you%40example.com", "127.0.0.1%3A1456" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, url, part) != null);
    // A saved token never rides in the URL: openers expose it in argv.
    try std.testing.expect(std.mem.indexOf(u8, url, "id_token_hint") == null);
    // The name hint is for first registrations only.
    try std.testing.expect(std.mem.indexOf(u8, url, "agent_name_hint") == null);
}

test "ChatGPT sign-in: callbacks decode their query and ignore other paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cb = chatgpt.parseCallback(a, "GET /auth/callback?code=ac_1.x-y&scope=chatgpt.tokens.use.direct+email&state=s%2B1&client_id=oaiapp_Z HTTP/1.1\r").?;
    try std.testing.expectEqualStrings("ac_1.x-y", cb.code);
    try std.testing.expectEqualStrings("s+1", cb.state);
    try std.testing.expectEqualStrings("oaiapp_Z", cb.client_id);
    const denied = chatgpt.parseCallback(a, "GET /auth/callback?error=access_denied&state=s HTTP/1.1").?;
    try std.testing.expectEqualStrings("access_denied", denied.err);
    try std.testing.expect(chatgpt.parseCallback(a, "GET /favicon.ico HTTP/1.1") == null);
    try std.testing.expect(chatgpt.parseCallback(a, "GET /auth/callbackx?code=1 HTTP/1.1") == null);
    try std.testing.expectEqualStrings("a%20b%2Fc~d", try chatgpt.percentEncode(a, "a b/c~d"));
    try std.testing.expectEqualStrings("a b/c%", try chatgpt.percentDecode(a, "a+b%2Fc%"));
}

test "ChatGPT sign-in: the chatgpt-new provider is a flat-rate plan on the public Responses endpoint" {
    const provider = @import("provider.zig");
    const spec = provider.specFor("chatgpt-new").?;
    try std.testing.expectEqual(provider.ProviderSpec.LoginKind.chatgpt_browser, spec.login);
    try std.testing.expect(spec.sub_login);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", spec.url);
    try std.testing.expectEqual(@import("billing.zig").Billing.sub, @import("billing.zig").forSeat("chatgpt-new", "gpt-6.1-sol", .login));
    // The route uses the verified subscription default, not the API maximum.
    try std.testing.expectEqual(@as(u64, 500_000), @import("pricing.zig").contextFor("chatgpt-new", "gpt-6.1-sol"));
    const p: provider.Provider = .{ .id = "chatgpt-new", .kind = .responses, .auth = .bearer, .url = spec.url, .api_key = "", .model = "gpt-6.1-sol", .context = 500_000 };
    try std.testing.expectEqual(@import("agent_server_compact.zig").ManualRoute.in_stream, @import("agent_server_compact.zig").manualRoute(p));
}

test "ChatGPT sign-in: host ids are version-4 UUID URNs" {
    const id = chatgpt.formatHostId(@splat(0xff));
    try std.testing.expectEqualStrings("urn:uuid:ffffffff-ffff-4fff-bfff-ffffffffffff", &id);
}

const probe_record =
    \\{"email": "you@example.com", "issuer": "https://auth.openai.com", "subject": "user-1",
    \\ "client_id": "oaiapp_x", "ext_agent_host_id": "urn:uuid:1", "id_token": "a.b.c",
    \\ "access_token": "tok-1", "refresh_token": "ref-1", "token_type": "Bearer", "expires_in": 3600,
    \\ "expires_at": 4102444800, "earliest_refresh_at": 4102444000,
    \\ "scopes": ["chatgpt.tokens.use.direct", "email", "offline_access", "openid", "profile", "resource.invoke"],
    \\ "saved_at": "2026-09-30T00:00:00Z"}
;

test "ChatGPT sign-in: the saved record round-trips and reads the trial script's format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = chatgpt.parseRecord(a, probe_record).?;
    try std.testing.expectEqualStrings("oaiapp_x", r.client_id);
    try std.testing.expectEqualStrings("urn:uuid:1", r.host_id);
    try std.testing.expectEqualStrings("ref-1", r.refresh);
    try std.testing.expectEqual(@as(i64, 4102444800), r.expires_at);
    try std.testing.expect(r.planEnabled());
    const again = chatgpt.parseRecord(a, try chatgpt.serializeRecord(a, r, "2026-09-30T00:00:00Z")).?;
    try std.testing.expectEqualStrings(r.access, again.access);
    try std.testing.expectEqualStrings(r.subject, again.subject);
    try std.testing.expectEqual(r.scopes.len, again.scopes.len);
    var no_plan = r;
    no_plan.scopes = &.{ "openid", "email" };
    try std.testing.expect(!no_plan.planEnabled());
}

test "ChatGPT sign-in: loading needs plan usage and never refreshes a fresh token" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    try std.testing.expect(chatgpt.loadChatgptOAuth(io, std.testing.allocator, a, home, false, null) == null);
    try tmp.dir.createDir(io, ".graff", credential_store.private_dir);
    try tmp.dir.createDir(io, ".graff/credentials", credential_store.private_dir);
    const write = struct {
        fn record(d: std.Io.Dir, alloc: std.mem.Allocator, r: chatgpt.Record) !void {
            try credential_store.replaceFile(std.testing.io, d, ".graff/credentials/chatgpt-new.json", try chatgpt.serializeRecord(alloc, r, "now"), credential_store.private_file);
        }
    };
    var r = chatgpt.parseRecord(a, probe_record).?;
    try write.record(tmp.dir, a, r);
    // Far from expiry and not forced: the saved token, with no network call.
    try std.testing.expectEqualStrings("tok-1", chatgpt.loadChatgptOAuth(io, std.testing.allocator, a, home, false, null).?);
    // A 401 on a token that is no longer on disk adopts the one that is.
    try std.testing.expectEqualStrings("tok-1", chatgpt.loadChatgptOAuth(io, std.testing.allocator, a, home, true, "tok-0").?);
    // A 401 on the current token before earliest_refresh_at keeps it: OpenAI
    // would answer that refresh with invalid_grant.
    try std.testing.expectEqualStrings("tok-1", chatgpt.loadChatgptOAuth(io, std.testing.allocator, a, home, true, "tok-1").?);
    // Expired with nothing to refresh with: still the saved token, still offline.
    r.expires_at = 1;
    r.earliest_refresh_at = 0;
    r.refresh = "";
    try write.record(tmp.dir, a, r);
    try std.testing.expectEqualStrings("tok-1", chatgpt.loadChatgptOAuth(io, std.testing.allocator, a, home, false, null).?);
    // Signed in without plan usage: nothing to send requests with.
    r.scopes = &.{ "openid", "email" };
    try write.record(tmp.dir, a, r);
    try std.testing.expect(chatgpt.loadChatgptOAuth(io, std.testing.allocator, a, home, false, null) == null);
}

fn tmpHome(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".graff", credential_store.private_dir);
    try tmp.dir.createDir(io, ".graff/credentials", credential_store.private_dir);
    return buf[0..try tmp.dir.realPath(io, buf)];
}

fn saveIn(dir: std.Io.Dir, alloc: std.mem.Allocator, r: chatgpt.Record) !void {
    try credential_store.replaceFile(std.testing.io, dir, ".graff/credentials/chatgpt-new.json", try chatgpt.serializeRecord(alloc, r, "now"), credential_store.private_file);
}

test "ChatGPT sign-in: a refresh takes a lock a second graff would block on" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmpHome(&tmp, &buf);
    const held = chatgpt.lockRecord(io, a, home) orelse return error.NoRefreshLock;
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{chatgpt.recordPath(a, home)});
    // flock/NtLockFile are per open file description, so a second open
    // conflicts even inside one process, exactly as another graff would.
    try std.testing.expectError(error.WouldBlock, std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }));
    held.close(io);
    const next = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
    next.close(io);
}

test "ChatGPT sign-in: a refresh another graff already made is adopted, not repeated" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmpHome(&tmp, &buf);
    const before = chatgpt.parseRecord(a, probe_record).?; // what this process read: tok-1 / ref-1
    var rotated = before;
    rotated.access = "tok-2";
    rotated.refresh = "ref-2";
    try saveIn(tmp.dir, a, rotated);
    // The disk moved on while this process waited for the lock: its token is
    // adopted with no token request (tests have no network), and the
    // replaced ref-1 is never presented.
    try std.testing.expectEqualStrings("tok-2", chatgpt.refreshLocked(io, std.testing.allocator, a, home, before).?);
    // Signed out meanwhile: nothing to send.
    var signed_out = rotated;
    signed_out.access = "";
    signed_out.refresh = "";
    try saveIn(tmp.dir, a, signed_out);
    try std.testing.expect(chatgpt.refreshLocked(io, std.testing.allocator, a, home, before) == null);
}

test "ChatGPT sign-in: a sign-in saved before the move is adopted, never copied" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDir(io, ".openai", credential_store.private_dir);
    try tmp.dir.createDir(io, ".openai/credentials", credential_store.private_dir);
    try credential_store.replaceFile(io, tmp.dir, ".openai/credentials/graff-oauth.json", try chatgpt.serializeRecord(a, chatgpt.parseRecord(a, probe_record).?, "now"), credential_store.private_file);
    try tmp.dir.writeFile(io, .{ .sub_path = ".openai/credentials/graff-host-id", .data = host ++ "\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".openai/credentials/graff-oauth.json.lock", .data = "" });
    try std.testing.expect(chatgpt.onDisk(io, a, home)); // listing providers still sees it
    // The first read moves it into graff's directory: no sign-in, no network.
    try std.testing.expectEqualStrings("tok-1", chatgpt.loadChatgptOAuth(io, std.testing.allocator, a, home, false, null).?);
    try std.testing.expectEqualStrings(host ++ "\n", try tmp.dir.readFileAlloc(io, ".graff/credentials/chatgpt-new-host-id", a, .limited(128)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".openai", .{})); // emptied, so removed
    try std.testing.expect(chatgpt.onDisk(io, a, home));
    try std.testing.expectEqualStrings("tok-1", chatgpt.loadChatgptOAuth(io, std.testing.allocator, a, home, false, null).?);
    if (@import("builtin").os.tag == .windows) return;
    const dir = try tmp.dir.openDir(io, ".graff/credentials", .{});
    defer dir.close(io);
    try std.testing.expectEqual(@as(u32, 0o700), (try dir.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o600), (try dir.statFile(io, "chatgpt-new.json", .{})).permissions.toMode() & 0o777);
}

test "ChatGPT sign-in: a refused renewal is recorded; an unusable refresh token is cleared, the access token kept" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmpHome(&tmp, &buf);
    const r = chatgpt.parseRecord(a, probe_record).?;
    try saveIn(tmp.dir, a, r);
    // A transient code keeps the refresh token for a later try, but says why.
    chatgpt.recordRefreshFailure(io, a, home, r, "temporarily_unavailable", "try later");
    var saved = chatgpt.parseRecord(a, try std.Io.Dir.cwd().readFileAlloc(io, chatgpt.recordPath(a, home), a, .limited(64 * 1024))).?;
    try std.testing.expectEqualStrings("ref-1", saved.refresh);
    try std.testing.expect(std.mem.endsWith(u8, saved.refresh_error, " temporarily_unavailable: try later"));
    chatgpt.recordRefreshFailure(io, a, home, r, "invalid_grant", "");
    saved = chatgpt.parseRecord(a, try std.Io.Dir.cwd().readFileAlloc(io, chatgpt.recordPath(a, home), a, .limited(64 * 1024))).?;
    try std.testing.expectEqualStrings("", saved.refresh);
    try std.testing.expect(std.mem.endsWith(u8, saved.refresh_error, " invalid_grant: "));
    try std.testing.expectEqualStrings("tok-1", saved.access); // usable until it expires
    try std.testing.expectEqualStrings("oaiapp_x", saved.client_id); // the next sign-in skips registration
    try std.testing.expect(@import("oauth_helpers.zig").permanentRefreshFailure("refresh_token_reused"));
    try std.testing.expect(@import("oauth_helpers.zig").permanentRefreshFailure("invalid_refresh_token"));
    try std.testing.expect(!@import("oauth_helpers.zig").permanentRefreshFailure("server_error"));
}
