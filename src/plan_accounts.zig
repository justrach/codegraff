//! Account identity and quota collection across all signed-in providers
//! (`codex`, `chatgpt-new`, `anthropic`, `claude-agent`, `xai`, `codegraff`,
//! `kimi`). Never emits bearer tokens, refresh tokens, or raw API keys.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const claude_agent_login = @import("claude_agent_login.zig");
const oauth = @import("oauth.zig");
const oauth_anthropic = @import("oauth_anthropic.zig");
const oauth_chatgpt = @import("oauth_chatgpt.zig");
const oauth_codegraff = @import("oauth_codegraff.zig");
const plan_usage = @import("plan_usage.zig");
const probe = @import("plan_accounts_probe.zig");
const provider_mod = @import("provider.zig");
const store = @import("credential_store.zig");
const util = @import("util.zig");

pub const AccountEntry = struct {
    provider: []const u8,
    authenticated: bool,
    auth_kind: []const u8,
    email: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    organization: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    windows: []const plan_usage.Window = &.{},
    prepaid_cents: ?i64 = null,
    reset_credits: ?f64 = null,
    note: ?[]const u8 = null,
};

pub const JwtClaims = struct {
    email: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    plan: ?[]const u8 = null,
};

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len > 0) s else null;
}

pub fn extractJwtClaims(arena: Allocator, token: []const u8) JwtClaims {
    const dot1 = std.mem.indexOfScalar(u8, token, '.') orelse return .{};
    const rest = token[dot1 + 1 ..];
    const dot2 = std.mem.indexOfScalar(u8, rest, '.') orelse return .{};
    const b64 = std.mem.trimEnd(u8, rest[0..dot2], "=");
    if (b64.len == 0) return .{};
    const dec = std.base64.url_safe_no_pad.Decoder;
    const len = dec.calcSizeForSlice(b64) catch return .{};
    const decoded = arena.alloc(u8, len) catch return .{};
    dec.decode(decoded, b64) catch return .{};
    const v = std.json.parseFromSliceLeaky(Value, arena, decoded, .{ .allocate = .alloc_always }) catch return .{};
    if (v != .object) return .{};
    var out: JwtClaims = .{
        .email = util.strFieldObj(v.object, "email"),
        .display_name = util.strFieldObj(v.object, "name") orelse util.strFieldObj(v.object, "given_name"),
        .account_id = util.strFieldObj(v.object, "chatgpt_account_id"),
        .plan = util.strFieldObj(v.object, "chatgpt_plan_type"),
    };
    if (v.object.get("https://api.openai.com/auth")) |auth| if (auth == .object) {
        if (out.account_id == null) out.account_id = util.strFieldObj(auth.object, "chatgpt_account_id");
        if (out.plan == null) out.plan = util.strFieldObj(auth.object, "chatgpt_plan_type");
    };
    return out;
}

fn readJsonObject(io: Io, arena: Allocator, path: []const u8) ?std.json.ObjectMap {
    if (path.len == 0) return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    return if (v == .object) v.object else null;
}

fn mergeLive(io: Io, arena: Allocator, provider: []const u8, entry: *AccountEntry) void {
    const live = (probe.liveWindows(io, arena, provider) catch null) orelse return;
    if (entry.windows.len == 0) entry.windows = live.windows;
    if (entry.plan == null and live.plan.len > 0) entry.plan = live.plan;
    if (entry.reset_credits == null) entry.reset_credits = live.credits;
}

fn authKindForKey(keys: *const provider_mod.Keys, provider: []const u8) []const u8 {
    return switch (keys.source(provider)) {
        .login => "oauth",
        .profile => "profile",
        .environment, .stored, .session => "api_key",
        .none => "none",
    };
}

