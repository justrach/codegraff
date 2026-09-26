//! HTTP client for the Harness edge vault (contract v1.1). Every request
//! carries the Harness bearer and X-Vault-Device; mutating requests are also
//! signed with the device's Ed25519 key. The transport is an interface so
//! tests run against an in-memory edge.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const crypto = @import("vault_crypto.zig");

pub const default_edge = "https://edge.codegraff.com";

pub const Response = struct { status: u16, body: []const u8 };

/// The bearer and ciphertext never travel in clear: https, or plain http to
/// this machine only (the dev edge).
pub fn checkEdgeUrl(url: []const u8) error{InsecureEdgeUrl}!void {
    if (std.mem.startsWith(u8, url, "https://")) return;
    for ([_][]const u8{ "http://127.0.0.1:", "http://127.0.0.1/", "http://localhost:", "http://localhost/", "http://[::1]:", "http://[::1]/" }) |ok| {
        if (std.mem.startsWith(u8, url, ok)) return;
    }
    return error.InsecureEdgeUrl;
}

test "checkEdgeUrl allows https and loopback http only" {
    try checkEdgeUrl("https://edge.example.com");
    try checkEdgeUrl("http://127.0.0.1:27640");
    try checkEdgeUrl("http://localhost:8787");
    try std.testing.expectError(error.InsecureEdgeUrl, checkEdgeUrl("http://edge.example.com"));
    try std.testing.expectError(error.InsecureEdgeUrl, checkEdgeUrl("http://127.0.0.1.evil.com"));
}

pub const Transport = struct {
    ctx: *anyopaque,
    callFn: *const fn (ctx: *anyopaque, arena: Allocator, method: []const u8, path: []const u8, headers: []const std.http.Header, body: []const u8) anyerror!Response,
};

