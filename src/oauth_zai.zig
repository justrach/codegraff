//! Z.AI Coding Plan login. Uses ZCode's public CLI OAuth broker, then
//! provisions a Graff-named API key onto `/api/coding/paas/v4`.
//!
//! Identity stays `graff/<version>`. The provisioned key is named
//! `graff-api-key`, not `zcode-api-key` (ADR 0151).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const style = &@import("ansi.zig").style;
const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const intFieldObj = util.intFieldObj;
const openBrowser = @import("oauth_helpers.zig").openBrowser;
const credential_store = @import("credential_store.zig");
const provider_mod = @import("provider.zig");
const credential_failover = @import("credential_failover.zig");
const main_mod = @import("main.zig");

const user_agent = "graff/" ++ @import("build_options").version;
const cli_base = "https://zcode.z.ai/api/v1";
const biz_host = "https://api.z.ai";
const default_org_name = "默认机构";
const default_project_name = "默认项目";

pub const api_key_name = "graff-api-key";
pub const oauth_dir = ".zai";

pub const InitData = struct {
    authorize_url: []const u8,
    flow_id: []const u8,
    expires_at: i64,
    poll_interval_sec: i64,
};

pub const ReadyData = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    jwt: []const u8,
};

pub const PollStatus = union(enum) {
    pending,
    failed,
    ready: ReadyData,
};

pub const OrgProject = struct {
    organization_id: []const u8,
    project_id: []const u8,
};

pub const KeySummary = struct {
    name: []const u8,
    api_key: []const u8,
};

pub fn isLoginName(name: []const u8) bool {
    return std.mem.eql(u8, name, "zai") or std.mem.eql(u8, name, "glm") or std.mem.eql(u8, name, "z.ai");
}

/// Env `GRAFF_ZAI_URL` / `ZAI_CODING` win; a coding-plan login otherwise
/// pins the coding host so the next process does not need `ZAI_CODING=1`.
pub fn applyCodingOverride() void {
    if (provider_mod.g_zai_url_override != null) return;
    provider_mod.g_zai_url_override = provider_mod.zai_coding_url;
}

pub fn currentZaiUrl() []const u8 {
    return provider_mod.g_zai_url_override orelse "https://api.z.ai/api/paas/v4/chat/completions";
}

fn authPath(arena: Allocator, home: []const u8) []const u8 {
    return credential_store.oauthPath(arena, home, oauth_dir);
}

fn unwrapData(v: Value) !Value {
    if (v != .object) return error.BadOAuthResponse;
    if (!isSuccessfulRemoteCode(v.object.get("code"))) return error.BadOAuthResponse;
    return v.object.get("data") orelse error.BadOAuthResponse;
}

fn asObject(v: Value) !std.json.ObjectMap {
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

pub fn isSuccessfulRemoteCode(code: ?Value) bool {
    const c = code orelse return true;
    return switch (c) {
        .integer => |i| i == 0 or i == 200,
        .string => |s| std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "200"),
        .null => true,
        else => false,
    };
}

pub fn parseInitData(data: std.json.ObjectMap) !InitData {
    const url = strFieldObj(data, "authorize_url") orelse return error.BadOAuthResponse;
    if (!std.mem.startsWith(u8, url, "https://")) return error.BadOAuthResponse;
    const flow_id = strFieldObj(data, "flow_id") orelse return error.BadOAuthResponse;
    if (flow_id.len == 0) return error.BadOAuthResponse;
    const expires_at = intFieldObj(data, "expires_at", 0);
    if (expires_at <= 0) return error.BadOAuthResponse;
    const interval = intFieldObj(data, "poll_interval_sec", 0);
    if (interval < 1) return error.BadOAuthResponse;
    return .{ .authorize_url = url, .flow_id = flow_id, .expires_at = expires_at, .poll_interval_sec = interval };
}

