//! Login / credential flows for the three OAuth-style providers — Codex
//! (ChatGPT PKCE), Kimi (device-code), and Codegraff (device-code) — plus the
//! on-disk credential loaders each writes/reads. Split out of main.zig (#123).
//!
//! Every entry point takes (io, gpa, arena, home) and reaches no Agent/global
//! state, so the coupling back to main is tiny: ansi for the palette, util for
//! the JSON getters, and a few shared consts (unixMs, the
//! codegraff gateway base) back-imported from main.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const helpers = @import("oauth_helpers.zig");
const b64url = helpers.b64url;
const accountFromIdToken = helpers.accountFromIdToken;
const writeCodexAuth = helpers.writeCodexAuth;
const codex_login_page_html = helpers.codex_login_page_html;
const queryParam = helpers.queryParam;
const openBrowser = helpers.openBrowser;

const ansi = @import("ansi.zig");
const style = &ansi.style;
const Style = ansi.Style;

const util = @import("util.zig");
const strFieldObj = util.strFieldObj;

const unixMs = util.unixMs;
const kimi_catalog = @import("kimi_catalog.zig");
const pricing = @import("pricing.zig");
const codegraff = @import("oauth_codegraff.zig");
const credential_store = @import("credential_store.zig");

pub const CodexAuth = struct { token: []const u8, account: []const u8 };

/// Read the Codex CLI's ChatGPT OAuth credentials from <codex_home>/auth.json.
/// Returns the access token + account id (for the chatgpt-account-id header),
/// or null if the file is missing/unparseable (i.e. not logged in).
pub fn loadCodexAuthFrom(io: Io, arena: Allocator, codex_home: []const u8) ?CodexAuth {
    const path = std.fmt.allocPrint(arena, "{s}/auth.json", .{codex_home}) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const tokens = v.object.get("tokens") orelse return null;
    if (tokens != .object) return null;
    const token = if (tokens.object.get("access_token")) |t| (if (t == .string) t.string else return null) else return null;
    if (token.len == 0) return null;
    const account = if (tokens.object.get("account_id")) |a| (if (a == .string) a.string else "") else "";
    return .{ .token = token, .account = account };
}

/// Default-home compatibility wrapper used by login flows that always write
/// ~/.codex/auth.json. Startup and `graff models` use loadCodexAuthFrom so a
/// user-supplied CODEX_HOME controls both credentials and the native catalog.
pub fn loadCodexAuth(io: Io, arena: Allocator, home: []const u8) ?CodexAuth {
    const codex_home = std.fmt.allocPrint(arena, "{s}/.codex", .{home}) catch return null;
    return loadCodexAuthFrom(io, arena, codex_home);
}

// #148: how long before an OAuth access token's expiry to proactively refresh
// it — wider than the old 60s so a mid-session refresh has headroom before a
// turn's request would otherwise cross the expiry and 401. kimi-code uses the
// same "ensureFresh near expiry + force-refresh on 401" shape.
const oauth_refresh_margin_s: i64 = 300;
// Serializes concurrent token refreshes (parallel subagents share the on-disk
// token) so they don't race the single-use refresh_token.
var oauth_refresh_mutex: Io.Mutex = .init;

// Codex / ChatGPT OAuth (PKCE) — same client + endpoints the Codex CLI uses
// (verified from the live id_token: aud/client_id app_EMoamEEZ…, iss
// auth.openai.com). `harness login` runs the browser flow; `harness login
// --refresh` refreshes the stored token (no browser).
const oauth_authorize_url = "https://auth.openai.com/oauth/authorize";
const oauth_token_url = "https://auth.openai.com/oauth/token";
const codex_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const codex_redirect = "http://localhost:1455/auth/callback";
const codex_redirect_enc = "http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback";
const oauth_scope_enc = "openid%20profile%20email%20offline_access";

