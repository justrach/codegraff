//! ChatGPT plan through OpenAI's sign-in for open-source apps (ADR 0221).
//!
//! The first sign-in registers Graff in the person's ChatGPT account
//! (`client_id=dynamic_agent_client` plus `agent_name_hint`); later sign-ins
//! reuse the issued `oaiapp_…` id and skip consent. Browser PKCE with an OIDC
//! nonce, a loopback callback on 127.0.0.1, and one stable
//! `ext_agent_host_id` per machine. The record lives in graff's own
//! directory, <home>/.graff/credentials/chatgpt-new.json (0600 in a 0700
//! directory); requests go to the public Responses endpoint with the access
//! token as the bearer.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const helpers = @import("oauth_helpers.zig");
const credential_store = @import("credential_store.zig");
const jwt = @import("oauth_chatgpt_jwt.zig");
const page = @import("oauth_chatgpt_page.zig");
const callback = @import("oauth_callback.zig");

const authorize_url = jwt.issuer ++ "/api/accounts/authorize";
const token_url = jwt.issuer ++ "/api/accounts/oauth/token";
const revoke_url = jwt.issuer ++ "/api/accounts/oauth/revoke";
pub const resource = "https://api.openai.com/v1";
const scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
pub const plan_scope = "chatgpt.tokens.use.direct";
pub const dynamic_client = "dynamic_agent_client";
pub const agent_name = "Graff";
/// Where sign-ins were saved before the record moved into graff's directory.
const legacy_dir = ".openai";
pub const manage_usage_url = "https://chatgpt.com/settings/usage";
/// Appended to a plan-usage failure so the person knows where to look.
pub const usage_hint = "ChatGPT plan usage limit; manage usage at " ++ manage_usage_url;
const refresh_margin_s: i64 = 300;
const callback_ports = [_]u16{ 1455, 1456, 1457, 1458, 1459 };

pub fn isLoginName(name: []const u8) bool {
    return std.mem.eql(u8, name, "chatgpt-new") or std.mem.eql(u8, name, "chat-gpt-new");
}

pub fn recordPath(arena: Allocator, home: []const u8) []const u8 {
    return credential_store.graffCredentialPath(arena, home, "chatgpt-new.json");
}

fn hostPath(arena: Allocator, home: []const u8) []const u8 {
    return credential_store.graffCredentialPath(arena, home, "chatgpt-new-host-id");
}