pub fn parsePollData(data: std.json.ObjectMap) !PollStatus {
    const status = strFieldObj(data, "status") orelse return error.BadOAuthResponse;
    if (std.mem.eql(u8, status, "pending")) return .pending;
    if (std.mem.eql(u8, status, "failed")) return .failed;
    if (!std.mem.eql(u8, status, "ready")) return error.BadOAuthResponse;
    const jwt = strFieldObj(data, "token") orelse return error.BadOAuthResponse;
    const provider = data.get("zai") orelse return error.BadOAuthResponse;
    if (provider != .object) return error.BadOAuthResponse;
    const access = strFieldObj(provider.object, "access_token") orelse strFieldObj(provider.object, "accessToken") orelse return error.BadOAuthResponse;
    if (access.len == 0 or jwt.len == 0) return error.BadOAuthResponse;
    const refresh = strFieldObj(provider.object, "refresh_token") orelse strFieldObj(provider.object, "refreshToken") orelse "";
    return .{ .ready = .{ .access_token = access, .refresh_token = refresh, .jwt = jwt } };
}

pub fn pickOrgAndProject(info: std.json.ObjectMap) ?OrgProject {
    const orgs_v = info.get("organizations") orelse return null;
    if (orgs_v != .array or orgs_v.array.items.len == 0) return null;
    var chosen_org: ?std.json.ObjectMap = null;
    for (orgs_v.array.items) |item| {
        if (item != .object) continue;
        const name = strFieldObj(item.object, "organizationName") orelse "";
        if (std.mem.indexOf(u8, name, default_org_name) != null) {
            chosen_org = item.object;
            break;
        }
        if (chosen_org == null) chosen_org = item.object;
    }
    const org = chosen_org orelse return null;
    const org_id = strFieldObj(org, "organizationId") orelse return null;
    const projects_v = org.get("projects") orelse return null;
    if (projects_v != .array or projects_v.array.items.len == 0) return null;
    var chosen_project: ?std.json.ObjectMap = null;
    for (projects_v.array.items) |item| {
        if (item != .object) continue;
        const name = strFieldObj(item.object, "projectName") orelse "";
        if (std.mem.indexOf(u8, name, default_project_name) != null) {
            chosen_project = item.object;
            break;
        }
        if (chosen_project == null) chosen_project = item.object;
    }
    const project = chosen_project orelse return null;
    const project_id = strFieldObj(project, "projectId") orelse return null;
    if (org_id.len == 0 or project_id.len == 0) return null;
    return .{ .organization_id = org_id, .project_id = project_id };
}

pub fn findGraffKey(keys: []const KeySummary) ?[]const u8 {
    for (keys) |item| {
        if (std.mem.eql(u8, item.name, api_key_name) and item.api_key.len > 0) return item.api_key;
    }
    return null;
}

pub fn composeApiKey(arena: Allocator, id: []const u8, secret: []const u8) ![]const u8 {
    if (id.len == 0) return error.BadOAuthResponse;
    if (secret.len == 0) return error.BadOAuthResponse;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ id, secret });
}

fn parseJsonObject(arena: Allocator, raw: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

fn httpJson(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    extra: []const std.http.Header,
) !Value {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    var extra_buf: [8]std.http.Header = undefined;
    const n = @min(extra.len, extra_buf.len);
    if (n > 0) @memcpy(extra_buf[0..n], extra[0..n]);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{
            .content_type = if (body != null) .{ .override = "application/json" } else .omit,
            .user_agent = .{ .override = user_agent },
        },
        .extra_headers = extra_buf[0..n],
    });
    return std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
}