/// POST a form body to the OAuth token endpoint; return the parsed JSON object.
fn oauthTokenPost(io: Io, gpa: Allocator, arena: Allocator, body: []const u8) !std.json.ObjectMap {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    _ = try client.fetch(.{
        .location = .{ .url = oauth_token_url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    });
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

/// `harness login [--refresh]`: the ChatGPT/Codex OAuth flow. Fresh login runs
/// PKCE (open browser → localhost:1455 callback → code→token exchange); refresh
/// uses the stored refresh_token. Either way writes ~/.codex/auth.json.
pub fn codexLogin(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, refresh_only: bool) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    var body: []const u8 = undefined;
    if (refresh_only) {
        const path = try std.fmt.allocPrint(arena, "{s}/.codex/auth.json", .{home});
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch {
            try out.print("not logged in (no {s}) — run `graff login` first\n", .{path});
            try out.flush();
            return;
        };
        const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return error.BadOAuthResponse;
        const refresh = blk: {
            if (v == .object) if (v.object.get("tokens")) |t| if (t == .object)
                if (t.object.get("refresh_token")) |r| if (r == .string) break :blk r.string;
            try out.writeAll("no refresh_token in ~/.codex/auth.json\n");
            try out.flush();
            return;
        };
        body = try std.fmt.allocPrint(arena, "grant_type=refresh_token&client_id={s}&refresh_token={s}&scope={s}", .{ codex_client_id, refresh, oauth_scope_enc });
        try out.writeAll("refreshing Codex token…\n");
        try out.flush();
    } else {
        var vbytes: [48]u8 = undefined;
        io.random(&vbytes);
        const verifier = b64url(arena, &vbytes);
        var ch: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &ch, .{});
        const challenge = b64url(arena, &ch);
        var sbytes: [16]u8 = undefined;
        io.random(&sbytes);
        const state = b64url(arena, &sbytes);

        const url = try std.fmt.allocPrint(arena, "{s}?response_type=code&client_id={s}&redirect_uri={s}&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}&id_token_add_organizations=true&codex_cli_simplified_flow=true", .{ oauth_authorize_url, codex_client_id, codex_redirect_enc, oauth_scope_enc, challenge, state });

        // Bind the callback port BEFORE opening the browser, so the redirect
        // can't arrive before we're listening.
        var addr = std.Io.net.IpAddress.parseLiteral("127.0.0.1:1455") catch return error.BadOAuthResponse;
        var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
        defer server.deinit(io);

        try out.print("\nOpen this URL to authorize (browser should open automatically):\n\n{s}\n\nwaiting for the callback on {s} …\n", .{ url, codex_redirect });
        try out.flush();
        openBrowser(io, url);

        const stream = try server.accept(io);
        defer stream.close(io);

        var rbuf: [16 * 1024]u8 = undefined;
        var sr = std.Io.net.Stream.Reader.init(stream, io, &rbuf);
        const req_line = (sr.interface.takeDelimiter('\n') catch null) orelse return error.BadOAuthResponse;

        // Branded, dark-mode-aware confirmation card (charset utf-8 so the ✓/◆
        // render) so the callback tab shows a real "you're all set" page, not a
        // bare line — then we read the code out of the same request below.
        const page = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n" ++ codex_login_page_html;
        var wbuf: [4096]u8 = undefined;
        var sw = std.Io.net.Stream.Writer.init(stream, io, &wbuf);
        sw.interface.writeAll(page) catch {};
        sw.interface.flush() catch {};

        const code = queryParam(req_line, "code") orelse {
            try out.writeAll("✗ no authorization code in callback\n");
            try out.flush();
            return;
        };
        const got_state = queryParam(req_line, "state") orelse "";
        if (!std.mem.eql(u8, got_state, state)) {
            try out.writeAll("✗ state mismatch — possible CSRF, aborting\n");
            try out.flush();
            return;
        }
        body = try std.fmt.allocPrint(arena, "grant_type=authorization_code&client_id={s}&code={s}&redirect_uri={s}&code_verifier={s}", .{ codex_client_id, code, codex_redirect_enc, verifier });
    }

    const resp = oauthTokenPost(io, gpa, arena, body) catch |err| {
        try out.print("✗ token exchange failed: {t}\n", .{err});
        try out.flush();
        return;
    };
    if (resp.get("error")) |e| {
        const msg = if (e == .string) e.string else "unknown";
        const desc = if (resp.get("error_description")) |d| (if (d == .string) d.string else "") else "";
        try out.print("✗ OAuth error: {s} {s}\n", .{ msg, desc });
        try out.flush();
        return;
    }
    const access = strFieldObj(resp, "access_token") orelse return error.BadOAuthResponse;
    const id_token = strFieldObj(resp, "id_token") orelse "";
    const refresh = strFieldObj(resp, "refresh_token") orelse "";
    const account = accountFromIdToken(arena, id_token);
    try writeCodexAuth(io, arena, home, id_token, access, refresh, account);
    try out.print("✓ logged into Codex (account {s}…) — wrote ~/.codex/auth.json. /model codex\n", .{account[0..@min(account.len, 8)]});
    try out.flush();
}