/// A saved sign-in, here or still at its old path. Presence only, so listing
/// providers never moves or refreshes anything.
pub fn onDisk(io: Io, arena: Allocator, home: []const u8) bool {
    for ([_][]const u8{ recordPath(arena, home), credential_store.oauthPath(arena, home, legacy_dir) }) |path| {
        if (Io.Dir.cwd().statFile(io, path, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Move a sign-in saved under <home>/.openai/credentials into graff's
/// directory, so nobody signs in again. A rename, never a copy: two copies of
/// a rotating refresh token split, and the stale one spends the sign-in.
fn adoptLegacy(io: Io, arena: Allocator, home: []const u8) void {
    const cwd = Io.Dir.cwd();
    const old_record = credential_store.oauthPath(arena, home, legacy_dir);
    const old_dir = std.fs.path.dirname(old_record) orelse return;
    const old_host = std.fmt.allocPrint(arena, "{s}/graff-host-id", .{old_dir}) catch return;
    var moved = false;
    for ([_][2][]const u8{ .{ old_record, recordPath(arena, home) }, .{ old_host, hostPath(arena, home) } }) |move| {
        _ = cwd.statFile(io, move[0], .{}) catch continue;
        if (cwd.statFile(io, move[1], .{})) |_| continue else |_| {}
        ensureDirs(io, arena, home);
        cwd.rename(move[0], cwd, move[1], io) catch continue;
        moved = true;
    }
    if (!moved) return;
    cwd.deleteFile(io, std.fmt.allocPrint(arena, "{s}.lock", .{old_record}) catch return) catch {};
    // Only once empty: another tool may keep its own files there.
    cwd.deleteDir(io, old_dir) catch return;
    cwd.deleteDir(io, std.fs.path.dirname(old_dir) orelse return) catch {};
}

/// One registration's saved sign-in, in the JSON shape OpenAI's docs show.
pub const Record = struct {
    email: []const u8 = "",
    subject: []const u8 = "",
    client_id: []const u8 = "",
    host_id: []const u8 = "",
    id_token: []const u8 = "",
    access: []const u8 = "",
    refresh: []const u8 = "",
    expires_at: i64 = 0,
    earliest_refresh_at: i64 = 0,
    scopes: []const []const u8 = &.{},
    /// The last refused renewal: when, OpenAI's code and its description.
    refresh_error: []const u8 = "",

    pub fn planEnabled(r: Record) bool {
        for (r.scopes) |s| if (std.mem.eql(u8, s, plan_scope)) return true;
        return false;
    }
};

fn splitScopes(arena: Allocator, scope: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, scope, " +");
    while (it.next()) |s| list.append(arena, s) catch break;
    return list.items;
}

pub fn parseRecord(arena: Allocator, bytes: []const u8) ?Record {
    const v = std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const o = v.object;
    var r: Record = .{
        .email = strFieldObj(o, "email") orelse "",
        .subject = strFieldObj(o, "subject") orelse "",
        .client_id = strFieldObj(o, "client_id") orelse "",
        .host_id = strFieldObj(o, "ext_agent_host_id") orelse "",
        .id_token = strFieldObj(o, "id_token") orelse "",
        .access = strFieldObj(o, "access_token") orelse "",
        .refresh = strFieldObj(o, "refresh_token") orelse "",
        .expires_at = util.intFieldObj(o, "expires_at", 0),
        .earliest_refresh_at = util.intFieldObj(o, "earliest_refresh_at", 0),
        .refresh_error = strFieldObj(o, "last_refresh_error") orelse "",
    };
    if (o.get("scopes")) |s| if (s == .array) {
        var list: std.ArrayList([]const u8) = .empty;
        for (s.array.items) |item| if (item == .string) list.append(arena, item.string) catch break;
        r.scopes = list.items;
    };
    return r;
}

pub fn serializeRecord(arena: Allocator, r: Record, saved_at: []const u8) ![]const u8 {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "email", .{ .string = r.email });
    try obj.put(arena, "issuer", .{ .string = jwt.issuer });
    try obj.put(arena, "subject", .{ .string = r.subject });
    try obj.put(arena, "client_id", .{ .string = r.client_id });
    try obj.put(arena, "ext_agent_host_id", .{ .string = r.host_id });
    try obj.put(arena, "id_token", .{ .string = r.id_token });
    try obj.put(arena, "access_token", .{ .string = r.access });
    try obj.put(arena, "refresh_token", .{ .string = r.refresh });
    try obj.put(arena, "token_type", .{ .string = "Bearer" });
    try obj.put(arena, "expires_at", .{ .integer = r.expires_at });
    try obj.put(arena, "earliest_refresh_at", .{ .integer = r.earliest_refresh_at });
    var list = std.json.Array.init(arena);
    for (r.scopes) |s| try list.append(.{ .string = s });
    try obj.put(arena, "scopes", .{ .array = list });
    try obj.put(arena, "saved_at", .{ .string = saved_at });
    if (r.refresh_error.len > 0) try obj.put(arena, "last_refresh_error", .{ .string = r.refresh_error });
    var aw: Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &aw.writer };
    try json.write(Value{ .object = obj });
    return aw.writer.buffered();
}

fn readRecord(io: Io, arena: Allocator, home: []const u8) ?Record {
    const path = recordPath(arena, home);
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| retry: {
        if (err != error.FileNotFound) return null;
        adoptLegacy(io, arena, home);
        break :retry Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    };
    return parseRecord(arena, data);
}

/// <home>/.graff keeps whatever mode it has (it holds sessions too); the
/// credentials directory under it is owner-only.
fn ensureDirs(io: Io, arena: Allocator, home: []const u8) void {
    const credentials = std.fs.path.dirname(recordPath(arena, home)) orelse return;
    Io.Dir.cwd().createDir(io, std.fs.path.dirname(credentials) orelse return, credential_store.private_dir) catch {};
    Io.Dir.cwd().createDir(io, credentials, credential_store.private_dir) catch {};
    // iterate=true: a default openDir can be O_PATH on Linux, where fchmod panics.
    const dir = Io.Dir.cwd().openDir(io, credentials, .{ .iterate = true }) catch return;
    defer dir.close(io);
    if (builtin.os.tag != .windows) dir.setPermissions(io, credential_store.private_dir) catch {};
}

fn writeRecord(io: Io, arena: Allocator, home: []const u8, r: Record) !void {
    ensureDirs(io, arena, home);
    var stamp: [24]u8 = undefined;
    const text = try serializeRecord(arena, r, helpers.rfc3339Utc(&stamp, util.unixMs(io)));
    try credential_store.replaceFile(io, Io.Dir.cwd(), recordPath(arena, home), text, credential_store.private_file);
}

/// A version-4 UUID as the `urn:uuid:` host id OpenAI accepts.
pub fn formatHostId(bytes: [16]u8) [45]u8 {
    var b = bytes;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(b, .lower);
    var out: [45]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "urn:uuid:{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    return out;
}

/// This machine's stable host id, created once before the first sign-in.
fn hostId(io: Io, arena: Allocator, home: []const u8) ![]const u8 {
    const path = hostPath(arena, home);
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256))) |data| {
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    } else |_| {}
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const id = try arena.dupe(u8, &formatHostId(bytes));
    ensureDirs(io, arena, home);
    try credential_store.replaceFile(io, Io.Dir.cwd(), path, try std.fmt.allocPrint(arena, "{s}\n", .{id}), credential_store.private_file);
    return id;
}

