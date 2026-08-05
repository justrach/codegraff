//! Codex credential IO, callback parsing and the common browser helpers used by
//! the OAuth login flows — plus the silent codex token refresh the request loop
//! runs mid-turn (#402), which must stay off stdout.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const strFieldObj = @import("util.zig").strFieldObj;

// Codex / ChatGPT OAuth client — the same client + endpoints the Codex CLI
// uses. Owned here (not in oauth.zig) so the silent refresh below can reach
// them without importing back into its own importer.
pub const codex_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const codex_token_url = "https://auth.openai.com/oauth/token";
pub const codex_scope_enc = "openid%20profile%20email%20offline_access";

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

pub fn codexAuthPath(arena: Allocator, codex_home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/auth.json", .{codex_home});
}

pub fn writeCodexAuth(io: Io, arena: Allocator, home: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) !void {
    const dir = try std.fmt.allocPrint(arena, "{s}/.codex", .{home});
    return writeCodexAuthAt(io, arena, dir, id_token, access, refresh, account);
}

/// Same, against an explicit CODEX_HOME. The silent refresh must write back to
/// the file it read: startup resolves $CODEX_HOME (startup.zig), while the login
/// flows always target ~/.codex, and refreshing the wrong file would either
/// no-op or clobber an unrelated credential.
pub fn writeCodexAuthAt(io: Io, arena: Allocator, codex_home: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) !void {
    const path = try codexAuthPath(arena, codex_home);
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
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(aw.writer.buffered());
    try writer.interface.flush();
}

/// POST a urlencoded form body to an OAuth token endpoint; return the parsed
/// JSON object. Shared by the interactive login flows and by the silent
/// mid-turn refresh below (#402), which cannot use codexLogin: that one prints
/// progress to stdout and would corrupt a live stream.
pub fn oauthFormPost(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, body: []const u8) !std.json.ObjectMap {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    });
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

/// #245: `force` means "the access token I was holding just failed with a 401".
/// The refresh mutex serializes concurrent refreshers but does NOT dedupe them,
/// so a fleet of subagents that all 401 on the same expired token would each
/// re-mint in turn. Kimi (and xAI) rotate refresh tokens and INVALIDATE the
/// superseded access token, so refresher N+1 kills the token refresher N just
/// adopted — the 401 cascade that wipes out a whole fleet.
///
/// If the on-disk token already differs from the one that failed, the 401 was
/// about the OLD token and somebody else has already done the work: adopt theirs
/// instead of minting another. `stale == null` keeps the previous behaviour for
/// callers that cannot say which token failed.
pub fn supersededToken(force: bool, on_disk: []const u8, stale: ?[]const u8) bool {
    if (!force) return false;
    const failed = stale orelse return false;
    return !std.mem.eql(u8, on_disk, failed);
}

/// The stored Codex credential, including the refresh_token that
/// oauth.loadCodexAuthFrom drops.
pub const StoredCodexAuth = struct {
    access: []const u8,
    refresh: []const u8 = "",
    id_token: []const u8 = "",
    account: []const u8 = "",
};

/// Read <codex_home>/auth.json in full. Null when missing/unparseable/empty,
/// i.e. not logged in.
pub fn readCodexAuth(io: Io, arena: Allocator, codex_home: []const u8) ?StoredCodexAuth {
    const path = codexAuthPath(arena, codex_home) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const tokens = v.object.get("tokens") orelse return null;
    if (tokens != .object) return null;
    const access = strFieldObj(tokens.object, "access_token") orelse return null;
    if (access.len == 0) return null;
    return .{
        .access = access,
        .refresh = strFieldObj(tokens.object, "refresh_token") orelse "",
        .id_token = strFieldObj(tokens.object, "id_token") orelse "",
        .account = strFieldObj(tokens.object, "account_id") orelse "",
    };
}