// Kimi Code OAuth — device-code flow, same client + endpoints the Kimi CLI
// uses (auth.kimi.com). `graff login kimi` runs the flow and writes the token
// to ~/.kimi/credentials/graff-oauth.json; loadKimiOAuth reads it at startup
// and refreshes in place when near expiry.
const kimi_oauth_host = "https://auth.kimi.com";
const kimi_device_auth_url = kimi_oauth_host ++ "/api/oauth/device_authorization";
const kimi_token_url = kimi_oauth_host ++ "/api/oauth/token";
const kimi_client_id = "17e5f671-d194-4dfb-9706-5516cb48c098";

/// POST a form body to a Kimi OAuth endpoint; return the parsed JSON object.
fn kimiOAuthPost(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, url: []const u8, body: []const u8) !std.json.ObjectMap {
    kimi_catalog.initIdentity(io, arena, home);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    var identity: [6]std.http.Header = undefined;
    _ = kimi_catalog.identityHeaders(&identity);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = kimi_catalog.user_agent },
        },
        .extra_headers = &identity,
    });
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

fn kimiAuthPath(arena: Allocator, home: []const u8) []const u8 {
    return credential_store.oauthPath(arena, home, ".kimi");
}

fn writeKimiAuth(io: Io, arena: Allocator, home: []const u8, access: []const u8, refresh: []const u8, expires_at: i64) !void {
    return credential_store.writeOAuth(io, arena, home, ".kimi", access, refresh, expires_at);
}

