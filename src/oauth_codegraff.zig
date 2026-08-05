//! Codegraff device-code login and local credential discovery.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const style = &@import("ansi.zig").style;
const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const intFieldObj = util.intFieldObj;
const openBrowser = @import("oauth_helpers.zig").openBrowser;
const credential_store = @import("credential_store.zig");
const codegraff_device_base = @import("main.zig").codegraff_device_base;

const key_file = ".simple-harness-codegraff.json";

fn httpJsonPost(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, body: []const u8) !std.json.ObjectMap {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    const value = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    if (value != .object) return error.BadOAuthResponse;
    return value.object;
}

pub fn login(io: Io, gpa: Allocator, arena: Allocator, home: []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const start_resp = httpJsonPost(io, gpa, arena, codegraff_device_base ++ "/v1/device/start", "{\"device_label\":\"simple-harness\"}") catch |err| {
        try out.print("✗ device/start failed: {t}\n", .{err});
        try out.flush();
        return;
    };
    const device_code = strFieldObj(start_resp, "device_code") orelse {
        try out.writeAll("✗ no device_code in start response\n");
        try out.flush();
        return;
    };
    const user_code = strFieldObj(start_resp, "user_code") orelse "";
    const verification_uri = strFieldObj(start_resp, "verification_uri") orelse "https://codegraff.com/cli/auth";
    const complete_uri = strFieldObj(start_resp, "verification_uri_complete") orelse verification_uri;
    const interval: i64 = @max(1, intFieldObj(start_resp, "interval", 2));
    const expires: i64 = intFieldObj(start_resp, "expires_in", 600);

    try out.print("\nTo authorize, open:\n\n  {s}\n\nand enter code: {s}{s}{s}\n\nwaiting for approval …\n", .{ verification_uri, style.bold, user_code, style.reset });
    try out.flush();
    openBrowser(io, complete_uri);

    const poll_body = try std.fmt.allocPrint(arena, "{{\"device_code\":\"{s}\"}}", .{device_code});
    var waited: i64 = 0;
    while (waited < expires) : (waited += interval) {
        io.sleep(Io.Duration.fromSeconds(interval), .awake) catch {};
        const poll = httpJsonPost(io, gpa, arena, codegraff_device_base ++ "/v1/device/poll", poll_body) catch continue;
        const status = strFieldObj(poll, "status") orelse "pending";
        if (std.mem.eql(u8, status, "ok")) {
            const key = strFieldObj(poll, "api_key") orelse {
                try out.writeAll("✗ approved but no api_key returned\n");
                try out.flush();
                return;
            };
            try writeKey(io, arena, home, key);
            try out.print("{s}✓{s} logged into codegraff — key saved to ~/{s}. /model deepseek-v4-pro\n", .{ style.green, style.reset, key_file });
            try out.flush();
            return;
        } else if (std.mem.eql(u8, status, "denied")) {
            try out.writeAll("✗ authorization denied\n");
            try out.flush();
            return;
        } else if (std.mem.eql(u8, status, "expired")) {
            try out.writeAll("✗ code expired — run `graff login codegraff` again\n");
            try out.flush();
            return;
        }
    }
    try out.writeAll("✗ timed out waiting for approval\n");
    try out.flush();
}

fn writeKey(io: Io, arena: Allocator, home: []const u8, key: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, key_file });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "api_key", .{ .string = key });
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(Value{ .object = obj });
    try credential_store.replaceFile(io, Io.Dir.cwd(), path, aw.writer.buffered(), .default_file);
}

/// Load the harness login file first, then graff's credential store.
pub fn loadKey(io: Io, arena: Allocator, home: []const u8) ?[]const u8 {
    if (std.fmt.allocPrint(arena, "{s}/{s}", .{ home, key_file })) |path| {
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024))) |data| {
            if (std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always })) |value| {
                if (value == .object) if (value.object.get("api_key")) |key|
                    if (key == .string and key.string.len > 0) return key.string;
            } else |_| {}
        } else |_| {}
    } else |_| {}
    if (std.fmt.allocPrint(arena, "{s}/forge/.credentials.json", .{home})) |path| {
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024))) |data| {
            if (std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always })) |value| {
                if (value == .array) for (value.array.items) |entry| {
                    if (entry != .object) continue;
                    const id = if (entry.object.get("id")) |item| (if (item == .string) item.string else "") else "";
                    if (!std.mem.eql(u8, id, "codegraff")) continue;
                    if (entry.object.get("auth_details")) |details| if (details == .object)
                        if (details.object.get("api_key")) |key| if (key == .string and key.string.len > 0) return key.string;
                };
            } else |_| {}
        } else |_| {}
    } else |_| {}
    return null;
}
