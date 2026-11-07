//! Kimi Code OAuth — device-code flow on the shared kimi-code OAuth client.
//! Moonshot runs two sign-in servers: auth.kimi.ai for international
//! accounts and auth.kimi.com for mainland China. Hosts tell themselves
//! apart by `X-Msh-Platform`; graff reports `graff` and `graff/<version>`,
//! never the CLI's identity (#1297, ADR 0204).
//! `graff login kimi` runs the flow and writes the token, plus the server
//! that issued it, to ~/.kimi/credentials/graff-oauth.json; `load` reads it at
//! startup and refreshes in place, on that same server, when near expiry.
//! Tokens from either server work on api.kimi.com, so the API host is shared.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const unixMs = util.unixMs;
const kimi_catalog = @import("kimi_catalog.zig");
const credential_store = @import("credential_store.zig");
const pricing = @import("pricing.zig");
const signin_link = @import("signin_link.zig");
const supersededToken = @import("oauth_helpers.zig").supersededToken;
const oauth_refresh_margin_s = @import("oauth.zig").oauth_refresh_margin_s;

const client_id = "17e5f671-d194-4dfb-9706-5516cb48c098";

pub const Region = enum {
    global,
    cn,

    pub fn host(r: Region) []const u8 {
        return switch (r) {
            .global => "https://auth.kimi.ai",
            .cn => "https://auth.kimi.com",
        };
    }

    pub fn site(r: Region) []const u8 {
        return switch (r) {
            .global => "kimi.ai",
            .cn => "kimi.com",
        };
    }

    fn other(r: Region) Region {
        return if (r == .global) .cn else .global;
    }
};

/// A login saved before graff recorded the server came from auth.kimi.com.
const legacy_host = Region.cn.host();

/// `graff login kimi.ai` / `kimi.com` pick the account's site; plain `kimi`
/// returns null and lets `chooseRegion` decide.
pub fn regionFromLoginName(name: []const u8) ?Region {
    for ([_][]const u8{ "kimi.ai", "kimi-global", "kimi-intl" }) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .global;
    for ([_][]const u8{ "kimi.com", "kimi-cn" }) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .cn;
    return null;
}

pub fn isLoginName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "kimi") or regionFromLoginName(name) != null;
}

fn regionOfHost(h: []const u8) ?Region {
    if (std.mem.eql(u8, h, Region.global.host())) return .global;
    if (std.mem.eql(u8, h, Region.cn.host())) return .cn;
    return null;
}

/// Same order as kimi-code: the env override, then the server the saved
/// login recorded, then a mainland-China clock or locale; everyone else is
/// global. A login from before graff recorded the server doesn't choose.
fn chooseRegion(io: Io, arena: Allocator, home: []const u8) Region {
    if (envHostRegion()) |r| return r;
    if (recordedRegion(io, arena, home)) |r| return r;
    var buf: [256]u8 = undefined;
    const n = Io.Dir.readLinkAbsolute(io, "/etc/localtime", &buf) catch 0;
    return if (inMainland(getenv("TZ"), getenv("LANG"), buf[0..n])) .cn else .global;
}

fn envHostRegion() ?Region {
    for ([_][*:0]const u8{ "KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST" }) |name| {
        const v = getenv(name) orelse continue;
        if (std.mem.indexOf(u8, v, "kimi.ai") != null) return .global;
        if (std.mem.indexOf(u8, v, "kimi.com") != null) return .cn;
    }
    return null;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

fn inMainland(tz: ?[]const u8, lang: ?[]const u8, localtime: []const u8) bool {
    const zones = [_][]const u8{ "Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Chungking", "Asia/Harbin", "Asia/Kashgar", "PRC" };
    for (zones) |z| {
        if (tz) |t| if (std.mem.endsWith(u8, t, z)) return true;
        if (std.mem.endsWith(u8, localtime, z)) return true;
    }
    if (lang) |l| if (std.ascii.startsWithIgnoreCase(l, "zh_CN") or std.ascii.startsWithIgnoreCase(l, "zh-CN")) return true;
    return false;
}

/// POST a form body to a Kimi OAuth endpoint; return the parsed JSON object.
fn post(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, body: []const u8) !std.json.ObjectMap {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    var identity_buf: [5]std.http.Header = undefined;
    const identity = kimi_catalog.identityHeaders(&identity_buf);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = kimi_catalog.user_agent },
        },
        .extra_headers = identity,
    });
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

fn endpoint(arena: Allocator, host: []const u8, path: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ host, path }) catch "";
}