fn collectCodex(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: *const provider_mod.Keys, include_usage: bool) ?AccountEntry {
    var access: []const u8 = "";
    var account_id: []const u8 = "";
    var id_token: []const u8 = "";
    if (oauth.codexHomeDir(arena, home)) |dir| {
        const path = std.fmt.allocPrint(arena, "{s}/auth.json", .{dir}) catch "";
        if (readJsonObject(io, arena, path)) |root| {
            if (root.get("tokens")) |tv| if (tv == .object) {
                access = util.strFieldObj(tv.object, "access_token") orelse "";
                account_id = util.strFieldObj(tv.object, "account_id") orelse "";
                id_token = util.strFieldObj(tv.object, "id_token") orelse "";
            };
        }
    }
    if (access.len == 0) if (oauth.loadCodexAuth(io, arena, home)) |a| {
        access = a.token;
        account_id = a.account;
    };
    const key_src = keys.source("codex");
    const has_key = access.len > 0 or keys.get("codex") != null;
    if (!has_key) return null;

    const id_c = extractJwtClaims(arena, id_token);
    const ac_c = extractJwtClaims(arena, access);
    var entry: AccountEntry = .{
        .provider = "codex",
        .authenticated = true,
        .auth_kind = if (access.len > 0) "oauth" else authKindForKey(keys, "codex"),
        .email = id_c.email orelse ac_c.email,
        .display_name = id_c.display_name orelse ac_c.display_name,
        .plan = id_c.plan orelse ac_c.plan,
    };
    const now_s = @divTrunc(util.unixMs(io), 1000);
    if (include_usage and access.len > 0 and key_src != .environment) {
        if (probe.probeCodexAt(io, gpa, arena, "https://chatgpt.com/backend-api/wham/usage", access, account_id, now_s)) |r| {
            entry.windows = r.windows;
            if (nonEmpty(r.plan)) |p| entry.plan = p;
            entry.reset_credits = r.reset_credits;
        }
    }
    mergeLive(io, arena, "codex", &entry);
    return entry;
}

fn collectChatgptNew(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: *const provider_mod.Keys, include_usage: bool) ?AccountEntry {
    const rec: ?oauth_chatgpt.Record = if (home.len > 0) blk: {
        const bytes = Io.Dir.cwd().readFileAlloc(io, oauth_chatgpt.recordPath(arena, home), arena, .limited(64 * 1024)) catch break :blk null;
        break :blk oauth_chatgpt.parseRecord(arena, bytes);
    } else null;
    const disk_token = if (rec) |r| r.access else "";
    const tok = if (include_usage and rec != null and rec.?.planEnabled())
        oauth_chatgpt.loadChatgptOAuth(io, gpa, arena, home, false, null) orelse disk_token
    else if (disk_token.len > 0)
        disk_token
    else
        keys.get("chatgpt-new") orelse "";
    if (tok.len == 0) return null;

    const id_c = extractJwtClaims(arena, if (rec) |r| r.id_token else "");
    const ac_c = extractJwtClaims(arena, tok);
    var entry: AccountEntry = .{
        .provider = "chatgpt-new",
        .authenticated = true,
        .auth_kind = if (rec != null or keys.source("chatgpt-new") == .login) "oauth" else authKindForKey(keys, "chatgpt-new"),
        .email = (if (rec) |r| nonEmpty(r.email) else null) orelse id_c.email orelse ac_c.email,
        .display_name = id_c.display_name orelse ac_c.display_name,
        .plan = id_c.plan orelse ac_c.plan,
    };
    const acct_id = ac_c.account_id orelse id_c.account_id orelse "";
    const now_s = @divTrunc(util.unixMs(io), 1000);
    if (include_usage and (rec == null or rec.?.planEnabled())) {
        if (probe.probeCodexAt(io, gpa, arena, "https://api.openai.com/api/codex/usage", tok, acct_id, now_s) orelse
            probe.probeCodexAt(io, gpa, arena, "https://chatgpt.com/backend-api/wham/usage", tok, acct_id, now_s)) |r|
        {
            entry.windows = r.windows;
            if (nonEmpty(r.plan)) |p| entry.plan = p;
            entry.reset_credits = r.reset_credits;
        }
    }
    mergeLive(io, arena, "chatgpt-new", &entry);
    return entry;
}