pub fn percentEncode(arena: Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~')
            try out.append(arena, c)
        else
            try out.appendSlice(arena, &.{ '%', hex[c >> 4], hex[c & 15] });
    }
    return out.items;
}

pub fn percentDecode(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '+') {
            try out.append(arena, ' ');
        } else if (s[i] == '%' and i + 2 < s.len) {
            const byte = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(arena, '%');
                continue;
            };
            try out.append(arena, byte);
            i += 2;
        } else try out.append(arena, s[i]);
    }
    return out.items;
}

fn form(arena: Allocator, pairs: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |p, i| {
        if (i > 0) try out.append(arena, '&');
        try out.appendSlice(arena, p[0]);
        try out.append(arena, '=');
        try out.appendSlice(arena, try percentEncode(arena, p[1]));
    }
    return out.items;
}

/// Everything one authorization attempt sends, held until its callback.
pub const Attempt = struct {
    client_id: []const u8,
    redirect: []const u8,
    state: []const u8,
    nonce: []const u8,
    challenge: []const u8,
    host_id: []const u8,
    login_hint: []const u8 = "",
};

pub fn authorizeUrl(arena: Allocator, a: Attempt) ![]const u8 {
    var pairs: std.ArrayList([2][]const u8) = .empty;
    try pairs.appendSlice(arena, &.{
        .{ "client_id", a.client_id },       .{ "response_type", "code" },       .{ "redirect_uri", a.redirect },
        .{ "scope", scopes },                .{ "resource", resource },          .{ "state", a.state },
        .{ "nonce", a.nonce },               .{ "code_challenge", a.challenge }, .{ "code_challenge_method", "S256" },
        .{ "ext_agent_host_id", a.host_id },
    });
    // The name hint belongs only to a first registration.
    if (std.mem.eql(u8, a.client_id, dynamic_client)) try pairs.append(arena, .{ "agent_name_hint", agent_name });
    // No id_token_hint: the browser opener gets this URL as a process
    // argument any local process can read, so it carries no saved token.
    // The issued client id and the email hint keep a returning sign-in
    // consent-free, and finish() checks the account still matches.
    if (a.login_hint.len > 0) try pairs.append(arena, .{ "login_hint", a.login_hint });
    return std.fmt.allocPrint(arena, "{s}?{s}", .{ authorize_url, try form(arena, pairs.items) });
}

pub const Callback = struct { code: []const u8 = "", state: []const u8 = "", client_id: []const u8 = "", err: []const u8 = "", err_desc: []const u8 = "" };

/// The callback's query, or null when the request line is some other path
/// (a browser also asks for /favicon.ico).
pub fn parseCallback(arena: Allocator, req_line: []const u8) ?Callback {
    var parts = std.mem.tokenizeScalar(u8, req_line, ' ');
    _ = parts.next() orelse return null;
    const target = parts.next() orelse return null;
    const q = std.mem.indexOfScalar(u8, target, '?');
    if (!std.mem.eql(u8, target[0 .. q orelse target.len], "/auth/callback")) return null;
    var cb: Callback = .{};
    var it = std.mem.tokenizeScalar(u8, if (q) |i| target[i + 1 ..] else "", '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const value = percentDecode(arena, pair[eq + 1 ..]) catch continue;
        const key = pair[0..eq];
        if (std.mem.eql(u8, key, "code")) cb.code = value else if (std.mem.eql(u8, key, "state")) cb.state = value else if (std.mem.eql(u8, key, "client_id")) cb.client_id = value else if (std.mem.eql(u8, key, "error")) cb.err = value else if (std.mem.eql(u8, key, "error_description")) cb.err_desc = value;
    }
    return cb;
}