fn writeAuth(
    io: Io,
    arena: Allocator,
    home: []const u8,
    api_key: []const u8,
    access: []const u8,
    refresh: []const u8,
    expires_at: i64,
) !void {
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, oauth_dir });
    const credentials = try std.fmt.allocPrint(arena, "{s}/credentials", .{base});
    for ([_][]const u8{ base, credentials }) |path| {
        Io.Dir.cwd().createDir(io, path, credential_store.private_dir) catch {};
        const dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        if (builtin.os.tag != .windows) dir.setPermissions(io, credential_store.private_dir) catch {};
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "api_key", .{ .string = api_key });
    try obj.put(arena, "access_token", .{ .string = access });
    try obj.put(arena, "refresh_token", .{ .string = refresh });
    try obj.put(arena, "expires_at", .{ .integer = expires_at });
    try obj.put(arena, "coding", .{ .bool = true });
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(Value{ .object = obj });
    try credential_store.replaceFile(io, Io.Dir.cwd(), authPath(arena, home), aw.writer.buffered(), credential_store.private_file);
}

/// Reads the provisioned Coding Plan API key. Sets the coding host unless an
/// env override already won. `gpa`/`force`/`stale` match the kimi/xai loader
/// signature; the key is long-lived so there is no refresh in this module.
pub fn loadZaiOAuth(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, force: bool, stale: ?[]const u8) ?[]const u8 {
    _ = gpa;
    _ = force;
    _ = stale;
    const data = Io.Dir.cwd().readFileAlloc(io, authPath(arena, home), arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const key = strFieldObj(v.object, "api_key") orelse return null;
    if (key.len == 0) return null;
    applyCodingOverride();
    return key;
}

fn bizGet(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, authorization: []const u8) !Value {
    const extra = [_]std.http.Header{.{ .name = "Authorization", .value = authorization }};
    return unwrapData(try httpJson(io, gpa, arena, .GET, url, null, &extra));
}

fn bizPost(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, authorization: []const u8, body: []const u8) !Value {
    const extra = [_]std.http.Header{.{ .name = "Authorization", .value = authorization }};
    return unwrapData(try httpJson(io, gpa, arena, .POST, url, body, &extra));
}

fn jsonObject(arena: Allocator, obj: std.json.ObjectMap) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(Value{ .object = obj });
    return aw.writer.buffered();
}

fn summariesFrom(arena: Allocator, v: Value) ![]KeySummary {
    const items = switch (v) {
        .array => |a| a.items,
        .object => |o| blk: {
            if (o.get("data")) |inner| if (inner == .array) break :blk inner.array.items;
            return &.{};
        },
        else => return &.{},
    };
    var out: std.ArrayList(KeySummary) = .empty;
    for (items) |item| {
        if (item != .object) continue;
        const name = strFieldObj(item.object, "name") orelse "";
        const key = strFieldObj(item.object, "apiKey") orelse "";
        if (key.len == 0) continue;
        try out.append(arena, .{ .name = name, .api_key = key });
    }
    return out.items;
}

fn provisionApiKey(io: Io, gpa: Allocator, arena: Allocator, oauth_access: []const u8) ![]const u8 {
    var login_obj: std.json.ObjectMap = .empty;
    try login_obj.put(arena, "token", .{ .string = oauth_access });
    const extra = [_]std.http.Header{};
    const login_v = try httpJson(io, gpa, arena, .POST, biz_host ++ "/api/auth/z/login", try jsonObject(arena, login_obj), &extra);
    const login_data = try asObject(try unwrapData(login_v));
    const biz = strFieldObj(login_data, "access_token") orelse strFieldObj(login_data, "accessToken") orelse return error.BadOAuthResponse;
    const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{biz});

    const customer = try asObject(try bizGet(io, gpa, arena, biz_host ++ "/api/biz/customer/getCustomerInfo", authorization));
    const loc = pickOrgAndProject(customer) orelse return error.BadOAuthResponse;
    const list_url = try std.fmt.allocPrint(
        arena,
        "{s}/api/biz/v1/organization/{s}/projects/{s}/api_keys",
        .{ biz_host, loc.organization_id, loc.project_id },
    );
    const listed = try summariesFrom(arena, try bizGet(io, gpa, arena, list_url, authorization));
    var api_id = findGraffKey(listed);
    if (api_id == null) {
        var create_obj: std.json.ObjectMap = .empty;
        try create_obj.put(arena, "name", .{ .string = api_key_name });
        const created = try asObject(try bizPost(io, gpa, arena, list_url, authorization, try jsonObject(arena, create_obj)));
        api_id = strFieldObj(created, "apiKey");
    }
    const id = api_id orelse return error.BadOAuthResponse;
    const copy_url = try std.fmt.allocPrint(arena, "{s}/copy/{s}", .{ list_url, id });
    const secret_data = try asObject(try bizGet(io, gpa, arena, copy_url, authorization));
    const secret = strFieldObj(secret_data, "secretKey") orelse return error.BadOAuthResponse;
    return composeApiKey(arena, id, secret);
}

