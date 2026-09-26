//! `graff peer` on codegraff's backend: the account's swarm channel (gateway
//! /v1/swarm), so agents on other machines, cloud agents and the Harness app
//! share one place to talk. Opt-in per machine — `graff peer cloud on` — and
//! local rooms stay the default: nothing leaves the device until it is on.
//!
//! Members are named like hub agents (a-z0-9-, 2-24 chars); a local name such
//! as `claude@codegraff` becomes `claude-codegraff`. A cloud agent's run token
//! (cg_lt_ with the swarm scope) is bound to its run's name server-side.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const util = @import("util.zig");
const cube = @import("cube.zig");

pub const config_file = ".graff/peer-cloud.json";

pub const State = struct { enabled: bool = false, next_from: i64 = 0 };

fn base() []const u8 {
    if (std.c.getenv("GRAFF_GATEWAY_BASE")) |v| return std.mem.span(v);
    return @import("main.zig").codegraff_device_base;
}

/// A local peer name as a swarm member name: lowercase a-z0-9, other runs of
/// characters become one '-', starts with a letter, at most 24 characters.
pub fn memberName(buf: *[24]u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |raw| {
        if (n == buf.len) break;
        const ch = std.ascii.toLower(raw);
        if (std.ascii.isAlphanumeric(ch) and ch < 0x80) {
            if (n == 0 and !std.ascii.isAlphabetic(ch)) {
                buf[0] = 'a';
                n = 1;
                if (n == buf.len) break;
            }
            buf[n] = ch;
            n += 1;
        } else if (n > 0 and buf[n - 1] != '-') {
            buf[n] = '-';
            n += 1;
        }
    }
    while (n > 0 and buf[n - 1] == '-') n -= 1;
    if (n < 2) {
        const fallback = "graff-agent";
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }
    return buf[0..n];
}

pub fn load(io: Io, arena: Allocator, home: []const u8) State {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, config_file }) catch return .{};
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return .{};
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return .{};
    if (v != .object) return .{};
    const on = if (v.object.get("enabled")) |e| (e == .bool and e.bool) else false;
    return .{ .enabled = on, .next_from = util.intFieldObj(v.object, "next_from", 0) };
}

fn save(io: Io, arena: Allocator, home: []const u8, st: State) void {
    const dir = std.fmt.allocPrint(arena, "{s}/.graff", .{home}) catch return;
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, config_file }) catch return;
    const text = std.fmt.allocPrint(arena, "{{\"enabled\":{},\"next_from\":{d}}}\n", .{ st.enabled, st.next_from }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

pub const Ctx = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    home: []const u8,
    key: []const u8,
    member: []const u8,
};

/// The context when cloud peers are on and a codegraff key exists, else null.
pub fn open(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, local_name: []const u8, member_buf: *[24]u8) ?Ctx {
    if (!load(io, arena, home).enabled) return null;
    const key = if (std.c.getenv("CODEGRAFF_API_KEY")) |k| std.mem.span(k) else @import("oauth.zig").loadCodegraffKey(io, arena, home) orelse return null;
    return .{ .io = io, .gpa = gpa, .arena = arena, .home = home, .key = key, .member = memberName(member_buf, local_name) };
}

fn call(c: Ctx, method: std.http.Method, path: []const u8, body: ?[]const u8) ?Value {
    const url = std.fmt.allocPrint(c.arena, "{s}{s}", .{ base(), path }) catch return null;
    const r = cube.gatewayFetch(c.io, c.gpa, c.arena, method, url, c.key, body) catch return null;
    if (r.code < 200 or r.code >= 300) return null;
    return std.json.parseFromSliceLeaky(Value, c.arena, r.body, .{ .allocate = .alloc_always }) catch .null;
}

fn json(arena: Allocator, value: anytype) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(value);
    return aw.writer.buffered();
}

/// Idempotent: re-registering refreshes host.
pub fn register(c: Ctx) bool {
    var hb: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = if (std.posix.gethostname(&hb)) |h| h else |_| "unknown";
    const body = json(c.arena, .{ .name = c.member, .kind = "external", .host = host }) catch return false;
    return call(c, .POST, "/v1/swarm/members", body) != null;
}

/// Post to the channel (to == null) or DM a member. False when the gateway refused.
pub fn post(c: Ctx, to: ?[]const u8, text: []const u8) bool {
    _ = register(c);
    const body = if (to) |t|
        json(c.arena, .{ .body = text, .from = c.member, .to = t }) catch return false
    else
        json(c.arena, .{ .body = text, .from = c.member }) catch return false;
    return call(c, .POST, "/v1/swarm/messages", body) != null;
}