/// A refresh grant that this refresh_token can never satisfy, however often it
/// is retried — as opposed to a transient 5xx/offline failure, which must stay
/// retryable. codex-rs caches exactly these for the current auth snapshot so a
/// dead credential stops costing a round trip per request.
pub fn permanentRefreshFailure(code: []const u8) bool {
    const permanent = [_][]const u8{ "invalid_grant", "invalid_client", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated" };
    for (permanent) |p| if (std.mem.eql(u8, code, p)) return true;
    return false;
}

/// Set to the Wyhash of a refresh_token whose grant failed permanently. Only
/// ever read/written under oauth.refreshOAuthKey's mutex, and a lost race costs
/// one extra POST, never a wrong credential.
var dead_refresh_token: u64 = 0;

/// #402: the codex sibling of oauth.loadKimiOAuth — the current ChatGPT access
/// token for `codex_home`, refreshed in place when `force` (i.e. the token we
/// were holding just 401'd). ChatGPT access tokens DO expire; treating them as
/// long-lived is what left an expired session unrecoverable.
///
/// Order matters and mirrors codex-rs's UnauthorizedRecovery. STEP 1: re-read
/// auth.json and adopt whatever is on disk if it already differs from the token
/// that failed — an in-session `/login`, a second graff, or the real Codex CLI
/// has already done the work, and re-minting would rotate-kill their token.
/// STEP 2, only then, spend the refresh_token. On a failed grant it returns the
/// token it read, so the caller (which compares against the stale one) gives up
/// instead of resending forever.
pub fn loadCodexOAuth(io: Io, gpa: Allocator, arena: Allocator, codex_home: []const u8, force: bool, stale: ?[]const u8) ?[]const u8 {
    const auth = readCodexAuth(io, arena, codex_home) orelse return null;
    if (supersededToken(force, auth.access, stale)) return auth.access;
    if (!force or auth.refresh.len == 0) return auth.access;
    const refresh_id = std.hash.Wyhash.hash(0, auth.refresh);
    if (refresh_id == dead_refresh_token) return auth.access; // known dead: no round trip
    const body = std.fmt.allocPrint(arena, "grant_type=refresh_token&client_id={s}&refresh_token={s}&scope={s}", .{ codex_client_id, auth.refresh, codex_scope_enc }) catch return auth.access;
    const resp = oauthFormPost(io, gpa, arena, codex_token_url, body) catch return auth.access; // transient: retryable, do not cache
    if (resp.get("error")) |e| {
        if (permanentRefreshFailure(if (e == .string) e.string else "")) dead_refresh_token = refresh_id;
        return auth.access;
    }
    const access = strFieldObj(resp, "access_token") orelse return auth.access;
    if (access.len == 0) return auth.access;
    const id_token = strFieldObj(resp, "id_token") orelse auth.id_token;
    const refresh = strFieldObj(resp, "refresh_token") orelse auth.refresh;
    var account = if (id_token.len > 0) accountFromIdToken(arena, id_token) else "";
    if (account.len == 0) account = auth.account; // a rotated grant may omit id_token
    writeCodexAuthAt(io, arena, codex_home, id_token, access, refresh, account) catch {};
    return access;
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

test "#402: loadCodexOAuth adopts the token /login wrote instead of minting a new one" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    // Not logged in: nothing to adopt or refresh, the caller keeps its own key.
    try std.testing.expect(loadCodexOAuth(io, std.testing.allocator, arena, codex_home, false, null) == null);

    // Proactive read (force=false): the on-disk token, no grant spent.
    try writeCodexAuthAt(io, arena, codex_home, "", "tok-expired", "refresh-1", "acct-1");
    try std.testing.expectEqualStrings("tok-expired", loadCodexOAuth(io, std.testing.allocator, arena, codex_home, false, null).?);

    // The #402 case: `/login` (or a second graff, or the real Codex CLI) rewrote
    // auth.json while this session still held the old token. Recovering from that
    // 401 must adopt what is on disk — no network call, and no #245 rotate-kill of
    // the credential the other writer just minted.
    try writeCodexAuthAt(io, arena, codex_home, "", "tok-fresh", "refresh-2", "acct-2");
    try std.testing.expectEqualStrings("tok-fresh", loadCodexOAuth(io, std.testing.allocator, arena, codex_home, true, "tok-expired").?);

    // Same token still on disk and no refresh_token to spend: hand back what was
    // read so the caller can see the refresh did not help and stop.
    try writeCodexAuthAt(io, arena, codex_home, "", "tok-fresh", "", "acct-2");
    try std.testing.expectEqualStrings("tok-fresh", loadCodexOAuth(io, std.testing.allocator, arena, codex_home, true, "tok-fresh").?);

    // readCodexAuth surfaces the refresh_token that oauth.loadCodexAuthFrom drops.
    try writeCodexAuthAt(io, arena, codex_home, "", "tok-fresh", "refresh-3", "acct-9");
    const stored = readCodexAuth(io, arena, codex_home).?;
    try std.testing.expectEqualStrings("refresh-3", stored.refresh);
    try std.testing.expectEqualStrings("acct-9", stored.account);
}

test "#402: permanentRefreshFailure separates a dead refresh_token from a retryable blip" {
    // These can never succeed on a retry — cache them so a dead credential stops
    // costing a token-endpoint round trip on every request.
    try std.testing.expect(permanentRefreshFailure("invalid_grant"));
    try std.testing.expect(permanentRefreshFailure("refresh_token_expired"));
    try std.testing.expect(permanentRefreshFailure("refresh_token_reused"));
    try std.testing.expect(permanentRefreshFailure("refresh_token_invalidated"));
    // Transient / unknown: must stay retryable, or one bad minute would wedge the
    // credential for the rest of the session.
    try std.testing.expect(!permanentRefreshFailure("server_error"));
    try std.testing.expect(!permanentRefreshFailure("temporarily_unavailable"));
    try std.testing.expect(!permanentRefreshFailure("slow_down"));
    try std.testing.expect(!permanentRefreshFailure(""));
}

test "#402: writeCodexAuth targets ~/.codex while writeCodexAuthAt honours CODEX_HOME" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    // A custom CODEX_HOME must not be redirected to ~/.codex: startup reads
    // $CODEX_HOME, so refreshing the wrong file would silently no-op.
    const custom = try std.fmt.allocPrint(arena, "{s}/custom", .{base});
    try Io.Dir.cwd().createDirPath(io, custom);
    try writeCodexAuthAt(io, arena, custom, "", "at-tok", "r", "a");
    try std.testing.expectEqualStrings("at-tok", readCodexAuth(io, arena, custom).?.access);

    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/.codex", .{base}));
    try writeCodexAuth(io, arena, base, "", "home-tok", "r", "a");
    try std.testing.expectEqualStrings("home-tok", readCodexAuth(io, arena, try std.fmt.allocPrint(arena, "{s}/.codex", .{base})).?.access);
    try std.testing.expectEqualStrings("at-tok", readCodexAuth(io, arena, custom).?.access); // untouched
}

pub fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "open", url }
    else
        &.{ "xdg-open", url };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}