/// `graff login zai`: open the Z.AI Coding Plan authorize URL, poll the CLI
/// broker, provision a Graff-named API key, and store it for `/api/coding/paas/v4`.
pub fn login(io: Io, gpa: Allocator, arena: Allocator, home: []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    var raw: [32]u8 = undefined;
    io.random(&raw);
    const poll_token = std.fmt.bytesToHex(raw, .lower);
    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{&poll_token});
    const init_headers = [_]std.http.Header{.{ .name = "Authorization", .value = bearer }};
    var init_obj: std.json.ObjectMap = .empty;
    try init_obj.put(arena, "provider", .{ .string = "zai" });
    const init_v = httpJson(io, gpa, arena, .POST, cli_base ++ "/oauth/cli/init", try jsonObject(arena, init_obj), &init_headers) catch |err| {
        try out.print("\xe2\x9c\x97 Z.AI login failed: {t}\n", .{err});
        try out.flush();
        return;
    };
    const init_data = asObject(unwrapData(init_v) catch {
        try out.writeAll("\xe2\x9c\x97 Z.AI login failed: bad init response\n");
        try out.flush();
        return;
    }) catch {
        try out.writeAll("\xe2\x9c\x97 Z.AI login failed: bad init response\n");
        try out.flush();
        return;
    };
    const init = parseInitData(init_data) catch {
        try out.writeAll("\xe2\x9c\x97 Z.AI login failed: invalid authorize URL\n");
        try out.flush();
        return;
    };

    try out.print("\nTo log in to Z.AI Coding Plan, open this URL (browser should open automatically):\n\n  {s}\n\nwaiting for authorization\xe2\x80\xa6\n", .{init.authorize_url});
    try out.flush();
    if (!main_mod.g_no_browser) openBrowser(io, init.authorize_url);

    const poll_url = try std.fmt.allocPrint(arena, "{s}/oauth/cli/poll/{s}", .{ cli_base, init.flow_id });
    var ready: ?ReadyData = null;
    var attempts: usize = 0;
    while (attempts < 360) : (attempts += 1) {
        io.sleep(Io.Duration.fromSeconds(init.poll_interval_sec), .awake) catch {};
        const now_s: i64 = @divTrunc(util.unixMs(io), 1000);
        if (now_s >= init.expires_at) break;
        const poll_v = httpJson(io, gpa, arena, .GET, poll_url, null, &init_headers) catch continue;
        const poll_data = asObject(unwrapData(poll_v) catch continue) catch continue;
        const status = parsePollData(poll_data) catch continue;
        switch (status) {
            .pending => continue,
            .failed => {
                try out.writeAll("\xe2\x9c\x97 authorization failed \xe2\x80\x94 run `graff login zai` again\n");
                try out.flush();
                return;
            },
            .ready => |r| {
                ready = r;
                break;
            },
        }
    }
    const tokens = ready orelse {
        try out.writeAll("\xe2\x9c\x97 timed out waiting for authorization\n");
        try out.flush();
        return;
    };

    const api_key = provisionApiKey(io, gpa, arena, tokens.access_token) catch |err| {
        try out.print("\xe2\x9c\x97 signed in but could not provision a Coding Plan key: {t}\n", .{err});
        try out.flush();
        return;
    };
    try writeAuth(io, arena, home, api_key, tokens.access_token, tokens.refresh_token, init.expires_at);
    applyCodingOverride();
    try out.print("{s}\xe2\x9c\x93{s} logged into Z.AI Coding Plan \xe2\x80\x94 wrote {s}. /model zai\n", .{ style.green, style.reset, authPath(arena, home) });
    try out.flush();
}

