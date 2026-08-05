//! Codex credential IO, callback parsing and the common browser helpers used by
//! the OAuth login flows — plus the silent codex token refresh the request loop
//! runs mid-turn (#402), which must stay off stdout.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const credential_store = @import("credential_store.zig");
const strFieldObj = @import("util.zig").strFieldObj;
const unixMs = @import("util.zig").unixMs;

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

/// THE codex credential directory for this process: `$CODEX_HOME`, or
/// `<HOME>/.codex` when it is unset. Pinned once at startup — before any
/// subcommand or session can log in — and read by every reader and writer of
/// auth.json below.
///
/// #402: there used to be two answers. The mid-turn refresh resolved
/// $CODEX_HOME off the ROOT's model catalog while every login flow hardcoded
/// ~/.codex, so with CODEX_HOME set a successful `/login` was silently REVERTED
/// by the next request's proactive re-read (the reported symptom), and a
/// subagent — which carries neither a catalog nor a `home` — resolved neither
/// and got no recovery at all. One resolver, one file, catalog or not.
pub var g_codex_home: []const u8 = "";

/// Pin it. `$CODEX_HOME` and `$HOME` are taken by value rather than as an
/// environ map so a test can drive the precedence with plain strings.
pub fn initCodexHome(arena: Allocator, env_codex_home: ?[]const u8, home: ?[]const u8) void {
    if (env_codex_home) |value| if (value.len > 0) {
        g_codex_home = value;
        return;
    };
    const h = home orelse return;
    if (h.len == 0) return;
    g_codex_home = std.fmt.allocPrint(arena, "{s}/.codex", .{h}) catch "";
}