/// `graff login kimi`: Kimi Code device-code OAuth. Prints a verification URL +
/// user code, opens the browser, polls until the user authorizes, then stores
/// the access/refresh token.
pub fn kimiLogin(io: Io, gpa: Allocator, arena: Allocator, home: []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const da_body = try std.fmt.allocPrint(arena, "client_id={s}", .{kimi_client_id});
    const da = kimiOAuthPost(io, gpa, arena, home, kimi_device_auth_url, da_body) catch |err| {
        try out.print("✗ Kimi device authorization failed: {t}\n", .{err});
        try out.flush();
        return;
    };
    if (da.get("error")) |e| {
        try out.print("✗ {s}\n", .{if (e == .string) e.string else "device authorization error"});
        try out.flush();
        return;
    }
    const device_code = strFieldObj(da, "device_code") orelse return error.BadOAuthResponse;
    const user_code = strFieldObj(da, "user_code") orelse "";
    const verify = strFieldObj(da, "verification_uri_complete") orelse strFieldObj(da, "verification_uri") orelse "";
    const interval: i64 = if (da.get("interval")) |iv| (if (iv == .integer) @max(iv.integer, 1) else 5) else 5;

    try out.print("\nTo log in to Kimi, open this URL (browser should open automatically):\n\n  {s}\n\nand confirm the code:  {s}\n\nwaiting for authorization…\n", .{ verify, user_code });
    try out.flush();
    openBrowser(io, verify);

    const poll_body = try std.fmt.allocPrint(arena, "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code", .{ kimi_client_id, device_code });
    var attempts: usize = 0;
    while (attempts < 360) : (attempts += 1) {
        io.sleep(Io.Duration.fromSeconds(interval), .awake) catch {};
        const resp = kimiOAuthPost(io, gpa, arena, home, kimi_token_url, poll_body) catch continue;
        if (resp.get("access_token")) |a| if (a == .string and a.string.len > 0) {
            const refresh = strFieldObj(resp, "refresh_token") orelse "";
            const expires_in: i64 = if (resp.get("expires_in")) |ei| (if (ei == .integer) ei.integer else 900) else 900;
            try writeKimiAuth(io, arena, home, a.string, refresh, @divTrunc(unixMs(io), 1000) + expires_in);
            _ = kimi_catalog.load(io, gpa, arena, home, a.string);
            try out.print("✓ logged into Kimi — wrote {s}. /model kimi selects {s}\n", .{
                kimiAuthPath(arena, home), pricing.providerDefaultModel("kimi", "k3"),
            });
            try out.flush();
            return;
        };
        const msg = if (resp.get("error")) |e| (if (e == .string) e.string else "") else "";
        if (std.mem.eql(u8, msg, "authorization_pending") or std.mem.eql(u8, msg, "slow_down")) continue;
        if (std.mem.eql(u8, msg, "expired_token")) {
            try out.writeAll("✗ the code expired — run `graff login kimi` again\n");
            try out.flush();
            return;
        }
        if (msg.len > 0) {
            try out.print("✗ {s}\n", .{msg});
            try out.flush();
            return;
        }
    }
    try out.writeAll("✗ timed out waiting for authorization\n");
    try out.flush();
}

/// #245 single-flight guard: has the token that just 401'd already been replaced
/// on disk by another concurrent refresher?
///
/// `force` means "the access token I was holding just failed with a 401". The
/// refresh mutex serializes concurrent refreshers but does NOT dedupe them, so a
/// fleet of subagents that all 401 on the same expired token would each re-mint
/// in turn. Kimi (and xAI) rotate refresh tokens and INVALIDATE the superseded
/// access token, so refresher N+1 kills the token refresher N just adopted — the
/// 401 cascade that wipes out a whole fleet.
///
/// If the on-disk token already differs from the one that failed, the 401 was
/// about the OLD token and somebody else has already done the work: adopt theirs
/// instead of minting another. `stale == null` keeps the previous behaviour for
/// callers that cannot say which token failed.
fn supersededToken(force: bool, on_disk: []const u8, stale: ?[]const u8) bool {
    if (!force) return false;
    const failed = stale orelse return false;
    return !std.mem.eql(u8, on_disk, failed);
}