fn randomToken(io: Io, arena: Allocator, comptime n: usize) []const u8 {
    var bytes: [n]u8 = undefined;
    io.random(&bytes);
    return helpers.b64url(arena, &bytes);
}

const Listener = struct { server: std.Io.net.Server, port: u16 };

fn listen(io: Io) !Listener {
    for (callback_ports) |port| {
        var buf: [32]u8 = undefined;
        const literal = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
        const addr = std.Io.net.IpAddress.parseLiteral(literal) catch continue;
        const server = std.Io.net.IpAddress.listen(&addr, io, .{}) catch continue;
        return .{ .server = server, .port = port };
    }
    return error.NoCallbackPort;
}

const Outcome = struct { state: page.State, account: []const u8 = "", detail: []const u8 = "" };

fn failed(detail: []const u8) Outcome {
    return .{ .state = .@"error", .detail = detail };
}

/// Validate the callback, exchange the code, check the ID token, save.
fn finish(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, saved: ?Record, a: Attempt, verifier: []const u8, cb: Callback) Outcome {
    if (!std.mem.eql(u8, cb.state, a.state)) return failed("the callback's state did not match this sign-in");
    if (std.mem.eql(u8, cb.err, "access_denied")) return .{ .state = .denied };
    if (cb.err.len > 0) return failed(std.fmt.allocPrint(arena, "{s} {s}", .{ cb.err, cb.err_desc }) catch cb.err);
    if (cb.code.len == 0) return failed("the callback carried no code");
    const returning = !std.mem.eql(u8, a.client_id, dynamic_client);
    if (returning and cb.client_id.len > 0 and !std.mem.eql(u8, cb.client_id, a.client_id)) return failed("the callback named a different app registration");
    if (!returning and (cb.client_id.len == 0 or std.mem.eql(u8, cb.client_id, dynamic_client))) return failed("the registration returned no app id");
    const issued = if (returning) a.client_id else cb.client_id;
    const body = form(arena, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", issued }, .{ "code", cb.code }, .{ "code_verifier", verifier }, .{ "redirect_uri", a.redirect }, .{ "resource", resource } }) catch return failed("out of memory");
    const tok = helpers.oauthFormPost(io, gpa, arena, token_url, body) catch |err| return failed(@errorName(err));
    if (tok.get("error")) |e| return failed(if (e == .string) e.string else "the token exchange failed");
    const access = strFieldObj(tok, "access_token") orelse return failed("the token response had no access token");
    const id_token = strFieldObj(tok, "id_token") orelse "";
    const now_s = @divTrunc(util.unixMs(io), 1000);
    const claims = jwt.verify(io, gpa, arena, id_token, issued, a.nonce, now_s) catch |err| return failed(@errorName(err));
    if (saved) |s| if (returning and s.subject.len > 0 and !std.mem.eql(u8, s.subject, claims.sub))
        return failed("signed in as a different ChatGPT account than this registration");
    const record: Record = .{
        .email = claims.email,
        .subject = claims.sub,
        .client_id = issued,
        .host_id = a.host_id,
        .id_token = id_token,
        .access = access,
        .refresh = strFieldObj(tok, "refresh_token") orelse "",
        .expires_at = now_s + util.intFieldObj(tok, "expires_in", 3600),
        .earliest_refresh_at = util.intFieldObj(tok, "earliest_refresh_at", 0),
        .scopes = splitScopes(arena, strFieldObj(tok, "scope") orelse ""),
    };
    writeRecord(io, arena, home, record) catch |err| return failed(@errorName(err));
    const state: page.State = if (!record.planEnabled()) .noplan else if (returning) .ok else .first;
    return .{ .state = state, .account = claims.email };
}

fn report(out: *Io.Writer, o: Outcome) !void {
    switch (o.state) {
        .first, .ok => try out.print("✓ signed in to ChatGPT as {s}; plan usage is on. Use it with /model chatgpt-new or `graff --model chatgpt-new/gpt-6.1-sol`. Manage usage: {s}\n", .{ o.account, manage_usage_url }),
        .noplan => try out.print("✓ signed in to ChatGPT as {s}, but plan usage was not allowed. Run `graff login chatgpt` again and allow it, or use an API key.\n", .{o.account}),
        .denied => try out.writeAll("✗ ChatGPT sign-in was cancelled. Nothing changed.\n"),
        .@"error" => try out.print("✗ ChatGPT sign-in failed: {s}\n", .{o.detail}),
    }
    try out.flush();
}

/// `graff login chatgpt`: open the browser, wait for the loopback callback,
/// answer it with the branded page, and save the record.
pub fn login(io: Io, gpa: Allocator, arena: Allocator, home: []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;
    const saved = readRecord(io, arena, home);
    const returning = if (saved) |s| s.client_id.len > 0 else false;
    const verifier = randomToken(io, arena, 48);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var listener = try listen(io);
    defer listener.server.deinit(io);
    const attempt: Attempt = .{
        .client_id = if (returning) saved.?.client_id else dynamic_client,
        .redirect = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/auth/callback", .{listener.port}),
        .state = randomToken(io, arena, 24),
        .nonce = randomToken(io, arena, 24),
        .challenge = helpers.b64url(arena, &digest),
        .host_id = try hostId(io, arena, home),
        .login_hint = if (returning) saved.?.email else "",
    };
    const url = try authorizeUrl(arena, attempt);
    try out.print("\nSign in with ChatGPT (your browser should open it):\n\n{s}\n", .{url});
    try @import("signin_link.zig").offer(io, out, url);
    try out.print("\nwaiting for the sign-in on {s} …\n", .{attempt.redirect});
    try out.flush();
    @import("signin_link.zig").open(io, url);
    // Only this attempt's redirect ends the wait; a tab left from an earlier
    // attempt gets a page saying so (oauth_callback.zig).
    var rbuf: [16 * 1024]u8 = undefined;
    const conn = callback.wait(io, &listener.server, "/auth/callback", attempt.state, &rbuf) catch |err| {
        if (err != error.Cancelled) return err;
        return report(out, failed("a newer sign-in took over the callback port"));
    };
    defer conn.stream.close(io);
    const cb = parseCallback(arena, conn.line) orelse return report(out, failed("the callback could not be read"));
    // The browser waits on this response, so the page shows the outcome.
    const outcome = finish(io, gpa, arena, home, saved, attempt, verifier, cb);
    callback.answer(io, conn.stream, page.response(arena, outcome.state, outcome.account) catch page.not_found);
    return report(out, outcome);
}

var dead_refresh: u64 = 0;

/// OpenAI rotates the refresh token on every grant and asks apps to serialize
/// refreshes for one session: a process that loses the race presents a
/// replaced token (`refresh_token_reused`) and the person must sign in again.
/// The lock sits beside the record (flock / NtLockFile). A filesystem without
/// working locks degrades to the unlocked refresh.
pub fn lockRecord(io: Io, arena: Allocator, home: []const u8) ?Io.File {
    ensureDirs(io, arena, home);
    const path = std.fmt.allocPrint(arena, "{s}.lock", .{recordPath(arena, home)}) catch return null;
    return Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive }) catch null;
}