/// Where auth.json lives. `home` is only the fallback for callers that can run
/// before startup pinned the global (and for tests); null when neither is
/// known, which every caller reads as "not logged in".
pub fn codexHomeDir(arena: Allocator, home: []const u8) ?[]const u8 {
    if (g_codex_home.len > 0) return g_codex_home;
    if (home.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/.codex", .{home}) catch null;
}

pub fn codexAuthPath(arena: Allocator, codex_home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/auth.json", .{codex_home});
}

/// Write the credential to THE codex auth.json (codexHomeDir). `home` is its
/// pre-startup fallback only — never a second location.
pub fn writeCodexAuth(io: Io, arena: Allocator, home: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) !void {
    const dir = codexHomeDir(arena, home) orelse return error.NoCodexHome;
    return writeCodexAuthAt(io, arena, dir, id_token, access, refresh, account);
}

/// `last_refresh` in the shape the real codex CLI stores it (serde
/// `Option<DateTime<Utc>>`). The literal "harness-login" this used to write is
/// not a timestamp — tolerable in a file only `graff login` touched, not in one
/// a silent mid-turn refresh now rewrites under the other CLI's feet.
fn rfc3339Utc(buf: *[24]u8, unix_ms: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, @divFloor(unix_ms, 1000))) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      @as(u16, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

/// Write the ChatGPT credential into `<codex_home>/auth.json`, PRESERVING every
/// field this harness does not own.
///
/// #402: auth.json is co-owned with the real `codex` CLI, whose AuthDotJson also
/// carries openai_api_key / agent_identity / personal_access_token /
/// bedrock_api_key. The previous write emitted a fixed four-field object and
/// destroyed the rest — survivable while only an explicit `graff login` ran it,
/// not now that a silent mid-turn refresh fires it unattended. So:
/// read-modify-write replacing ONLY the token fields, and 0600 like every other
/// credential this repo writes (oauth.writeKimiAuth).
pub fn writeCodexAuthAt(io: Io, arena: Allocator, codex_home: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) !void {
    const path = try codexAuthPath(arena, codex_home);
    var object: std.json.ObjectMap = .empty;
    var tokens: std.json.ObjectMap = .empty;
    if (readCodexJson(io, arena, path)) |existing| {
        object = existing;
        if (existing.get("tokens")) |t| if (t == .object) {
            tokens = t.object;
        };
    }
    try tokens.put(arena, "id_token", .{ .string = id_token });
    try tokens.put(arena, "access_token", .{ .string = access });
    try tokens.put(arena, "refresh_token", .{ .string = refresh });
    try tokens.put(arena, "account_id", .{ .string = account });
    var stamp: [24]u8 = undefined;
    try object.put(arena, "auth_mode", .{ .string = "chatgpt" });
    try object.put(arena, "tokens", .{ .object = tokens });
    try object.put(arena, "last_refresh", .{ .string = rfc3339Utc(&stamp, unixMs(io)) });
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(Value{ .object = object });
    Io.Dir.cwd().createDirPath(io, codex_home) catch {}; // a freshly-pointed $CODEX_HOME
    // 0600, staged + renamed by the shared credential writer: this holds the
    // id/access/refresh triple, is co-owned with the openai/codex CLI (which
    // writes it 0600 itself), and a silent mid-turn refresh must never leave it
    // observable half-written — a torn read here would be re-PERSISTED by our
    // own next read-modify-write.
    try credential_store.replaceFile(io, Io.Dir.cwd(), path, aw.writer.buffered(), credential_store.private_file);
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

/// The parsed top-level object of an auth.json, or null when it is missing or
/// unparseable. Shared by the reader and by the read-modify-write above, so the
/// fields graff does not own survive a refresh.
fn readCodexJson(io: Io, arena: Allocator, path: []const u8) ?std.json.ObjectMap {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    return if (v == .object) v.object else null;
}

/// Read <codex_home>/auth.json in full. Null when missing/unparseable/empty,
/// i.e. not logged in.
pub fn readCodexAuth(io: Io, arena: Allocator, codex_home: []const u8) ?StoredCodexAuth {
    const path = codexAuthPath(arena, codex_home) catch return null;
    const object = readCodexJson(io, arena, path) orelse return null;
    const tokens = object.get("tokens") orelse return null;
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

/// A credential the request loop may adopt: the bearer AND the ChatGPT account
/// id it belongs to. They travel together because `account` is the
/// chatgpt-account-id header on every codex request (http_headers.zig,
/// agent_ws.zig) — a new bearer paired with the previous account's id just
/// 401/403s again. Empty `account` means "unchanged / not applicable" (kimi, xai).
pub const FreshKey = struct { key: []const u8, account: []const u8 = "" };

/// Set when a refreshed credential could NOT be written back, so the caller can
/// warn. OpenAI rotates the refresh_token on the grant, which kills the old one
/// server-side the moment the POST succeeds: swallowing this write failure would
/// leave only a dead credential on disk and log the user out at next start with
/// no diagnostic (codex-rs propagates it as RefreshTokenError). `@errorName` is
/// static, so the slice outlives every arena. Written under refreshOAuthKey's
/// mutex; a concurrent reader can at worst attribute one warning to the wrong
/// agent, never miss that something failed.
pub var persist_error: ?[]const u8 = null;

pub fn takePersistError() ?[]const u8 {
    defer persist_error = null;
    return persist_error;
}

/// Persist a refreshed credential, retrying once. The failures that reach here
/// (a concurrent writer's truncate, a transient EIO) are usually not sticky;
/// a still-failing write is recorded for the caller to surface.
fn persistRefreshed(io: Io, arena: Allocator, codex_home: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) void {
    writeCodexAuthAt(io, arena, codex_home, id_token, access, refresh, account) catch {
        writeCodexAuthAt(io, arena, codex_home, id_token, access, refresh, account) catch |err| {
            persist_error = @errorName(err);
        };
    };
}

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
///
/// `expect_account` is codex-rs's `reload_if_account_id_matches`: a credential
/// minted for a DIFFERENT ChatGPT account is never adopted (null = give up,
/// which the caller surfaces as the original auth error) rather than silently
/// paired with this session's account header.
pub fn loadCodexOAuth(io: Io, gpa: Allocator, arena: Allocator, codex_home: []const u8, force: bool, stale: ?[]const u8, expect_account: []const u8) ?FreshKey {
    const auth = readCodexAuth(io, arena, codex_home) orelse return null;
    if (expect_account.len > 0 and auth.account.len > 0 and !std.mem.eql(u8, expect_account, auth.account)) return null;
    const on_disk: FreshKey = .{ .key = auth.access, .account = auth.account };
    if (supersededToken(force, auth.access, stale)) return on_disk;
    if (!force or auth.refresh.len == 0) return on_disk;
    const refresh_id = std.hash.Wyhash.hash(0, auth.refresh);
    if (refresh_id == dead_refresh_token) return on_disk; // known dead: no round trip
    const body = std.fmt.allocPrint(arena, "grant_type=refresh_token&client_id={s}&refresh_token={s}&scope={s}", .{ codex_client_id, auth.refresh, codex_scope_enc }) catch return on_disk;
    const resp = oauthFormPost(io, gpa, arena, codex_token_url, body) catch return on_disk; // transient: retryable, do not cache
    if (resp.get("error")) |e| {
        if (permanentRefreshFailure(if (e == .string) e.string else "")) dead_refresh_token = refresh_id;
        return on_disk;
    }
    const access = strFieldObj(resp, "access_token") orelse return on_disk;
    if (access.len == 0) return on_disk;
    const id_token = strFieldObj(resp, "id_token") orelse auth.id_token;
    const refresh = strFieldObj(resp, "refresh_token") orelse auth.refresh;
    var account = if (id_token.len > 0) accountFromIdToken(arena, id_token) else "";
    if (account.len == 0) account = auth.account; // a rotated grant may omit id_token
    persistRefreshed(io, arena, codex_home, id_token, access, refresh, account);
    return .{ .key = access, .account = account };
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
    try std.testing.expect(loadCodexOAuth(io, std.testing.allocator, arena, codex_home, false, null, "") == null);

    // Proactive read (force=false): the on-disk token, no grant spent.
    try writeCodexAuthAt(io, arena, codex_home, "", "tok-expired", "refresh-1", "acct-1");
    try std.testing.expectEqualStrings("tok-expired", loadCodexOAuth(io, std.testing.allocator, arena, codex_home, false, null, "acct-1").?.key);

    // The #402 case: `/login` (or a second graff, or the real Codex CLI) rewrote
    // auth.json while this session still held the old token. Recovering from that
    // 401 must adopt what is on disk — no network call, and no #245 rotate-kill of
    // the credential the other writer just minted. The account id comes WITH it:
    // it is the chatgpt-account-id header, and a new bearer under the old id 403s.
    try writeCodexAuthAt(io, arena, codex_home, "", "tok-fresh", "refresh-2", "acct-1");
    const adopted = loadCodexOAuth(io, std.testing.allocator, arena, codex_home, true, "tok-expired", "acct-1").?;
    try std.testing.expectEqualStrings("tok-fresh", adopted.key);
    try std.testing.expectEqualStrings("acct-1", adopted.account);

    // Same token still on disk and no refresh_token to spend: hand back what was
    // read so the caller can see the refresh did not help and stop.
    try writeCodexAuthAt(io, arena, codex_home, "", "tok-fresh", "", "acct-1");
    try std.testing.expectEqualStrings("tok-fresh", loadCodexOAuth(io, std.testing.allocator, arena, codex_home, true, "tok-fresh", "acct-1").?.key);

    // codex-rs's reload_if_account_id_matches: a credential minted for ANOTHER
    // ChatGPT account is never adopted. Pairing its bearer with this session's
    // account header just 401/403s, with the one recovery attempt already spent.
    try std.testing.expect(loadCodexOAuth(io, std.testing.allocator, arena, codex_home, true, "tok-expired", "acct-other") == null);
    try std.testing.expect(loadCodexOAuth(io, std.testing.allocator, arena, codex_home, false, null, "acct-other") == null);

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

    const saved = g_codex_home;
    defer g_codex_home = saved;

    // CODEX_HOME unset → ~/.codex, for writer and reader alike.
    g_codex_home = "";
    initCodexHome(arena, null, home);
    try std.testing.expectEqualStrings(home_codex, codexHomeDir(arena, home).?);
    try writeCodexAuth(io, arena, home, "", "home-tok", "r", "a");
    try std.testing.expectEqualStrings("home-tok", readCodexAuth(io, arena, codexHomeDir(arena, home).?).?.access);

    // CODEX_HOME set → BOTH move to it. This is the #402 split-brain: the login
    // writer used to stay on ~/.codex while the refresh read $CODEX_HOME, so the
    // next request's proactive read reverted a login that had just succeeded.
    g_codex_home = "";
    initCodexHome(arena, custom, home);
    try std.testing.expectEqualStrings(custom, codexHomeDir(arena, home).?);
    try writeCodexAuth(io, arena, home, "", "env-tok", "r", "a");
    try std.testing.expectEqualStrings("env-tok", readCodexAuth(io, arena, codexHomeDir(arena, home).?).?.access);
    try std.testing.expectEqualStrings("home-tok", readCodexAuth(io, arena, home_codex).?.access); // the other file is untouched

    // An empty $CODEX_HOME is not a location; and with neither, there is nothing
    // to read rather than a path built from "".
    g_codex_home = "";
    initCodexHome(arena, "", home);
    try std.testing.expectEqualStrings(home_codex, g_codex_home);
    g_codex_home = "";
    try std.testing.expect(codexHomeDir(arena, "") == null);
}

test "#402: a refresh that cannot be persisted is reported, not swallowed" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    // A "codex home" whose parent is a regular file: neither the mkdir nor the
    // create can succeed, however often they are retried.
    const blocker = try std.fmt.allocPrint(arena, "{s}/not-a-dir", .{base});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = blocker, .data = "x" });
    persist_error = null;
    persistRefreshed(io, arena, try std.fmt.allocPrint(arena, "{s}/codex", .{blocker}), "id", "new", "rotated", "acct");
    // The grant already invalidated the OLD refresh_token server-side, so losing
    // this write silently would log the user out at next start with no clue why.
    try std.testing.expect(takePersistError() != null);
    try std.testing.expect(takePersistError() == null); // drained: warned once, not every request

    // A writable destination still persists silently.
    persistRefreshed(io, arena, base, "id", "new", "rotated", "acct");
    try std.testing.expect(takePersistError() == null);
    try std.testing.expectEqualStrings("new", readCodexAuth(io, arena, base).?.access);
}