fn collectAnthropic(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: *const provider_mod.Keys, include_usage: bool) ?AccountEntry {
    const rec = if (home.len > 0) oauth_anthropic.readRecord(io, arena, home) else null;
    const key_tok = keys.get("anthropic");
    if (rec == null and key_tok == null) return null;

    var entry: AccountEntry = .{
        .provider = "anthropic",
        .authenticated = true,
        .auth_kind = if (rec != null) "oauth" else authKindForKey(keys, "anthropic"),
        .email = if (rec) |r| nonEmpty(r.email) else null,
        .display_name = if (rec) |r| nonEmpty(r.display_name) else null,
        .organization = if (rec) |r| nonEmpty(r.organization) else null,
        .plan = if (rec) |r| nonEmpty(r.plan) else null,
    };
    const now_s = @divTrunc(util.unixMs(io), 1000);
    if (include_usage and rec != null) {
        const tok = oauth_anthropic.loadAnthropicOAuth(io, gpa, arena, home, false, null) orelse rec.?.access;
        const has_prof = entry.email != null and entry.plan != null;
        if (probe.probeAnthropicOAuth(io, gpa, arena, home, tok, now_s, has_prof)) |r| {
            if (r.windows.len > 0) entry.windows = r.windows;
            if (r.email) |e| entry.email = e;
            if (r.display_name) |d| entry.display_name = d;
            if (r.organization) |o| entry.organization = o;
            if (nonEmpty(r.plan)) |p| entry.plan = p;
            if (nonEmpty(r.note)) |n| entry.note = n;
        }
    }
    mergeLive(io, arena, "anthropic", &entry);
    return entry;
}

fn collectClaudeAgent(io: Io, arena: Allocator, home: []const u8, keys: *const provider_mod.Keys, include_usage: bool) ?AccountEntry {
    const marker = claude_agent_login.readMarker(io, arena, home);
    const has_key = keys.get("claude-agent") != null;
    if (marker == null and !has_key) return null;
    var email: []const u8 = if (marker) |m| m.email else "";
    var org: []const u8 = if (marker) |m| m.organization else "";
    var plan: []const u8 = if (marker) |m| m.plan else "";
    const exe: []const u8 = if (marker) |m| m.claude else "claude";

    if (include_usage and (email.len == 0 or plan.len == 0)) {
        if (claude_agent_login.status(io, arena, exe)) |st| {
            if (st.logged_in) {
                if (st.email.len > 0) email = st.email;
                if (st.organization.len > 0) org = st.organization;
                if (st.plan.len > 0) plan = st.plan;
                if (marker != null) claude_agent_login.saveMarker(io, arena, home, .{ .claude = exe, .email = email, .organization = org, .plan = plan }) catch {};
            }
        } else |_| {}
    }
    var entry: AccountEntry = .{
        .provider = "claude-agent",
        .authenticated = true,
        .auth_kind = "cli",
        .email = nonEmpty(email),
        .organization = nonEmpty(org),
        .plan = nonEmpty(plan),
    };
    mergeLive(io, arena, "claude-agent", &entry);
    return entry;
}