pub fn authPath(arena: Allocator, home: []const u8) []const u8 {
    return credential_store.oauthPath(arena, home, ".kimi");
}

pub fn writeAuth(io: Io, arena: Allocator, home: []const u8, access: []const u8, refresh: []const u8, expires_at: i64, host: []const u8) !void {
    return credential_store.writeOAuthFrom(io, arena, home, ".kimi", access, refresh, expires_at, host);
}

fn readSaved(io: Io, arena: Allocator, home: []const u8) ?std.json.ObjectMap {
    const data = Io.Dir.cwd().readFileAlloc(io, authPath(arena, home), arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    return if (v == .object) v.object else null;
}

/// The server that issued the saved login. Only a known Kimi server counts:
/// the refresh token is sent there.
fn savedHost(io: Io, arena: Allocator, home: []const u8) ?[]const u8 {
    const saved = readSaved(io, arena, home) orelse return null;
    const h = strFieldObj(saved, "oauth_host") orelse return legacy_host;
    return if (regionOfHost(h) != null) h else legacy_host;
}

fn recordedRegion(io: Io, arena: Allocator, home: []const u8) ?Region {
    const saved = readSaved(io, arena, home) orelse return null;
    return regionOfHost(strFieldObj(saved, "oauth_host") orelse return null);
}

fn intField(obj: std.json.ObjectMap, name: []const u8, default: i64) i64 {
    const v = obj.get(name) orelse return default;
    return if (v == .integer) v.integer else default;
}

/// `graff login kimi`: prints a verification URL + user code, copies the URL,
/// opens the browser, polls until the user authorizes, then stores the
/// access/refresh token. `region` null = choose (see chooseRegion).
pub fn login(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, region: ?Region) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;
    const r = region orelse chooseRegion(io, arena, home);
    const host = r.host();

    const da_body = try std.fmt.allocPrint(arena, "client_id={s}", .{client_id});
    const da = post(io, gpa, arena, endpoint(arena, host, "/api/oauth/device_authorization"), da_body) catch |err| {
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
    var interval: i64 = @max(intField(da, "interval", 5), 1);
    const lifetime: i64 = std.math.clamp(intField(da, "expires_in", 900), 60, 1800);

    const opens = signin_link.opensBrowser();
    try out.print("\nTo log in to Kimi on {s}, open this URL ({s}):\n\n  {s}\n", .{
        r.site(), if (opens) "browser should open automatically" else "on any device", verify,
    });
    try signin_link.offer(io, out, verify);
    try out.print("\nand confirm the code:  {s}\n\nwaiting for authorization… (the code expires in {d} min)\n", .{ user_code, @divTrunc(lifetime + 59, 60) });
    try out.print("Account on {s}? Run `graff login {s}` instead.\n", .{ r.other().site(), r.other().site() });
    try out.flush();
    signin_link.open(io, verify);

    const poll_body = try std.fmt.allocPrint(arena, "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code", .{ client_id, device_code });
    const token_url = endpoint(arena, host, "/api/oauth/token");
    const deadline = @divTrunc(unixMs(io), 1000) + lifetime;
    var failures: usize = 0;
    while (@divTrunc(unixMs(io), 1000) < deadline) {
        io.sleep(Io.Duration.fromSeconds(interval), .awake) catch {};
        const resp = post(io, gpa, arena, token_url, poll_body) catch |err| {
            failures += 1;
            if (failures >= 6) {
                try out.print("✗ can't reach {s}: {t}\n", .{ host, err });
                try out.flush();
                return;
            }
            if (failures == 1) {
                try out.print("  can't reach {s} ({t}), still trying…\n", .{ host, err });
                try out.flush();
            }
            continue;
        };
        failures = 0;
        if (resp.get("access_token")) |a| if (a == .string and a.string.len > 0) {
            const refresh = strFieldObj(resp, "refresh_token") orelse "";
            const expires_in = intField(resp, "expires_in", 900);
            try writeAuth(io, arena, home, a.string, refresh, @divTrunc(unixMs(io), 1000) + expires_in, host);
            _ = kimi_catalog.load(io, gpa, arena, a.string);
            try out.print("✓ logged into Kimi ({s}) — wrote {s}. /model kimi selects {s}\n", .{
                r.site(), authPath(arena, home), pricing.providerDefaultModel("kimi", "k3"),
            });
            try out.flush();
            return;
        };
        const msg = strFieldObj(resp, "error") orelse "";
        if (std.mem.eql(u8, msg, "authorization_pending")) continue;
        // RFC 8628 §3.5: every slow_down adds 5 seconds for the rest of the poll.
        if (std.mem.eql(u8, msg, "slow_down")) {
            interval += 5;
            continue;
        }
        if (std.mem.eql(u8, msg, "expired_token")) break;
        if (std.mem.eql(u8, msg, "access_denied")) {
            try out.print("✗ sign-in was declined on {s}\n", .{r.site()});
            try out.flush();
            return;
        }
        if (msg.len > 0) {
            try out.print("✗ {s}\n", .{strFieldObj(resp, "error_description") orelse msg});
            try out.flush();
            return;
        }
    }
    try out.writeAll("✗ the code expired — run `graff login kimi` again\n");
    try out.flush();
}

/// Reads the stored Kimi OAuth access token, refreshing it in place when within
/// the refresh margin of expiry. Returns null if not logged in. Mirrors
/// loadCodexAuth. `stale` is the token that just 401'd (null when not
/// recovering from one) — see supersededToken.
pub fn load(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, force: bool, stale: ?[]const u8) ?[]const u8 {
    const saved = readSaved(io, arena, home) orelse return null;
    const access = strFieldObj(saved, "access_token") orelse return null;
    const expires_at = intField(saved, "expires_at", 0);
    // #245: another concurrent refresher may already have replaced the token that
    // 401'd; re-minting would rotate-kill theirs. Adopt what is on disk instead.
    if (supersededToken(force, access, stale)) return access;
    if (force or (expires_at != 0 and @divTrunc(unixMs(io), 1000) >= expires_at - oauth_refresh_margin_s)) {
        if (strFieldObj(saved, "refresh_token")) |refresh| {
            const host = savedHost(io, arena, home) orelse legacy_host;
            const body = std.fmt.allocPrint(arena, "client_id={s}&grant_type=refresh_token&refresh_token={s}", .{ client_id, refresh }) catch return access;
            const resp = post(io, gpa, arena, endpoint(arena, host, "/api/oauth/token"), body) catch return access;
            if (resp.get("access_token")) |a| if (a == .string and a.string.len > 0) {
                const new_refresh = strFieldObj(resp, "refresh_token") orelse refresh;
                const expires_in = intField(resp, "expires_in", 900);
                writeAuth(io, arena, home, a.string, new_refresh, @divTrunc(unixMs(io), 1000) + expires_in, host) catch {};
                return a.string;
            };
        }
    }
    return access;
}

test "login names pick the Kimi site" {
    try std.testing.expectEqual(Region.global, regionFromLoginName("kimi.ai").?);
    try std.testing.expectEqual(Region.cn, regionFromLoginName("Kimi.com").?);
    try std.testing.expect(regionFromLoginName("kimi") == null);
    try std.testing.expect(isLoginName("kimi") and isLoginName("kimi.ai") and !isLoginName("kimix"));
    try std.testing.expectEqualStrings("https://auth.kimi.ai", Region.global.host());
}

test "mainland clock or locale picks kimi.com; everyone else kimi.ai" {
    try std.testing.expect(inMainland(null, null, "/var/db/timezone/zoneinfo/Asia/Shanghai"));
    try std.testing.expect(inMainland("Asia/Urumqi", null, ""));
    try std.testing.expect(inMainland(null, "zh_CN.UTF-8", ""));
    try std.testing.expect(!inMainland(null, "zh_TW.UTF-8", "/usr/share/zoneinfo/Asia/Taipei"));
    try std.testing.expect(!inMainland("Asia/Singapore", "en_US.UTF-8", "/usr/share/zoneinfo/Asia/Singapore"));
}

test "a login keeps the server that issued it; old logins and unknown hosts mean kimi.com" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const far_future: i64 = 4102444800;

    try std.testing.expect(savedHost(io, arena, home) == null);
    try writeAuth(io, arena, home, "a", "r", far_future, Region.global.host());
    try std.testing.expectEqualStrings("https://auth.kimi.ai", savedHost(io, arena, home).?);
    try std.testing.expectEqual(Region.global, recordedRegion(io, arena, home).?);
    try writeAuth(io, arena, home, "a", "r", far_future, "");
    try std.testing.expectEqualStrings(legacy_host, savedHost(io, arena, home).?);
    try std.testing.expect(recordedRegion(io, arena, home) == null);
    try writeAuth(io, arena, home, "a", "r", far_future, "https://evil.example");
    try std.testing.expectEqualStrings(legacy_host, savedHost(io, arena, home).?);
    try std.testing.expectEqualStrings("a", load(io, std.testing.allocator, arena, home, false, null).?);
}