/// Reads the stored Kimi OAuth access token, refreshing it in place when within
/// 60s of expiry. Returns null if not logged in. Mirrors loadCodexAuth.
/// `stale` is the token that just 401'd (null when not recovering from one) —
/// see supersededToken.
pub fn loadKimiOAuth(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, force: bool, stale: ?[]const u8) ?[]const u8 {
    const data = Io.Dir.cwd().readFileAlloc(io, kimiAuthPath(arena, home), arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const access = strFieldObj(v.object, "access_token") orelse return null;
    const expires_at: i64 = if (v.object.get("expires_at")) |e| (if (e == .integer) e.integer else 0) else 0;
    // #245: another concurrent refresher may already have replaced the token that
    // 401'd; re-minting would rotate-kill theirs. Adopt what is on disk instead.
    if (supersededToken(force, access, stale)) return access;
    if (force or (expires_at != 0 and @divTrunc(unixMs(io), 1000) >= expires_at - oauth_refresh_margin_s)) {
        if (strFieldObj(v.object, "refresh_token")) |refresh| {
            const body = std.fmt.allocPrint(arena, "client_id={s}&grant_type=refresh_token&refresh_token={s}", .{ kimi_client_id, refresh }) catch return access;
            const resp = kimiOAuthPost(io, gpa, arena, home, kimi_token_url, body) catch return access;
            if (resp.get("access_token")) |a| if (a == .string and a.string.len > 0) {
                const new_refresh = strFieldObj(resp, "refresh_token") orelse refresh;
                const expires_in: i64 = if (resp.get("expires_in")) |ei| (if (ei == .integer) ei.integer else 900) else 900;
                writeKimiAuth(io, arena, home, a.string, new_refresh, @divTrunc(unixMs(io), 1000) + expires_in) catch {};
                return a.string;
            };
        }
    }
    return access;
}

/// #148: mid-session refresh for a login-sourced key. For the short-lived
/// refreshable OAuth providers (kimi/xai) returns the current access token,
/// refreshed in place if within oauth_refresh_margin_s of expiry (or `force`d,
/// e.g. after a 401). Returns null for providers with no auto-refresh flow
/// (env keys, and the long-lived codex/codegraff tokens), so the caller keeps
/// the key it has. Mutex-guarded so concurrent subagents don't double-refresh.
pub fn refreshOAuthKey(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, provider_id: []const u8, force: bool, stale: ?[]const u8) ?[]const u8 {
    const is_kimi = std.mem.eql(u8, provider_id, "kimi");
    const is_xai = std.mem.eql(u8, provider_id, "xai");
    if (!is_kimi and !is_xai) return null;
    oauth_refresh_mutex.lockUncancelable(io);
    defer oauth_refresh_mutex.unlock(io);
    return if (is_kimi) loadKimiOAuth(io, gpa, arena, home, force, stale) else loadXaiOAuth(io, gpa, arena, home, force, stale);
}

// xAI (Grok) OAuth — device-code flow against auth.x.ai. The OIDC discovery
// doc (auth.x.ai/.well-known/openid-configuration) advertises the device_code
// grant + a public ("none") client, so no secret/PKCE is needed. `graff login
// xai` runs the flow and writes the token to ~/.xai/credentials/graff-oauth.json;
// loadXaiOAuth reads it at startup and refreshes near expiry. The access token
// is sent as a plain bearer to the existing xai provider row
// (api.x.ai/v1/chat/completions, kind=.openai). client_id is xAI's shared Grok
// CLI client — the consent screen shows "Grok Build" — same posture as the
// Codex/Kimi logins. NOTE: xAI gates api.x.ai per account, so a valid login can
// still 403 on inference until the account is allowlisted (env XAI_API_KEY wins
// and always works). User-Agent is set on all requests (Cloudflare-fronted).
const xai_oauth_host = "https://auth.x.ai";
const xai_device_auth_url = xai_oauth_host ++ "/oauth2/device/code";
const xai_token_url = xai_oauth_host ++ "/oauth2/token";
const xai_client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const xai_scope = "openid profile email offline_access grok-cli:access api:access";
const xai_user_agent = "grok-cli/1.0";

/// POST a form body to an xAI OAuth endpoint (with a CLI User-Agent); return the
/// parsed JSON object.
fn xaiOAuthPost(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, body: []const u8) !std.json.ObjectMap {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = xai_user_agent },
        },
    });
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

fn xaiAuthPath(arena: Allocator, home: []const u8) []const u8 {
    return credential_store.oauthPath(arena, home, ".xai");
}

fn writeXaiAuth(io: Io, arena: Allocator, home: []const u8, access: []const u8, refresh: []const u8, expires_at: i64) !void {
    return credential_store.writeOAuth(io, arena, home, ".xai", access, refresh, expires_at);
}