fn collectXai(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: *const provider_mod.Keys, include_usage: bool) ?AccountEntry {
    const disk_obj = if (home.len > 0) readJsonObject(io, arena, store.oauthPath(arena, home, ".xai")) else null;
    const disk_tok = if (disk_obj) |o| util.strFieldObj(o, "access_token") orelse "" else "";
    const oauth_tok = if (include_usage and disk_tok.len > 0)
        oauth.loadXaiOAuth(io, gpa, arena, home, false, null) orelse disk_tok
    else
        disk_tok;
    const api_tok = keys.get("xai");
    const is_oauth = oauth_tok.len > 0 and (keys.source("xai") == .none or keys.source("xai") == .login);
    if (oauth_tok.len == 0 and api_tok == null) return null;

    const claims = extractJwtClaims(arena, if (is_oauth) oauth_tok else (api_tok orelse ""));
    var entry: AccountEntry = .{
        .provider = "xai",
        .authenticated = true,
        .auth_kind = if (is_oauth) "oauth" else authKindForKey(keys, "xai"),
        .email = (if (disk_obj) |o| util.strFieldObj(o, "email") else null) orelse claims.email,
        .display_name = claims.display_name,
        .plan = if (disk_obj) |o| util.strFieldObj(o, "plan") else null,
    };
    const now_s = @divTrunc(util.unixMs(io), 1000);
    if (include_usage) {
        if (is_oauth) {
            if (probe.probeGrokBilling(io, gpa, arena, oauth_tok, now_s)) |r| {
                entry.windows = r.windows;
                if (nonEmpty(r.plan)) |p| entry.plan = p;
                entry.prepaid_cents = r.prepaid_cents;
            }
        }
        if (entry.windows.len == 0) {
            if (plan_usage.fetchXaiHeaders(io, gpa, arena, home, if (is_oauth) null else api_tok)) |maybe| {
                if (maybe) |r| {
                    entry.windows = r.windows;
                    if (nonEmpty(r.note)) |n| entry.note = n;
                }
            } else |_| {}
        }
    }
    mergeLive(io, arena, "xai", &entry);
    return entry;
}

fn collectSimpleOAuthOrKey(io: Io, arena: Allocator, home: []const u8, keys: *const provider_mod.Keys, provider: []const u8, oauth_dir: ?[]const u8) ?AccountEntry {
    const obj = if (home.len > 0 and oauth_dir != null) readJsonObject(io, arena, store.oauthPath(arena, home, oauth_dir.?)) else null;
    const oauth_tok = if (obj) |o| util.strFieldObj(o, "access_token") orelse "" else "";
    const codegraff_disk = if (std.mem.eql(u8, provider, "codegraff") and home.len > 0) oauth_codegraff.loadKey(io, arena, home) else null;
    const key_tok = keys.get(provider);
    if (oauth_tok.len == 0 and codegraff_disk == null and key_tok == null) return null;
    const tok = if (oauth_tok.len > 0) oauth_tok else (codegraff_disk orelse key_tok.?);
    const claims = extractJwtClaims(arena, tok);
    return .{
        .provider = provider,
        .authenticated = true,
        .auth_kind = if (oauth_tok.len > 0) "oauth" else if (codegraff_disk != null) "api_key" else authKindForKey(keys, provider),
        .email = (if (obj) |o| util.strFieldObj(o, "email") else null) orelse claims.email,
        .display_name = claims.display_name,
        .organization = if (obj) |o| util.strFieldObj(o, "organization") else null,
        .plan = if (obj) |o| util.strFieldObj(o, "plan") else null,
    };
}

pub fn collectAccounts(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: *const provider_mod.Keys, include_usage: bool) ![]AccountEntry {
    var list: std.ArrayList(AccountEntry) = .empty;
    if (collectCodex(io, gpa, arena, home, keys, include_usage)) |e| try list.append(arena, e);
    if (collectChatgptNew(io, gpa, arena, home, keys, include_usage)) |e| try list.append(arena, e);
    if (collectAnthropic(io, gpa, arena, home, keys, include_usage)) |e| try list.append(arena, e);
    if (collectClaudeAgent(io, arena, home, keys, include_usage)) |e| try list.append(arena, e);
    if (collectXai(io, gpa, arena, home, keys, include_usage)) |e| try list.append(arena, e);
    if (collectSimpleOAuthOrKey(io, arena, home, keys, "codegraff", null)) |e| try list.append(arena, e);
    if (collectSimpleOAuthOrKey(io, arena, home, keys, "kimi", ".kimi")) |e| try list.append(arena, e);
    return try list.toOwnedSlice(arena);
}