test "#402: a refresh write preserves the fields the codex CLI owns" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    // auth.json as the real codex CLI writes it: fields graff knows nothing
    // about, at the top level AND inside tokens.
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try codexAuthPath(arena, codex_home),
        .data =
        \\{"OPENAI_API_KEY":"sk-user-key","auth_mode":"chatgpt","agent_identity":"ai","tokens":{"access_token":"old","refresh_token":"r0","account_id":"acct-1","personal_access_token":"pat"},"last_refresh":"2026-01-02T03:04:05Z"}
        ,
    });

    // A silent mid-turn refresh now rewrites this file unattended. Anything it
    // does not own must survive, or graff quietly destroys the user's other
    // codex credentials on the first 401 of a session.
    try writeCodexAuthAt(io, arena, codex_home, "id2", "new", "r1", "acct-1");
    const raw = try Io.Dir.cwd().readFileAlloc(io, try codexAuthPath(arena, codex_home), arena, .limited(64 * 1024));
    const v = try std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always });
    try std.testing.expectEqualStrings("sk-user-key", strFieldObj(v.object, "OPENAI_API_KEY").?);
    try std.testing.expectEqualStrings("ai", strFieldObj(v.object, "agent_identity").?);
    const tokens = v.object.get("tokens").?.object;
    try std.testing.expectEqualStrings("pat", strFieldObj(tokens, "personal_access_token").?);
    try std.testing.expectEqualStrings("new", strFieldObj(tokens, "access_token").?);
    try std.testing.expectEqualStrings("r1", strFieldObj(tokens, "refresh_token").?);
    // last_refresh is what codex's own serde expects there (DateTime<Utc>), not
    // the old literal "harness-login", which would fail ITS parse of the file.
    const stamp = strFieldObj(v.object, "last_refresh").?;
    try std.testing.expectEqual(@as(usize, 20), stamp.len);
    try std.testing.expect(stamp[10] == 'T' and stamp[19] == 'Z');

    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("2026-08-05T12:34:56Z", rfc3339Utc(&buf, 1_785_933_296_000));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", rfc3339Utc(&buf, 0));

    // The write stages + renames, so a reader never sees a half-written
    // credential — and the staging file is never left next to it.
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

pub fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "open", url }
    else
        &.{ "xdg-open", url };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}