/// `graff login xai`: xAI/Grok device-code OAuth. Prints a verification URL +
/// user code, opens the browser, polls until the user authorizes, then stores
/// the access/refresh token. (The consent screen shows "Grok Build" — xAI's
/// shared CLI client.)
pub fn xaiLogin(io: Io, gpa: Allocator, arena: Allocator, home: []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const da_body = try std.fmt.allocPrint(arena, "client_id={s}&scope={s}", .{ xai_client_id, xai_scope });
    const da = xaiOAuthPost(io, gpa, arena, xai_device_auth_url, da_body) catch |err| {
        try out.print("✗ xAI device authorization failed: {t}\n", .{err});
        try out.flush();
        return;
    };
    if (da.get("error")) |e| {
        try out.print("✗ {s}\n", .{if (e == .string) e.string else "device authorization error"});
        try out.flush();
        return;
    }
    const device_code = strFieldObj(da, "device_code") orelse return error.BadOAuthResponse;
    const user_code = strFieldObj(da, "user_code") orelse "";
    const verify = strFieldObj(da, "verification_uri_complete") orelse strFieldObj(da, "verification_uri") orelse "";
    const interval: i64 = if (da.get("interval")) |iv| (if (iv == .integer) @max(iv.integer, 1) else 5) else 5;

    try out.print("\nTo log in to Grok (xAI), open this URL (browser should open automatically):\n\n  {s}\n\nand confirm the code:  {s}\n\nwaiting for authorization…\n", .{ verify, user_code });
    try out.flush();
    openBrowser(io, verify);

    const poll_body = try std.fmt.allocPrint(arena, "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code", .{ xai_client_id, device_code });
    var attempts: usize = 0;
    while (attempts < 360) : (attempts += 1) {
        io.sleep(Io.Duration.fromSeconds(interval), .awake) catch {};
        const resp = xaiOAuthPost(io, gpa, arena, xai_token_url, poll_body) catch continue;
        if (resp.get("access_token")) |a| if (a == .string and a.string.len > 0) {
            const refresh = strFieldObj(resp, "refresh_token") orelse "";
            const expires_in: i64 = if (resp.get("expires_in")) |ei| (if (ei == .integer) ei.integer else 3600) else 3600;
            try writeXaiAuth(io, arena, home, a.string, refresh, @divTrunc(unixMs(io), 1000) + expires_in);
            try out.print("✓ logged into Grok (xAI) — wrote {s}. /model xai grok-4.3\n", .{xaiAuthPath(arena, home)});
            try out.writeAll("  note: xAI gates its OpenAI-compatible API per account — if a Grok turn 403s, your account isn't allowlisted for api.x.ai yet.\n");
            try out.flush();
            return;
        };
        const msg = if (resp.get("error")) |e| (if (e == .string) e.string else "") else "";
        if (std.mem.eql(u8, msg, "authorization_pending") or std.mem.eql(u8, msg, "slow_down")) continue;
        if (std.mem.eql(u8, msg, "expired_token")) {
            try out.writeAll("✗ the code expired — run `graff login xai` again\n");
            try out.flush();
            return;
        }
        if (msg.len > 0) {
            try out.print("✗ {s}\n", .{msg});
            try out.flush();
            return;
        }
    }
    try out.writeAll("✗ timed out waiting for authorization\n");
    try out.flush();
}