fn renderAccount(out: *Io.Writer, e: AccountEntry) !void {
    try out.print("{s} ({s})\n", .{ e.provider, e.auth_kind });
    try plan_usage.renderWindows(out, .{
        .provider = e.provider,
        .plan = e.plan orelse "",
        .email = e.email,
        .display_name = e.display_name,
        .organization = e.organization,
        .auth_kind = e.auth_kind,
        .windows = e.windows,
        .prepaid_cents = e.prepaid_cents,
        .reset_credits = e.reset_credits,
        .note = e.note orelse "",
    });
}

pub fn appendUsageTo(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: *const provider_mod.Keys, active_provider: []const u8, out: *Io.Writer) void {
    const accounts = collectAccounts(io, gpa, arena, home, keys, true) catch return;
    for (accounts) |e| if (std.mem.eql(u8, e.provider, active_provider)) renderAccount(out, e) catch return;
    for (accounts) |e| {
        if (std.mem.eql(u8, e.provider, active_provider)) continue;
        if (e.windows.len == 0 and e.email == null and e.plan == null and e.prepaid_cents == null and e.reset_credits == null) continue;
        renderAccount(out, e) catch return;
    }
}

test "extractJwtClaims decodes email, display name, and chatgpt_plan_type without secrets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const payload = "{\"email\":\"user@example.com\",\"name\":\"Ada Lovelace\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_1\",\"chatgpt_plan_type\":\"pro\"}}";
    var b64_buf: [256]u8 = undefined;
    const enc = std.base64.url_safe_no_pad.Encoder.encode(&b64_buf, payload);
    const jwt = try std.fmt.allocPrint(a, "eyJhbGciOiJub25lIn0.{s}.sig", .{enc});
    const claims = extractJwtClaims(a, jwt);
    try std.testing.expectEqualStrings("user@example.com", claims.email.?);
    try std.testing.expectEqualStrings("Ada Lovelace", claims.display_name.?);
    try std.testing.expectEqualStrings("acct_1", claims.account_id.?);
    try std.testing.expectEqualStrings("pro", claims.plan.?);
}

test "collectAccounts reads disk metadata and live cache without network when include_usage is false" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const live = @import("plan_usage_live.zig");
    live.resetForTest();
    defer live.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = try a.dupe(u8, pbuf[0..try tmp.dir.realPath(std.testing.io, &pbuf)]);
    const ant_dir = try std.fmt.allocPrint(a, "{s}/.anthropic/credentials", .{root_path});
    const graff_dir = try std.fmt.allocPrint(a, "{s}/.graff/credentials", .{root_path});
    try Io.Dir.cwd().createDirPath(std.testing.io, ant_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, graff_dir);
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/graff-oauth.json", .{ant_dir}),
        .data = "{\"access_token\":\"sk-ant-oat-secret\",\"refresh_token\":\"rt\",\"expires_at\":4102444800,\"email\":\"ant@example.com\",\"organization\":\"Acme\",\"plan\":\"Claude Max\"}",
    });
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/claude-agent.json", .{graff_dir}),
        .data = "{\"claude\":\"claude\",\"email\":\"ca@example.com\",\"organization\":\"Lab\",\"plan\":\"max\"}",
    });
    live.noteClaudeRateLimit(std.testing.io, "claude-fable-5-2", .{ .status = "allowed_warning", .rate_limit_type = "fable", .utilization = 0.6 });

    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    const entries = try collectAccounts(std.testing.io, std.testing.allocator, a, root_path, &keys, false);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("anthropic", entries[0].provider);
    try std.testing.expectEqualStrings("ant@example.com", entries[0].email.?);
    try std.testing.expectEqualStrings("Claude Max", entries[0].plan.?);
    try std.testing.expectEqualStrings("claude-agent", entries[1].provider);
    try std.testing.expectEqualStrings("ca@example.com", entries[1].email.?);
    try std.testing.expectEqualStrings("Fable", entries[1].windows[0].label);
    try std.testing.expectApproxEqAbs(@as(f64, 40), entries[1].windows[0].remaining_percent, 0.01);
}