pub const Msg = struct { seq: i64, from: []const u8, to: ?[]const u8, body: []const u8, ts: i64 };

/// Messages for this member (mentions, @all, DMs) since the saved cursor.
/// Advances and acks the cursor unless `peek`.
pub fn inbox(c: Ctx, peek: bool) []const Msg {
    var st = load(c.io, c.arena, c.home);
    const path = std.fmt.allocPrint(c.arena, "/v1/swarm/messages?from={d}&for={s}", .{ @max(st.next_from, 1), c.member }) catch return &.{};
    const v = call(c, .GET, path, null) orelse return &.{};
    if (v != .object) return &.{};
    const list = v.object.get("messages") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(Msg) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const from = util.strFieldObj(o, "from") orelse continue;
        if (std.mem.eql(u8, from, c.member)) continue;
        out.append(c.arena, .{
            .seq = util.intFieldObj(o, "seq", 0),
            .from = from,
            .to = util.strFieldObj(o, "to"),
            .body = util.strFieldObj(o, "body") orelse "",
            .ts = util.intFieldObj(o, "ts", 0),
        }) catch break;
    }
    const next = util.intFieldObj(v.object, "next_from", st.next_from);
    if (!peek and next > st.next_from) {
        st.next_from = next;
        save(c.io, c.arena, c.home, st);
        const ack_path = std.fmt.allocPrint(c.arena, "/v1/swarm/members/{s}/ack", .{c.member}) catch return out.items;
        const ack = json(c.arena, .{ .upto_seq = next - 1 }) catch return out.items;
        _ = call(c, .POST, ack_path, ack);
    }
    return out.items;
}

pub const Member = struct { name: []const u8, kind: []const u8, host: []const u8, online: bool };

pub fn members(c: Ctx) []const Member {
    const v = call(c, .GET, "/v1/swarm", null) orelse return &.{};
    if (v != .object) return &.{};
    const list = v.object.get("members") orelse v.object.get("agents") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(Member) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const online = if (o.get("online")) |b| (b == .bool and b.bool) else false;
        out.append(c.arena, .{
            .name = util.strFieldObj(o, "name") orelse continue,
            .kind = util.strFieldObj(o, "kind") orelse "hub",
            .host = util.strFieldObj(o, "host") orelse "",
            .online = online,
        }) catch break;
    }
    return out.items;
}

pub fn writeMsg(w: *Io.Writer, m: Msg) !void {
    if (m.to) |t| {
        try w.print("[cloud dm {s} → {s}] {s}\n", .{ m.from, t, m.body });
    } else try w.print("[cloud {s}] {s}\n", .{ m.from, m.body });
}

/// `graff peer cloud on|off|status`.
pub fn command(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, local_name: []const u8, sub: []const u8, out: *Io.Writer) !void {
    var mb: [24]u8 = undefined;
    const member = memberName(&mb, local_name);
    var st = load(io, arena, home);
    if (std.mem.eql(u8, sub, "on")) {
        st.enabled = true;
        save(io, arena, home, st);
        const c = open(io, gpa, arena, home, local_name, &mb) orelse {
            try out.writeAll("cloud peers on, but there is no codegraff key — run `graff login`\n");
            return;
        };
        if (register(c)) {
            try out.print("cloud peers on: you are @{s} in your codegraff swarm channel\n", .{member});
        } else try out.writeAll("cloud peers on, but the gateway refused to register this member (check `graff login`)\n");
        return;
    }
    if (std.mem.eql(u8, sub, "off")) {
        st.enabled = false;
        save(io, arena, home, st);
        try out.writeAll("cloud peers off: peer rooms stay on this device\n");
        return;
    }
    try out.print("cloud peers {s} · member @{s}\n", .{ if (st.enabled) "on" else "off (graff peer cloud on)", member });
}

test "local peer names map to swarm member names" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("claude-codegraff-acpv2", memberName(&b, "claude@codegraff:acpv2"));
    try std.testing.expectEqualStrings("a2-graff", memberName(&b, "2 graff"));
    try std.testing.expectEqualStrings("graff-agent", memberName(&b, "@@"));
    try std.testing.expectEqualStrings("session-1790411649669-63", memberName(&b, "session-1790411649669-6302"));
    try std.testing.expectEqualStrings("mimo", memberName(&b, "MIMO--"));
}