test "isLoginName: zai aliases" {
    try std.testing.expect(isLoginName("zai"));
    try std.testing.expect(isLoginName("glm"));
    try std.testing.expect(isLoginName("z.ai"));
    try std.testing.expect(!isLoginName("xai"));
    try std.testing.expect(!isLoginName("codegraff"));
}

test "parseInitData: requires https authorize URL and positive interval" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = try parseJsonObject(a, "{\"authorize_url\":\"https://chat.z.ai/a\",\"flow_id\":\"f1\",\"expires_at\":9999999999,\"poll_interval_sec\":2}");
    const init = try parseInitData(good);
    try std.testing.expectEqualStrings("https://chat.z.ai/a", init.authorize_url);
    try std.testing.expectEqualStrings("f1", init.flow_id);
    try std.testing.expectEqual(@as(i64, 2), init.poll_interval_sec);
    const http = try parseJsonObject(a, "{\"authorize_url\":\"http://evil.example/a\",\"flow_id\":\"f1\",\"expires_at\":9,\"poll_interval_sec\":2}");
    try std.testing.expectError(error.BadOAuthResponse, parseInitData(http));
    const no_interval = try parseJsonObject(a, "{\"authorize_url\":\"https://chat.z.ai/a\",\"flow_id\":\"f1\",\"expires_at\":9,\"poll_interval_sec\":0}");
    try std.testing.expectError(error.BadOAuthResponse, parseInitData(no_interval));
}

test "parsePollData: pending, failed, ready, missing token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pending = try parseJsonObject(a, "{\"status\":\"pending\"}");
    try std.testing.expect(try parsePollData(pending) == .pending);
    const failed = try parseJsonObject(a, "{\"status\":\"failed\"}");
    try std.testing.expect(try parsePollData(failed) == .failed);
    const ready = try parseJsonObject(a, "{\"status\":\"ready\",\"token\":\"jwt\",\"zai\":{\"access_token\":\"oa\",\"refresh_token\":\"rt\"}}");
    const got = try parsePollData(ready);
    try std.testing.expectEqualStrings("oa", got.ready.access_token);
    try std.testing.expectEqualStrings("rt", got.ready.refresh_token);
    try std.testing.expectEqualStrings("jwt", got.ready.jwt);
    const missing = try parseJsonObject(a, "{\"status\":\"ready\",\"token\":\"jwt\"}");
    try std.testing.expectError(error.BadOAuthResponse, parsePollData(missing));
}

test "pickOrgAndProject: default-name match, else first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const named_json = try std.fmt.allocPrint(a, "{{\"organizations\":[{{\"organizationId\":\"o2\",\"organizationName\":\"other\",\"projects\":[{{\"projectId\":\"p2\",\"projectName\":\"x\"}}]}},{{\"organizationId\":\"o1\",\"organizationName\":\"pre {s}\",\"projects\":[{{\"projectId\":\"p0\",\"projectName\":\"skip\"}},{{\"projectId\":\"p1\",\"projectName\":\"{s}\"}}]}}]}}", .{ default_org_name, default_project_name });
    const named = try parseJsonObject(a, named_json);
    const loc = pickOrgAndProject(named).?;
    try std.testing.expectEqualStrings("o1", loc.organization_id);
    try std.testing.expectEqualStrings("p1", loc.project_id);
    const first = try parseJsonObject(a, "{\"organizations\":[{\"organizationId\":\"ox\",\"organizationName\":\"acme\",\"projects\":[{\"projectId\":\"px\",\"projectName\":\"eng\"}]}]}");
    const loc2 = pickOrgAndProject(first).?;
    try std.testing.expectEqualStrings("ox", loc2.organization_id);
    try std.testing.expectEqualStrings("px", loc2.project_id);
    const empty = try parseJsonObject(a, "{\"organizations\":[]}");
    try std.testing.expect(pickOrgAndProject(empty) == null);
}