/// Refresh under the lock, against the record as it is now: another graff
/// may have refreshed while this one waited, and its replacement is then the
/// only live refresh token. `before` is what the caller read before locking.
/// Null when the sign-in is gone.
pub fn refreshLocked(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, before: Record) ?[]const u8 {
    const lock = lockRecord(io, arena, home);
    defer if (lock) |f| f.close(io);
    const current = readRecord(io, arena, home) orelse return null;
    if (current.access.len == 0 or !current.planEnabled()) return null;
    if (!std.mem.eql(u8, current.refresh, before.refresh)) return current.access;
    const next = refreshed(io, gpa, arena, home, current) orelse return current.access;
    return next.access;
}

/// OpenAI: clear an unusable refresh token so no process replays it. The
/// access token stays until it expires; after that the request error says to
/// sign in again. Called with the record lock held.
/// Keep OpenAI's answer to a refused renewal in the record: otherwise the
/// refresh fails silently and only the later 401 shows. A code OpenAI calls
/// unusable also clears the refresh token; the access token stays until it
/// expires, and the issued client id lets the next sign-in skip registration.
pub fn recordRefreshFailure(io: Io, arena: Allocator, home: []const u8, r: Record, code: []const u8, description: []const u8) void {
    var next = r;
    var stamp: [24]u8 = undefined;
    next.refresh_error = std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ helpers.rfc3339Utc(&stamp, util.unixMs(io)), code, description }) catch code;
    if (helpers.permanentRefreshFailure(code)) next.refresh = "";
    writeRecord(io, arena, home, next) catch {};
}

