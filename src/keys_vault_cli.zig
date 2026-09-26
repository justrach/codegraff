//! `graff keys`: sync provider logins between a person's own devices through
//! the end-to-end encrypted vault (harness ADR 0005, contract v1.1).
//!
//!   graff keys status [--json]        this device, its fingerprint, synced logins
//!   graff keys enable [--name N]      enroll this device (the first one creates the vault)
//!   graff keys devices [--json]       enrolled and pending devices
//!   graff keys approve <id> [--yes]   let a pending device read the vault
//!   graff keys remove <id> [--yes]    remove a device and rotate the vault key
//!   graff keys push|pull [provider]   graff's logins: codex, kimi, xai
//!   graff keys put|get <agent>/<slot> opaque bytes on stdin/stdout (for Harness)
//!
//! The bearer comes from HARNESS_BEARER; the edge from HARNESS_EDGE_URL.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const crypto = @import("vault_crypto.zig");
const client = @import("vault_client.zig");
const sync = @import("vault_sync.zig");
const keys_cli = @import("keys_cli.zig");
const credential_store = @import("credential_store.zig");
const oauth_helpers = @import("oauth_helpers.zig");

const device_account = "graff-vault-device";

pub const usage =
    \\usage: graff keys <status|enable|devices|approve|remove|push|pull|put|get> [options]
    \\  status [--json]                 this device, its fingerprint, and synced logins
    \\  enable [--name NAME]            enroll this device; the first device creates the vault
    \\  devices [--json]                enrolled and pending devices
    \\  approve <device-id> [--yes]     let a pending device read the vault
    \\  remove <device-id> [--yes]      remove a device and rotate the vault key
    \\  push [codex|kimi|xai]           upload graff's logins (all when omitted)
    \\  pull [codex|kimi|xai]           download graff's logins into their usual files
    \\  put <agent>/<slot>              store stdin as an opaque item
    \\  get <agent>/<slot>              print an item's bytes
    \\Needs HARNESS_BEARER (Harness passes it). HARNESS_EDGE_URL overrides the edge.
    \\GRAFF_VAULT_DEVICE_FILE keeps this device's keys in a 0600 file instead of the Keychain.
    \\
;

/// graff's own provider logins and where graff keeps each one.
pub const Provider = struct { name: []const u8, kind: []const u8 };
pub const providers = [_]Provider{
    .{ .name = "codex", .kind = "rotating" },
    .{ .name = "kimi", .kind = "rotating" },
    .{ .name = "xai", .kind = "rotating" },
};

pub fn providerPath(arena: Allocator, home: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "codex")) {
        const dir = oauth_helpers.codexHomeDir(arena, home) orelse return null;
        return oauth_helpers.codexAuthPath(arena, dir) catch null;
    }
    if (std.mem.eql(u8, name, "kimi")) return credential_store.oauthPath(arena, home, ".kimi");
    if (std.mem.eql(u8, name, "xai")) return credential_store.oauthPath(arena, home, ".xai");
    return null;
}

/// This device's id and key pair, created on first use. Stored as one
/// secret: the Keychain on macOS, the 0600 key file elsewhere.
pub const Identity = struct { id: []const u8, keys: crypto.DeviceKeys };

/// `file`: GRAFF_VAULT_DEVICE_FILE — keep the identity in this 0600 file
/// instead of the Keychain (headless servers, sandboxes, tests).
pub fn loadIdentity(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, create: bool, file: ?[]const u8) !?Identity {
    if (file) |path| return loadIdentityFile(io, arena, path, create);
    if (keys_cli.loadStoredKey(io, arena, home, device_account)) |stored| return try parseIdentity(stored);
    if (!create) return null;
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const id = try std.fmt.allocPrint(arena, "dev-{s}", .{std.fmt.bytesToHex(raw, .lower)});
    const keys = crypto.DeviceKeys.generate(io);
    const secret = keys.encodeSecret();
    const value = try std.fmt.allocPrint(arena, "{s}:{s}", .{ id, &secret });
    if (!keys_cli.storeKey(io, gpa, arena, home, device_account, value)) return error.CannotStoreDeviceKey;
    return .{ .id = id, .keys = keys };
}

fn parseIdentity(stored: []const u8) !Identity {
    const t = std.mem.trim(u8, stored, " \t\r\n");
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return error.BadDeviceKey;
    return .{ .id = t[0..colon], .keys = try crypto.DeviceKeys.decodeSecret(t[colon + 1 ..]) };
}

