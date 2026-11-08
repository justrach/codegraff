//! Codex credential IO, callback parsing and the common browser helpers used by
//! the OAuth login flows — plus the silent codex token refresh the request loop
//! runs mid-turn (#402), which must stay off stdout.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const credential_store = @import("credential_store.zig");
const oauth_lock = @import("oauth_lock.zig");
const strFieldObj = @import("util.zig").strFieldObj;
const unixMs = @import("util.zig").unixMs;

pub const PostFn = *const fn (Io, Allocator, Allocator, []const u8, []const u8) anyerror!std.json.ObjectMap;

pub fn isTransientHttpStatus(status: std.http.Status) bool {
    const code = @backingInt(status);
    return status == .request_timeout or status == .too_many_requests or code >= 500;
}

/// Retains a rotated OAuth credential in memory when atomic disk persistence
/// fails transiently, so a single-use replacement refresh_token is not lost
/// across turns and flushes once the credential path becomes writable again.
pub const PendingSlot = struct {
    mu: Io.Mutex = .init,
    buf: []u8 = &.{},
    key_len: usize = 0,
    stale_len: usize = 0,

    pub const View = struct { stale_refresh: []const u8, payload: []const u8 };

    pub fn save(self: *PendingSlot, io: Io, key: []const u8, stale_refresh: []const u8, payload: []const u8) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const total = key.len + stale_refresh.len + payload.len;
        const mem = std.heap.page_allocator.alloc(u8, total) catch return;
        @memcpy(mem[0..key.len], key);
        @memcpy(mem[key.len..][0..stale_refresh.len], stale_refresh);
        @memcpy(mem[key.len + stale_refresh.len ..], payload);
        if (self.buf.len > 0) std.heap.page_allocator.free(self.buf);
        self.buf = mem;
        self.key_len = key.len;
        self.stale_len = stale_refresh.len;
    }

    pub fn peek(self: *PendingSlot, io: Io, arena: Allocator, key: []const u8) ?View {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.buf.len == 0) return null;
        if (!std.mem.eql(u8, self.buf[0..self.key_len], key)) return null;
        const stale = arena.dupe(u8, self.buf[self.key_len..][0..self.stale_len]) catch return null;
        const payload = arena.dupe(u8, self.buf[self.key_len + self.stale_len ..]) catch return null;
        return .{ .stale_refresh = stale, .payload = payload };
    }

    pub fn clear(self: *PendingSlot, io: Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.buf.len > 0) std.heap.page_allocator.free(self.buf);
        self.buf = &.{};
        self.key_len = 0;
        self.stale_len = 0;
    }
};

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
/// auth.json below (#402).
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
/// `Option<DateTime<Utc>>`).
pub fn rfc3339Utc(buf: *[24]u8, unix_ms: i64) []const u8 {
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
/// field this harness does not own (#402).
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
    Io.Dir.cwd().createDirPath(io, codex_home) catch {};
    try credential_store.replaceFile(io, Io.Dir.cwd(), path, aw.writer.buffered(), credential_store.private_file);
}