pub const Client = struct {
    io: Io,
    arena: Allocator,
    transport: Transport,
    bearer: []const u8,
    device_id: []const u8,
    keys: crypto.DeviceKeys,
    /// Test hook: fixed clock for signatures.
    now_ms: ?i64 = null,

    fn call(c: *Client, method: []const u8, path: []const u8, body: []const u8, signed: bool, extra: []const std.http.Header) !Response {
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(c.arena, .{ .name = "Authorization", .value = try std.fmt.allocPrint(c.arena, "Bearer {s}", .{c.bearer}) });
        try headers.append(c.arena, .{ .name = "X-Vault-Device", .value = c.device_id });
        if (body.len > 0) try headers.append(c.arena, .{ .name = "Content-Type", .value = "application/json" });
        if (signed) {
            const ts = c.now_ms orelse @import("util.zig").unixMs(c.io);
            try headers.append(c.arena, .{ .name = "X-Vault-Timestamp", .value = try std.fmt.allocPrint(c.arena, "{d}", .{ts}) });
            try headers.append(c.arena, .{ .name = "X-Vault-Signature", .value = try crypto.signRequest(c.arena, c.keys, method, path, body, ts, c.device_id) });
        }
        try headers.appendSlice(c.arena, extra);
        return c.transport.callFn(c.transport.ctx, c.arena, method, path, headers.items, body);
    }

    fn json(c: *Client, value: anytype) ![]const u8 {
        var aw: Io.Writer.Allocating = .init(c.arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.write(value);
        return aw.writer.buffered();
    }

    fn itemPath(c: *Client, agent: []const u8, slot: []const u8, suffix: []const u8) ![]const u8 {
        return std.fmt.allocPrint(c.arena, "/vault/items/{s}/{s}{s}", .{ agent, slot, suffix });
    }

    pub fn getVault(c: *Client) !Vault {
        const r = try c.call("GET", "/vault", "", false, &.{});
        if (r.status != 200) return statusError(r.status);
        return std.json.parseFromSliceLeaky(Vault, c.arena, r.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    pub fn getItem(c: *Client, agent: []const u8, slot: []const u8) !?Item {
        const r = try c.call("GET", try c.itemPath(agent, slot, ""), "", false, &.{});
        if (r.status == 404) return null;
        if (r.status != 200) return statusError(r.status);
        return try std.json.parseFromSliceLeaky(Item, c.arena, r.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    pub fn putItem(c: *Client, agent: []const u8, slot: []const u8, if_match: u64, body: PutBody) !PutResult {
        const payload = try c.json(body);
        const etag = try std.fmt.allocPrint(c.arena, "{d}", .{if_match});
        const r = try c.call("PUT", try c.itemPath(agent, slot, ""), payload, true, &.{.{ .name = "If-Match", .value = etag }});
        return switch (r.status) {
            200, 201 => .{ .ok = (try parseField(c.arena, r.body, "version")) orelse if_match + 1 },
            412 => .{ .conflict = (try parseField(c.arena, r.body, "currentVersion")) orelse 0 },
            409 => if (std.mem.indexOf(u8, r.body, "stale_epoch") != null) .stale_epoch else .lease_held,
            else => statusError(r.status),
        };
    }

    /// The item's version at the moment the lease was granted, or null when
    /// another device holds it. Decide what to do from this version, never
    /// from an earlier read: another device may have committed in between.
    pub fn lease(c: *Client, agent: []const u8, slot: []const u8, ttl_s: u32) !?u64 {
        const r = try c.call("POST", try c.itemPath(agent, slot, "/lease"), try c.json(.{ .ttlSeconds = @min(ttl_s, 60) }), true, &.{});
        return switch (r.status) {
            200 => (try parseField(c.arena, r.body, "version")) orelse 0,
            409 => null,
            else => statusError(r.status),
        };
    }

    pub fn release(c: *Client, agent: []const u8, slot: []const u8) !void {
        const r = try c.call("DELETE", try c.itemPath(agent, slot, "/lease"), "", true, &.{});
        if (r.status != 200 and r.status != 204 and r.status != 404) return statusError(r.status);
    }

    pub fn setStatus(c: *Client, agent: []const u8, slot: []const u8, status: []const u8, if_version: u64) !void {
        const r = try c.call("POST", try c.itemPath(agent, slot, "/status"), try c.json(.{ .status = status, .ifVersion = if_version }), true, &.{});
        if (r.status != 200 and r.status != 412) return statusError(r.status);
    }

    pub fn registerDevice(c: *Client, name: []const u8, wrapped_key: ?[]const u8) ![]const u8 {
        const body = try c.json(.{
            .deviceId = c.device_id,
            .name = name,
            .publicKey = try crypto.encode(c.arena, &c.keys.box.public_key),
            .signingKey = try crypto.encode(c.arena, &c.keys.sign.public_key.toBytes()),
            .wrappedKey = wrapped_key,
        });
        const r = try c.call("POST", "/vault/devices", body, false, &.{});
        if (r.status != 200 and r.status != 201) return statusError(r.status);
        return (try parseStringField(c.arena, r.body, "status")) orelse "pending";
    }

    pub fn approve(c: *Client, device_id: []const u8, wrapped_key: []const u8) !void {
        const path = try std.fmt.allocPrint(c.arena, "/vault/devices/{s}/approve", .{device_id});
        const r = try c.call("POST", path, try c.json(.{ .wrappedKey = wrapped_key }), true, &.{});
        if (r.status != 200) return statusError(r.status);
    }

    pub fn deleteDevice(c: *Client, device_id: []const u8) !void {
        const path = try std.fmt.allocPrint(c.arena, "/vault/devices/{s}", .{device_id});
        const r = try c.call("DELETE", path, "", true, &.{});
        if (r.status != 200 and r.status != 204) return statusError(r.status);
    }

    pub fn rotate(c: *Client, key_epoch: u64, wrapped: std.json.ObjectMap) !void {
        const r = try c.call("POST", "/vault/rotate", try c.json(.{ .keyEpoch = key_epoch, .wrappedKeys = std.json.Value{ .object = wrapped } }), true, &.{});
        if (r.status != 200) return statusError(r.status);
    }
};

pub const Device = struct {
    deviceId: []const u8 = "",
    name: []const u8 = "",
    publicKey: []const u8 = "",
    signingKey: []const u8 = "",
    status: []const u8 = "",
};

pub const ItemHeader = struct {
    agent: []const u8 = "",
    slot: []const u8 = "",
    version: u64 = 0,
    keyEpoch: u64 = 0,
    kind: []const u8 = "static",
    status: []const u8 = "ok",
    holder: ?[]const u8 = null,
    leaseHolder: ?[]const u8 = null,
    leaseUntil: ?i64 = null,
    updatedAt: ?i64 = null,
    updatedBy: ?[]const u8 = null,
};

pub const Vault = struct {
    /// The verified user id. Older edges omit it; callers then fall back to
    /// the bearer's `sub`.
    userId: ?[]const u8 = null,
    devices: []const Device = &.{},
    wrappedKey: ?[]const u8 = null,
    keyEpoch: u64 = 0,
    items: []const ItemHeader = &.{},
};

pub const Item = struct {
    agent: []const u8 = "",
    slot: []const u8 = "",
    version: u64 = 0,
    keyEpoch: u64 = 0,
    kind: []const u8 = "static",
    status: []const u8 = "ok",
    nonce: []const u8 = "",
    ciphertext: []const u8 = "",
};

pub const PutBody = struct {
    kind: []const u8,
    status: []const u8 = "ok",
    keyEpoch: u64,
    nonce: []const u8,
    ciphertext: []const u8,
};

pub const PutResult = union(enum) {
    ok: u64,
    conflict: u64,
    lease_held,
    stale_epoch,
};

fn statusError(status: u16) error{ Unauthorized, Forbidden, NotFound, EdgeError } {
    return switch (status) {
        401 => error.Unauthorized,
        403 => error.Forbidden,
        404 => error.NotFound,
        else => error.EdgeError,
    };
}

fn parseField(arena: Allocator, body: []const u8, name: []const u8) !?u64 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (v != .object) return null;
    const f = v.object.get(name) orelse return null;
    return if (f == .integer and f.integer >= 0) @intCast(f.integer) else null;
}

fn parseStringField(arena: Allocator, body: []const u8, name: []const u8) !?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const f = v.object.get(name) orelse return null;
    return if (f == .string) f.string else null;
}

/// Real transport: std.http against the edge base URL.
pub const Http = struct {
    io: Io,
    gpa: Allocator,
    base: []const u8 = default_edge,

    pub fn transport(h: *Http) Transport {
        return .{ .ctx = h, .callFn = callHttp };
    }

    fn callHttp(ctx: *anyopaque, arena: Allocator, method: []const u8, path: []const u8, headers: []const std.http.Header, body: []const u8) anyerror!Response {
        const h: *Http = @ptrCast(@alignCast(ctx));
        var client: std.http.Client = .{ .allocator = h.gpa, .io = h.io };
        defer client.deinit();
        var aw: Io.Writer.Allocating = .init(arena);
        const m = std.meta.stringToEnum(std.http.Method, method) orelse return error.BadMethod;
        const res = try client.fetch(.{
            .location = .{ .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ h.base, path }) },
            .method = m,
            .payload = if (body.len > 0 or m == .POST or m == .PUT) body else null,
            .response_writer = &aw.writer,
            .extra_headers = headers,
        });
        return .{ .status = @intFromEnum(res.status), .body = aw.writer.buffered() };
    }
};

test {
    _ = @import("vault_client_tests.zig");
}