fn loadIdentityFile(io: Io, arena: Allocator, path: []const u8, create: bool) !?Identity {
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096))) |stored| return try parseIdentity(stored) else |_| {}
    if (!create) return null;
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const id = try std.fmt.allocPrint(arena, "dev-{s}", .{std.fmt.bytesToHex(raw, .lower)});
    const keys = crypto.DeviceKeys.generate(io);
    const secret = keys.encodeSecret();
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    try credential_store.replaceFile(io, Io.Dir.cwd(), path, try std.fmt.allocPrint(arena, "{s}:{s}\n", .{ id, &secret }), credential_store.private_file);
    return .{ .id = id, .keys = keys };
}

const Opts = struct {
    action: []const u8 = "",
    arg: []const u8 = "",
    name: []const u8 = "",
    json: bool = false,
    yes: bool = false,
};

fn parse(args: []const []const u8) error{Usage}!Opts {
    var o: Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) {
            o.yes = true;
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            o.name = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.Usage;
        } else if (o.action.len == 0) {
            o.action = a;
        } else if (o.arg.len == 0) {
            o.arg = a;
        } else return error.Usage;
    }
    if (o.action.len == 0) return error.Usage;
    return o;
}

fn confirm(io: Io, out: *Io.Writer, question: []const u8) bool {
    out.print("{s} [y/N] ", .{question}) catch return false;
    out.flush() catch {};
    var buf: [64]u8 = undefined;
    var r = Io.File.stdin().reader(io, &buf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return false;
    const t = std.mem.trim(u8, line, " \t\r");
    return t.len > 0 and (t[0] == 'y' or t[0] == 'Y');
}

/// Flush buffered output first: std.process.exit does not run defers.
fn exitFlushed(out: *Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

fn splitItem(spec: []const u8) ?struct { agent: []const u8, slot: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return null;
    if (slash == 0 or slash + 1 >= spec.len) return null;
    return .{ .agent = spec[0..slash], .slot = spec[slash + 1 ..] };
}

pub fn command(gpa: Allocator, io: Io, arena: Allocator, home: []const u8, env: anytype, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &obuf);
    const out = &w.interface;
    defer out.flush() catch {};
    const o = parse(args) catch {
        try out.writeAll(usage);
        return;
    };
    const bearer = env.get("HARNESS_BEARER") orelse {
        try out.writeAll("graff keys: set HARNESS_BEARER (Harness passes it to graff)\n");
        exitFlushed(out, 2);
    };
    const creating = std.mem.eql(u8, o.action, "enable");
    const ident = (try loadIdentity(io, gpa, arena, home, creating, env.get("GRAFF_VAULT_DEVICE_FILE"))) orelse {
        try out.writeAll("This device is not enrolled. Run `graff keys enable` first.\n");
        exitFlushed(out, 2);
    };
    var http: client.Http = .{ .io = io, .gpa = gpa, .base = env.get("HARNESS_EDGE_URL") orelse client.default_edge };
    var c: client.Client = .{ .io = io, .arena = arena, .transport = http.transport(), .bearer = bearer, .device_id = ident.id, .keys = ident.keys };
    var s = try sync.Session.open(io, arena, &c);
    const fp = crypto.fingerprint(ident.keys.box.public_key);

    if (creating) {
        const name = if (o.name.len > 0) o.name else "graff device";
        switch (try s.enable(name)) {
            .enrolled => try out.print("✓ this device ({s}, fingerprint {s}) is enrolled\n", .{ ident.id, &fp }),
            .pending => try out.print("This device ({s}, fingerprint {s}) is waiting for approval.\nOn an enrolled device run: graff keys approve {s}\n", .{ ident.id, &fp, ident.id }),
        }
    } else if (std.mem.eql(u8, o.action, "status") or std.mem.eql(u8, o.action, "devices")) {
        const v = try c.getVault();
        if (o.json) {
            var js: std.json.Stringify = .{ .writer = out };
            try js.write(.{ .deviceId = ident.id, .fingerprint = &fp, .keyEpoch = v.keyEpoch, .devices = v.devices, .items = v.items });
            try out.writeAll("\n");
            return;
        }
        try out.print("this device: {s}  fingerprint {s}\n", .{ ident.id, &fp });
        for (v.devices) |d| {
            const dfp = s.deviceFingerprint(d) catch "????????".*;
            try out.print("  {s:<10} {s}  {s}  {s}\n", .{ d.status, &dfp, d.deviceId, d.name });
        }
        if (std.mem.eql(u8, o.action, "status")) for (v.items) |it| {
            try out.print("  {s}/{s}  v{d}  {s}  {s}\n", .{ it.agent, it.slot, it.version, it.kind, it.status });
        };
    } else if (std.mem.eql(u8, o.action, "approve")) {
        const v = try c.getVault();
        const d = sync.Session.findDevice(v, o.arg) orelse {
            try out.print("no device {s} — see graff keys devices\n", .{o.arg});
            exitFlushed(out, 1);
        };
        const dfp = try s.deviceFingerprint(d);
        try out.print("Approve \"{s}\" ({s}), fingerprint {s}?\nCheck that fingerprint on that device with `graff keys status`.\n", .{ d.name, d.deviceId, &dfp });
        if (!o.yes and !confirm(io, out, "Approve")) {
            try out.writeAll("not approved\n");
            return;
        }
        try s.approve(o.arg);
        try out.print("✓ approved {s}\n", .{o.arg});
    } else if (std.mem.eql(u8, o.action, "remove")) {
        if (!o.yes and !confirm(io, out, "Remove this device and rotate the vault key?")) return;
        try s.remove(o.arg);
        try out.print("✓ removed {s} and rotated the vault key\n", .{o.arg});
    } else if (std.mem.eql(u8, o.action, "push") or std.mem.eql(u8, o.action, "pull")) {
        const pushing = o.action[1] == 'u' and o.action[2] == 's';
        for (providers) |p| {
            if (o.arg.len > 0 and !std.mem.eql(u8, o.arg, p.name)) continue;
            const path = providerPath(arena, home, p.name) orelse continue;
            if (pushing) {
                const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch {
                    if (o.arg.len > 0) try out.print("  {s}: not signed in here\n", .{p.name});
                    continue;
                };
                const v = try s.push("graff", p.name, p.kind, bytes);
                try out.print("  ✓ {s} pushed (v{d})\n", .{ p.name, v });
            } else {
                const got = (try s.pull("graff", p.name)) orelse {
                    if (o.arg.len > 0) try out.print("  {s}: not in the vault\n", .{p.name});
                    continue;
                };
                try credential_store.replaceFile(io, Io.Dir.cwd(), path, got.bytes, credential_store.private_file);
                try out.print("  ✓ {s} pulled (v{d}) into {s}\n", .{ p.name, got.version, path });
            }
        }
    } else if (std.mem.eql(u8, o.action, "put") or std.mem.eql(u8, o.action, "get")) {
        const it = splitItem(o.arg) orelse {
            try out.writeAll("graff keys put|get needs <agent>/<slot>\n");
            exitFlushed(out, 2);
        };
        if (o.action[0] == 'p') {
            var ibuf: [4096]u8 = undefined;
            var r = Io.File.stdin().reader(io, &ibuf);
            const bytes = try r.interface.allocRemaining(arena, .limited(1 << 20));
            const v = try s.push(it.agent, it.slot, "static", bytes);
            try out.print("✓ stored {s}/{s} (v{d})\n", .{ it.agent, it.slot, v });
        } else {
            const got = (try s.pull(it.agent, it.slot)) orelse exitFlushed(out, 1);
            try out.writeAll(got.bytes);
        }
    } else {
        try out.writeAll(usage);
    }
}

test "splitItem and parse" {
    try std.testing.expectEqualStrings("claude", splitItem("claude/default").?.agent);
    try std.testing.expect(splitItem("noslash") == null);
    try std.testing.expect(splitItem("/x") == null);
    const o = try parse(&.{ "approve", "dev-1", "--yes" });
    try std.testing.expectEqualStrings("dev-1", o.arg);
    try std.testing.expect(o.yes);
    try std.testing.expectError(error.Usage, parse(&.{ "status", "--bogus" }));
}

test "providerPath maps graff's logins to their usual files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(std.mem.endsWith(u8, providerPath(a, "/h", "kimi").?, "/.kimi/credentials/graff-oauth.json"));
    try std.testing.expect(std.mem.endsWith(u8, providerPath(a, "/h", "xai").?, "/.xai/credentials/graff-oauth.json"));
    try std.testing.expect(providerPath(a, "/h", "zai") == null);
}