/// POST a urlencoded form body to an OAuth token endpoint; return the parsed
/// JSON object. HTTP 408/429/5xx are treated as transient transport errors so
/// upstream blips can never be mistaken for a revoked refresh grant.
pub fn oauthFormPost(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, body: []const u8) !std.json.ObjectMap {
    const res = try oauth_lock.fetchPostBounded(io, gpa, arena, .{ .url = url, .payload = body });
    if (isTransientHttpStatus(res.status)) return error.TransientOAuthStatus;
    const v = try std.json.parseFromSliceLeaky(Value, arena, res.body, .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

/// #245: if the on-disk token already differs from the one that failed, another
/// refresher has already rotated it: adopt theirs instead of minting another.
pub fn supersededToken(force: bool, on_disk: []const u8, stale: ?[]const u8) bool {
    if (!force) return false;
    const failed = stale orelse return false;
    return !std.mem.eql(u8, on_disk, failed);
}

pub const StoredCodexAuth = struct {
    access: []const u8,
    refresh: []const u8 = "",
    id_token: []const u8 = "",
    account: []const u8 = "",
};

fn readCodexJson(io: Io, arena: Allocator, path: []const u8) ?std.json.ObjectMap {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    return if (v == .object) v.object else null;
}

/// Read <codex_home>/auth.json in full. Null when missing/unparseable/empty.
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
/// is retried — as opposed to a transient 5xx/offline failure.
pub fn permanentRefreshFailure(code: []const u8) bool {
    const permanent = [_][]const u8{ "invalid_grant", "invalid_client", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated" };
    for (permanent) |p| if (std.mem.eql(u8, code, p)) return true;
    return false;
}

var dead_refresh_token: u64 = 0;
var codex_pending: PendingSlot = .{};
var codex_refresh_mutex: Io.Mutex = .init;

pub const FreshKey = struct { key: []const u8, account: []const u8 = "" };

pub var persist_error: ?[]const u8 = null;

pub fn takePersistError() ?[]const u8 {
    defer persist_error = null;
    return persist_error;
}

pub fn clearStateForTest(io: Io) void {
    if (!builtin.is_test) return;
    codex_pending.clear(io);
    dead_refresh_token = 0;
    persist_error = null;
}

fn serializePendingCodex(arena: Allocator, auth: StoredCodexAuth) ?[]const u8 {
    var obj: std.json.ObjectMap = .empty;
    obj.put(arena, "id_token", .{ .string = auth.id_token }) catch return null;
    obj.put(arena, "access_token", .{ .string = auth.access }) catch return null;
    obj.put(arena, "refresh_token", .{ .string = auth.refresh }) catch return null;
    obj.put(arena, "account_id", .{ .string = auth.account }) catch return null;
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    stringify.write(Value{ .object = obj }) catch return null;
    return aw.writer.buffered();
}

fn parsePendingCodex(arena: Allocator, payload: []const u8) ?StoredCodexAuth {
    const v = std.json.parseFromSliceLeaky(Value, arena, payload, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const access = strFieldObj(v.object, "access_token") orelse return null;
    if (access.len == 0) return null;
    return .{
        .access = access,
        .refresh = strFieldObj(v.object, "refresh_token") orelse "",
        .id_token = strFieldObj(v.object, "id_token") orelse "",
        .account = strFieldObj(v.object, "account_id") orelse "",
    };
}

/// Persist a refreshed credential, retrying once. If both writes fail, retain
/// the rotated credential in memory so later turns do not replay the spent
/// refresh_token from disk, and surface `persist_error` to the caller.
pub fn persistRefreshed(io: Io, arena: Allocator, codex_home: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) void {
    persistRefreshedWithStale(io, arena, codex_home, "", id_token, access, refresh, account);
}

fn persistRefreshedWithStale(io: Io, arena: Allocator, codex_home: []const u8, stale_refresh: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) void {
    writeCodexAuthAt(io, arena, codex_home, id_token, access, refresh, account) catch {
        writeCodexAuthAt(io, arena, codex_home, id_token, access, refresh, account) catch |err| {
            persist_error = @errorName(err);
            if (serializePendingCodex(arena, .{ .access = access, .refresh = refresh, .id_token = id_token, .account = account })) |payload| {
                codex_pending.save(io, codex_home, stale_refresh, payload);
            }
            return;
        };
    };
    codex_pending.clear(io);
}

const ResolvedCodex = struct { auth: StoredCodexAuth, disk_stale_refresh: []const u8 };

fn resolveCodexAuth(io: Io, arena: Allocator, codex_home: []const u8) ?ResolvedCodex {
    const disk = readCodexAuth(io, arena, codex_home);
    if (codex_pending.peek(io, arena, codex_home)) |pend| {
        if (disk) |d| {
            if (d.refresh.len > 0 and !std.mem.eql(u8, d.refresh, pend.stale_refresh)) {
                codex_pending.clear(io);
                return .{ .auth = d, .disk_stale_refresh = d.refresh };
            }
        }
        if (parsePendingCodex(arena, pend.payload)) |p_auth| {
            if (writeCodexAuthAt(io, arena, codex_home, p_auth.id_token, p_auth.access, p_auth.refresh, p_auth.account)) |_| {
                codex_pending.clear(io);
                return .{ .auth = p_auth, .disk_stale_refresh = p_auth.refresh };
            } else |_| {
                return .{ .auth = p_auth, .disk_stale_refresh = pend.stale_refresh };
            }
        }
    }
    const d = disk orelse return null;
    return .{ .auth = d, .disk_stale_refresh = d.refresh };
}

pub fn loadCodexOAuth(io: Io, gpa: Allocator, arena: Allocator, codex_home: []const u8, force: bool, stale: ?[]const u8, expect_account: []const u8) ?FreshKey {
    return loadCodexOAuthWithPost(io, gpa, arena, codex_home, force, stale, expect_account, oauthFormPost);
}

pub fn loadCodexOAuthWithPost(io: Io, gpa: Allocator, arena: Allocator, codex_home: []const u8, force: bool, stale: ?[]const u8, expect_account: []const u8, post_fn: PostFn) ?FreshKey {
    const resolved = resolveCodexAuth(io, arena, codex_home) orelse return null;
    const auth = resolved.auth;
    if (expect_account.len > 0 and auth.account.len > 0 and !std.mem.eql(u8, expect_account, auth.account)) return null;
    const on_disk: FreshKey = .{ .key = auth.access, .account = auth.account };
    if (supersededToken(force, auth.access, stale)) return on_disk;
    if (!force or auth.refresh.len == 0) return on_disk;

    const cred_path = codexAuthPath(arena, codex_home) catch return on_disk;
    const guard = oauth_lock.acquire(io, arena, &codex_refresh_mutex, cred_path) orelse return on_disk;
    defer guard.release();

    const locked = resolveCodexAuth(io, arena, codex_home) orelse return null;
    const cur = locked.auth;
    if (expect_account.len > 0 and cur.account.len > 0 and !std.mem.eql(u8, expect_account, cur.account)) return null;
    const cur_key: FreshKey = .{ .key = cur.access, .account = cur.account };
    if (!std.mem.eql(u8, cur.access, auth.access) or !std.mem.eql(u8, cur.refresh, auth.refresh) or supersededToken(force, cur.access, stale))
        return cur_key;
    if (cur.refresh.len == 0) return cur_key;
    const refresh_id = std.hash.Wyhash.hash(0, cur.refresh);
    if (refresh_id == dead_refresh_token) return cur_key; // known dead: no round trip
    const body = std.fmt.allocPrint(arena, "grant_type=refresh_token&client_id={s}&refresh_token={s}&scope={s}", .{ codex_client_id, cur.refresh, codex_scope_enc }) catch return cur_key;
    const shield = oauth_lock.CancelShield.enter(io);
    defer shield.leave();
    const resp = post_fn(io, gpa, arena, codex_token_url, body) catch return cur_key; // transient: retryable, do not cache
    if (resp.get("error")) |e| {
        // A sibling `codex` CLI without advisory locking may have rotated auth.json in flight.
        if (readCodexAuth(io, arena, codex_home)) |after| {
            const acct_ok = expect_account.len == 0 or after.account.len == 0 or std.mem.eql(u8, expect_account, after.account);
            if (acct_ok and (!std.mem.eql(u8, after.access, cur.access) or !std.mem.eql(u8, after.refresh, cur.refresh))) {
                codex_pending.clear(io);
                return .{ .key = after.access, .account = after.account };
            }
        }
        if (permanentRefreshFailure(if (e == .string) e.string else "")) dead_refresh_token = refresh_id;
        return cur_key;
    }
    const access = strFieldObj(resp, "access_token") orelse return cur_key;
    if (access.len == 0) return cur_key;
    const id_token = strFieldObj(resp, "id_token") orelse cur.id_token;
    const refresh = strFieldObj(resp, "refresh_token") orelse cur.refresh;
    var account = if (id_token.len > 0) accountFromIdToken(arena, id_token) else "";
    if (account.len == 0) account = cur.account; // a rotated grant may omit id_token
    persistRefreshedWithStale(io, arena, codex_home, locked.disk_stale_refresh, id_token, access, refresh, account);
    return .{ .key = access, .account = account };
}

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

/// Opens `url` in the default browser, or in GRAFF_BROWSER when set.
pub fn openBrowser(io: Io, url: []const u8) void {
    const chosen: ?[]const u8 = if (std.c.getenv("GRAFF_BROWSER")) |v| std.mem.span(v) else null;
    var buf: [4][]const u8 = undefined;
    var child = std.process.spawn(io, .{ .argv = browserArgv(builtin.os.tag, chosen, url, &buf), .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}

pub fn browserArgv(os: std.Target.Os.Tag, chosen: ?[]const u8, url: []const u8, buf: *[4][]const u8) []const []const u8 {
    const parts: []const []const u8 = switch (os) {
        .macos => if (chosen) |app| &.{ "open", "-a", app, url } else &.{ "open", url },
        .windows => if (chosen) |cmd| &.{ cmd, url } else &.{ "rundll32.exe", "url.dll,FileProtocolHandler", url },
        else => if (chosen) |cmd| &.{ cmd, url } else &.{ "xdg-open", url },
    };
    @memcpy(buf[0..parts.len], parts);
    return buf[0..parts.len];
}

test {
    _ = .{ @import("oauth_helpers_tests.zig"), @import("oauth_lock.zig") };
}