test "findGraffKey + composeApiKey: graff-api-key and id.secret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const keys = [_]KeySummary{
        .{ .name = "other", .api_key = "aaa" },
        .{ .name = api_key_name, .api_key = "kid" },
    };
    try std.testing.expectEqualStrings("kid", findGraffKey(&keys).?);
    try std.testing.expect(findGraffKey(&.{.{ .name = "other", .api_key = "aaa" }}) == null);
    try std.testing.expectEqualStrings("kid.sec", try composeApiKey(a, "kid", "sec"));
    try std.testing.expectError(error.BadOAuthResponse, composeApiKey(a, "kid", ""));
}

test "isSuccessfulRemoteCode: 0/200 and string forms" {
    try std.testing.expect(isSuccessfulRemoteCode(null));
    try std.testing.expect(isSuccessfulRemoteCode(.{ .integer = 0 }));
    try std.testing.expect(isSuccessfulRemoteCode(.{ .integer = 200 }));
    try std.testing.expect(isSuccessfulRemoteCode(.{ .string = "0" }));
    try std.testing.expect(isSuccessfulRemoteCode(.{ .string = "200" }));
    try std.testing.expect(!isSuccessfulRemoteCode(.{ .integer = 401 }));
    try std.testing.expect(!isSuccessfulRemoteCode(.{ .string = "no" }));
}

test "writeAuth/loadZaiOAuth: 0600 file, api_key round-trip, coding URL" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const saved = provider_mod.g_zai_url_override;
    provider_mod.g_zai_url_override = null;
    defer provider_mod.g_zai_url_override = saved;

    try writeAuth(io, arena, home, "id.secret", "oa", "rt", 42);
    const credentials = try tmp.dir.openDir(io, ".zai/credentials", .{});
    defer credentials.close(io);
    const file = try credentials.openFile(io, "graff-oauth.json", .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(u32, 0o600), (try file.stat(io)).permissions.toMode() & 0o777);

    const key = loadZaiOAuth(io, std.testing.allocator, arena, home, false, null).?;
    try std.testing.expectEqualStrings("id.secret", key);
    try std.testing.expectEqualStrings(provider_mod.zai_coding_url, provider_mod.g_zai_url_override.?);
}

test "applyCodingOverride: env override wins" {
    const saved = provider_mod.g_zai_url_override;
    defer provider_mod.g_zai_url_override = saved;
    provider_mod.g_zai_url_override = "https://example.test/v4";
    applyCodingOverride();
    try std.testing.expectEqualStrings("https://example.test/v4", provider_mod.g_zai_url_override.?);
    provider_mod.g_zai_url_override = null;
    applyCodingOverride();
    try std.testing.expectEqualStrings(provider_mod.zai_coding_url, provider_mod.g_zai_url_override.?);
}

test "preferPlan parks a metered ZAI_API_KEY behind a coding-plan login" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const saved = provider_mod.g_zai_url_override;
    provider_mod.g_zai_url_override = null;
    defer provider_mod.g_zai_url_override = saved;
    credential_failover.resetForTest();
    defer credential_failover.resetForTest();

    try writeAuth(io, arena, home, "id.secret", "oa", "rt", 42);
    const spec = provider_mod.specFor("zai").?;
    var value: ?[]const u8 = "sk-metered";
    var source: provider_mod.Keys.CredentialSource = .environment;
    credential_failover.preferPlan(io, std.testing.allocator, arena, home, spec, &value, &source);
    try std.testing.expectEqualStrings("id.secret", value.?);
    try std.testing.expectEqual(provider_mod.Keys.CredentialSource.login, source);
    try std.testing.expect(credential_failover.standingBy("zai"));
}
