//! In-memory Harness edge vault for tests (contract v1.1): device
//! enrollment, per-device wrapped keys, compare-and-swap items, leases,
//! key epochs, rotation, and Ed25519 request-signature checks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = @import("vault_crypto.zig");
const client = @import("vault_client.zig");
const Ed25519 = std.crypto.sign.Ed25519;

const Device = struct {
    id: []const u8,
    name: []const u8,
    public_key: []const u8,
    signing_key: []const u8,
    enrolled: bool,
    wrapped: ?[]const u8 = null,
};

const Item = struct {
    version: u64 = 0,
    key_epoch: u64 = 0,
    kind: []const u8 = "static",
    status: []const u8 = "ok",
    nonce: []const u8 = "",
    ciphertext: []const u8 = "",
    lease_holder: ?[]const u8 = null,
};

pub const MockEdge = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    devices: std.ArrayList(Device) = .empty,
    items: std.StringHashMapUnmanaged(Item) = .empty,
    key_epoch: u64 = 1,
    /// Count of rejected signatures, so tests can prove the checks ran.
    bad_signatures: usize = 0,
    requests: usize = 0,

    pub fn init(gpa: Allocator) MockEdge {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(m: *MockEdge) void {
        m.arena.deinit();
    }

    /// Test hook: a lease that expired while its holder was still working.
    pub fn dropLease(m: *MockEdge, key: []const u8) void {
        if (m.items.getPtr(key)) |it| it.lease_holder = null;
    }

    pub fn transport(m: *MockEdge) client.Transport {
        return .{ .ctx = m, .callFn = handle };
    }

    fn header(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
        for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    fn find(m: *MockEdge, id: []const u8) ?*Device {
        for (m.devices.items) |*d| if (std.mem.eql(u8, d.id, id)) return d;
        return null;
    }

    fn resp(arena: Allocator, status: u16, value: anytype) !client.Response {
        var aw: std.Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.write(value);
        return .{ .status = status, .body = aw.writer.buffered() };
    }

    fn verified(m: *MockEdge, arena: Allocator, method: []const u8, path: []const u8, headers: []const std.http.Header, body: []const u8) bool {
        const dev_id = header(headers, "X-Vault-Device") orelse return false;
        const d = m.find(dev_id) orelse return false;
        if (!d.enrolled) return false;
        const ts = std.fmt.parseInt(i64, header(headers, "X-Vault-Timestamp") orelse return false, 10) catch return false;
        const sig_raw = crypto.decode(arena, header(headers, "X-Vault-Signature") orelse return false) catch return false;
        const key_raw = crypto.decode(arena, d.signing_key) catch return false;
        if (sig_raw.len != 64 or key_raw.len != 32) return false;
        const pk = Ed25519.PublicKey.fromBytes(key_raw[0..32].*) catch return false;
        const msg = crypto.signingString(arena, method, path, body, ts, dev_id) catch return false;
        Ed25519.Signature.fromBytes(sig_raw[0..64].*).verify(msg, pk) catch return false;
        return true;
    }

    fn handle(ctx: *anyopaque, arena: Allocator, method: []const u8, path: []const u8, headers: []const std.http.Header, body: []const u8) anyerror!client.Response {
        const m: *MockEdge = @ptrCast(@alignCast(ctx));
        m.requests += 1;
        const a = m.arena.allocator();
        if (header(headers, "Authorization") == null) return .{ .status = 401, .body = "{}" };
        const caller = header(headers, "X-Vault-Device") orelse "";
        const is_get = std.mem.eql(u8, method, "GET");
        const registering = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/vault/devices");
        if (!is_get and !registering and !m.verified(arena, method, path, headers, body)) {
            m.bad_signatures += 1;
            return .{ .status = 401, .body = "{\"error\":\"bad_signature\"}" };
        }
        const parsed: std.json.Value = if (body.len > 0) try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) else .null;

        if (is_get and std.mem.eql(u8, path, "/vault")) {
            var devs: std.ArrayList(client.Device) = .empty;
            for (m.devices.items) |d| try devs.append(arena, .{ .deviceId = d.id, .name = d.name, .publicKey = d.public_key, .signingKey = d.signing_key, .status = if (d.enrolled) "enrolled" else "pending" });
            var heads: std.ArrayList(client.ItemHeader) = .empty;
            var it = m.items.iterator();
            while (it.next()) |e| {
                const slash = std.mem.indexOfScalar(u8, e.key_ptr.*, '/').?;
                try heads.append(arena, .{ .agent = e.key_ptr.*[0..slash], .slot = e.key_ptr.*[slash + 1 ..], .version = e.value_ptr.version, .keyEpoch = e.value_ptr.key_epoch, .kind = e.value_ptr.kind, .status = e.value_ptr.status, .leaseHolder = e.value_ptr.lease_holder });
            }
            const wrapped = if (m.find(caller)) |d| d.wrapped else null;
            return resp(arena, 200, client.Vault{ .userId = "user-7", .devices = devs.items, .wrappedKey = wrapped, .keyEpoch = m.key_epoch, .items = heads.items });
        }
        if (registering) {
            const o = parsed.object;
            var any_enrolled = false;
            for (m.devices.items) |d| any_enrolled = any_enrolled or d.enrolled;
            const wrapped = if (o.get("wrappedKey")) |w| (if (w == .string) w.string else null) else null;
            const bootstrap = !any_enrolled and wrapped != null;
            try m.devices.append(a, .{
                .id = try a.dupe(u8, o.get("deviceId").?.string),
                .name = try a.dupe(u8, o.get("name").?.string),
                .public_key = try a.dupe(u8, o.get("publicKey").?.string),
                .signing_key = try a.dupe(u8, o.get("signingKey").?.string),
                .enrolled = bootstrap,
                .wrapped = if (bootstrap) try a.dupe(u8, wrapped.?) else null,
            });
            return resp(arena, 200, .{ .status = if (bootstrap) "enrolled" else "pending" });
        }
        if (std.mem.startsWith(u8, path, "/vault/devices/")) {
            const rest = path["/vault/devices/".len..];
            if (std.mem.endsWith(u8, rest, "/approve")) {
                const d = m.find(rest[0 .. rest.len - "/approve".len]) orelse return .{ .status = 404, .body = "{}" };
                d.enrolled = true;
                d.wrapped = try a.dupe(u8, parsed.object.get("wrappedKey").?.string);
                return resp(arena, 200, .{ .status = "enrolled" });
            }
            for (m.devices.items, 0..) |d, i| if (std.mem.eql(u8, d.id, rest)) {
                _ = m.devices.orderedRemove(i);
                return .{ .status = 204, .body = "" };
            };
            return .{ .status = 404, .body = "{}" };
        }
        if (std.mem.eql(u8, path, "/vault/rotate")) {
            const o = parsed.object;
            const epoch: u64 = @intCast(o.get("keyEpoch").?.integer);
            if (epoch != m.key_epoch + 1) return .{ .status = 409, .body = "{\"error\":\"stale_epoch\"}" };
            const wk = o.get("wrappedKeys").?.object;
            var enrolled: usize = 0;
            for (m.devices.items) |d| if (d.enrolled) {
                enrolled += 1;
                if (wk.get(d.id) == null) return .{ .status = 400, .body = "{\"error\":\"missing_device\"}" };
            };
            if (wk.count() != enrolled) return .{ .status = 400, .body = "{\"error\":\"extra_device\"}" };
            for (m.devices.items) |*d| if (d.enrolled) {
                d.wrapped = try a.dupe(u8, wk.get(d.id).?.string);
            };
            m.key_epoch = epoch;
            return resp(arena, 200, .{ .keyEpoch = epoch });
        }
        if (std.mem.startsWith(u8, path, "/vault/items/")) {
            var rest = path["/vault/items/".len..];
            var action: []const u8 = "";
            for ([_][]const u8{ "/lease", "/status", "/hold" }) |suf| if (std.mem.endsWith(u8, rest, suf)) {
                action = suf;
                rest = rest[0 .. rest.len - suf.len];
            };
            const gop = try m.items.getOrPut(a, try a.dupe(u8, rest));
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const item = gop.value_ptr;
            if (std.mem.eql(u8, action, "/lease")) {
                if (std.mem.eql(u8, method, "DELETE")) {
                    if (item.lease_holder) |h| if (std.mem.eql(u8, h, caller)) {
                        item.lease_holder = null;
                    };
                    return .{ .status = 204, .body = "" };
                }
                if (item.lease_holder) |h| if (!std.mem.eql(u8, h, caller)) return .{ .status = 409, .body = "{\"error\":\"lease_held\"}" };
                item.lease_holder = try a.dupe(u8, caller);
                return resp(arena, 200, .{ .leaseHolder = caller, .version = item.version });
            }
            if (std.mem.eql(u8, action, "/status")) {
                item.status = try a.dupe(u8, parsed.object.get("status").?.string);
                return resp(arena, 200, .{ .status = item.status });
            }
            if (is_get) {
                if (item.version == 0) return .{ .status = 404, .body = "{}" };
                const slash = std.mem.indexOfScalar(u8, rest, '/').?;
                return resp(arena, 200, client.Item{ .agent = rest[0..slash], .slot = rest[slash + 1 ..], .version = item.version, .keyEpoch = item.key_epoch, .kind = item.kind, .status = item.status, .nonce = item.nonce, .ciphertext = item.ciphertext });
            }
            if (std.mem.eql(u8, method, "PUT")) {
                if (item.lease_holder) |h| if (!std.mem.eql(u8, h, caller)) return .{ .status = 409, .body = "{\"error\":\"lease_held\"}" };
                const o = parsed.object;
                if (@as(u64, @intCast(o.get("keyEpoch").?.integer)) != m.key_epoch) return .{ .status = 409, .body = "{\"error\":\"stale_epoch\"}" };
                const if_match = std.fmt.parseInt(u64, header(headers, "If-Match") orelse "", 10) catch return .{ .status = 428, .body = "{}" };
                if (if_match != item.version) return resp(arena, 412, .{ .currentVersion = item.version });
                item.version += 1;
                item.key_epoch = m.key_epoch;
                item.kind = try a.dupe(u8, o.get("kind").?.string);
                item.status = try a.dupe(u8, o.get("status").?.string);
                item.nonce = try a.dupe(u8, o.get("nonce").?.string);
                item.ciphertext = try a.dupe(u8, o.get("ciphertext").?.string);
                return resp(arena, 200, .{ .version = item.version });
            }
        }
        return .{ .status = 404, .body = "{}" };
    }
};