/// Reads the stored xAI OAuth access token, refreshing in place near expiry.
/// Returns null if not logged in. Mirrors loadKimiOAuth.
pub fn loadXaiOAuth(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, force: bool, stale: ?[]const u8) ?[]const u8 {
    const data = Io.Dir.cwd().readFileAlloc(io, xaiAuthPath(arena, home), arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const access = strFieldObj(v.object, "access_token") orelse return null;
    const expires_at: i64 = if (v.object.get("expires_at")) |e| (if (e == .integer) e.integer else 0) else 0;
    // #245: another concurrent refresher may already have replaced the token that
    // 401'd; re-minting would rotate-kill theirs. Adopt what is on disk instead.
    if (supersededToken(force, access, stale)) return access;
    if (force or (expires_at != 0 and @divTrunc(unixMs(io), 1000) >= expires_at - oauth_refresh_margin_s)) {
        if (strFieldObj(v.object, "refresh_token")) |refresh| {
            const body = std.fmt.allocPrint(arena, "client_id={s}&grant_type=refresh_token&refresh_token={s}", .{ xai_client_id, refresh }) catch return access;
            const resp = xaiOAuthPost(io, gpa, arena, xai_token_url, body) catch return access;
            if (resp.get("access_token")) |a| if (a == .string and a.string.len > 0) {
                const new_refresh = strFieldObj(resp, "refresh_token") orelse refresh;
                const expires_in: i64 = if (resp.get("expires_in")) |ei| (if (ei == .integer) ei.integer else 3600) else 3600;
                writeXaiAuth(io, arena, home, a.string, new_refresh, @divTrunc(unixMs(io), 1000) + expires_in) catch {};
                return a.string;
            };
        }
    }
    return access;
}

pub const codegraffLogin = codegraff.login;
pub const loadCodegraffKey = codegraff.loadKey;

test "b64url: url-safe base64 without padding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("Zm9v", b64url(a, "foo"));
    try std.testing.expectEqualStrings("", b64url(a, ""));
    // bytes that would be '+' and '/' in standard base64 use '-' and '_', no '=' padding
    try std.testing.expectEqualStrings("-_8", b64url(a, &[_]u8{ 0xfb, 0xff }));
}
test "queryParam: extracts a value from an HTTP request line's query string" {
    try std.testing.expectEqualStrings("2", queryParam("GET /p?a=1&b=2 HTTP/1.1", "b").?);
    try std.testing.expectEqualStrings("1", queryParam("GET /p?a=1&b=2 HTTP/1.1", "a").?);
    try std.testing.expect(queryParam("GET /p?a=1 HTTP/1.1", "z") == null); // key absent
    try std.testing.expect(queryParam("GET /p HTTP/1.1", "a") == null); // no query string
}
test "accountFromIdToken: extracts chatgpt_account_id from a JWT payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // payload base64url-no-pad encodes
    // {"https://api.openai.com/auth":{"chatgpt_account_id":"acc_test_123"}}
    const token = "eyJhbGciOiJub25lIn0." ++
        "eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOiB7ImNoYXRncHRfYWNjb3VudF9pZCI6ICJhY2NfdGVzdF8xMjMifX0" ++
        ".sig";
    try std.testing.expectEqualStrings("acc_test_123", accountFromIdToken(a, token));
    try std.testing.expectEqualStrings("", accountFromIdToken(a, "not-a-jwt")); // no payload segment
    try std.testing.expectEqualStrings("", accountFromIdToken(a, "a.b.c")); // payload not valid base64/json
}

test "supersededToken (#245): a concurrent refresher's token is adopted, not re-minted" {
    const failed = "access-token-A";
    const replaced = "access-token-B";

    // The proactive (near-expiry) path never short-circuits — it is not recovering
    // from a 401, so there is no "failed token" to compare against.
    try std.testing.expect(!supersededToken(false, failed, failed));
    try std.testing.expect(!supersededToken(false, replaced, failed));

    // Recovering from a 401 while the on-disk token is STILL the one that failed:
    // nobody else has refreshed, so this caller must do it.
    try std.testing.expect(!supersededToken(true, failed, failed));

    // Recovering from a 401 but disk already holds a DIFFERENT token: another child
    // won the race. Re-minting here would rotate-kill their token and cascade the
    // 401s across the fleet, which is the whole bug.
    try std.testing.expect(supersededToken(true, replaced, failed));

    // A caller that cannot say which token failed keeps the old behaviour.
    try std.testing.expect(!supersededToken(true, replaced, null));
    try std.testing.expect(!supersededToken(false, replaced, null));
}