fn refreshed(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, r: Record) ?Record {
    const id = std.hash.Wyhash.hash(0, r.refresh);
    if (id == dead_refresh) return null; // known dead: no round trip
    const body = form(arena, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", r.client_id }, .{ "refresh_token", r.refresh }, .{ "resource", resource } }) catch return null;
    const tok = helpers.oauthFormPost(io, gpa, arena, token_url, body) catch return null; // transient: keep everything
    if (tok.get("error")) |e| {
        const code = if (e == .string) e.string else "";
        if (helpers.permanentRefreshFailure(code)) dead_refresh = id;
        recordRefreshFailure(io, arena, home, r, code, strFieldObj(tok, "error_description") orelse "");
        return null;
    }
    const now_s = @divTrunc(util.unixMs(io), 1000);
    var next = r;
    next.access = strFieldObj(tok, "access_token") orelse return null;
    next.refresh = strFieldObj(tok, "refresh_token") orelse r.refresh;
    next.expires_at = now_s + util.intFieldObj(tok, "expires_in", 3600);
    next.earliest_refresh_at = util.intFieldObj(tok, "earliest_refresh_at", 0);
    if (strFieldObj(tok, "scope")) |s| next.scopes = splitScopes(arena, s);
    if (strFieldObj(tok, "id_token")) |t| {
        if (jwt.verify(io, gpa, arena, t, r.client_id, null, now_s)) |claims| {
            // Tokens for another account must never run under this sign-in
            // (OpenAI's SIWC DevKit refuses them as account_mismatch). The
            // grant already rotated, so this ends the session: sign in again.
            if (r.subject.len > 0 and !std.mem.eql(u8, claims.sub, r.subject)) {
                recordRefreshFailure(io, arena, home, r, "account_mismatch", "the renewed sign-in belongs to a different ChatGPT account");
                return null;
            }
            next.id_token = t;
        } else |_| {}
    }
    // The grant rotated the refresh token: an unwritten record is a logout.
    writeRecord(io, arena, home, next) catch writeRecord(io, arena, home, next) catch |err| {
        helpers.persist_error = @errorName(err);
    };
    return next;
}

/// The access token for requests, refreshed near expiry or when `force`d by
/// a 401. Null when signed out or when plan usage was not granted.
/// oauth.refreshOAuthKey's mutex serializes refreshes within this process and
/// the record lock serializes them across graff processes.
pub fn loadChatgptOAuth(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, force: bool, stale: ?[]const u8) ?[]const u8 {
    const r = readRecord(io, arena, home) orelse return null;
    if (r.access.len == 0 or !r.planEnabled()) return null;
    if (helpers.supersededToken(force, r.access, stale)) return r.access;
    const now_s = @divTrunc(util.unixMs(io), 1000);
    // OpenAI answers a refresh before earliest_refresh_at with invalid_grant,
    // which reads as a dead token. Not even a 401 may spend it early.
    if (now_s < r.earliest_refresh_at) return r.access;
    const due = r.expires_at != 0 and now_s >= r.expires_at - refresh_margin_s;
    if (!(force or due) or r.refresh.len == 0) return r.access;
    return refreshLocked(io, gpa, arena, home, r);
}

/// Sign out: revoke the refresh token, then clear the tokens. The app id,
/// account and host id stay so the next sign-in skips registration.
pub fn logout(io: Io, gpa: Allocator, arena: Allocator, home: []const u8) !void {
    var obuf: [1024]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;
    var r = readRecord(io, arena, home) orelse {
        try out.writeAll("not signed in to ChatGPT\n");
        return out.flush();
    };
    if (r.refresh.len > 0) {
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        const body = try form(arena, &.{ .{ "token", r.refresh }, .{ "token_type_hint", "refresh_token" }, .{ "client_id", r.client_id } });
        _ = client.fetch(.{ .location = .{ .url = revoke_url }, .method = .POST, .payload = body, .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } } }) catch {};
    }
    r.access = "";
    r.refresh = "";
    r.id_token = "";
    r.scopes = &.{};
    r.expires_at = 0;
    try writeRecord(io, arena, home, r);
    try out.writeAll("✓ signed out of ChatGPT on this computer\n");
    try out.flush();
}

test {
    _ = .{ @import("oauth_chatgpt_tests.zig"), @import("oauth_chatgpt_jwt.zig"), @import("oauth_chatgpt_page.zig") };
}
