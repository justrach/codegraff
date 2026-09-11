//! MCP Apps result snapshots. HTML and _meta stay out of model context.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const rpc = @import("mcp_rpc.zig");
const mime = "text/html;profile=mcp-app";
const max_snapshot = 12 * 1024 * 1024;

pub fn modelVisible(tool: Value) bool {
    if (tool != .object) return true;
    const meta = tool.object.get("_meta") orelse return true;
    if (meta != .object) return true;
    const ui = meta.object.get("ui") orelse return true;
    if (ui != .object) return true;
    const visibility = ui.object.get("visibility") orelse return true;
    if (visibility != .array) return true;
    for (visibility.array.items) |v| if (v == .string and std.mem.eql(u8, v.string, "model")) return true;
    return false;
}

pub fn resourceUri(tool: Value) ?[]const u8 {
    if (tool != .object) return null;
    const meta = tool.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const nested = if (meta.object.get("ui")) |ui| (if (ui == .object) ui.object.get("resourceUri") else null) else null;
    const value = nested orelse meta.object.get("ui/resourceUri") orelse return null;
    if (value != .string or value.string.len > 2048 or !std.mem.startsWith(u8, value.string, "ui://")) return null;
    return value.string;
}

pub fn readResource(response: Value, uri: []const u8) ?Value {
    if (response != .object) return null;
    const result = response.object.get("result") orelse return null;
    if (result != .object) return null;
    const contents = result.object.get("contents") orelse return null;
    if (contents != .array) return null;
    for (contents.array.items) |item| {
        if (item != .object) continue;
        const u = item.object.get("uri") orelse continue;
        const m = item.object.get("mimeType") orelse continue;
        if (u != .string or !std.mem.eql(u8, u.string, uri) or m != .string or !std.mem.eql(u8, m.string, mime)) continue;
        return item;
    }
    return null;
}

pub fn snapshot(io: Io, a: Allocator, home: []const u8, server: *rpc.Server, uri: []const u8, input: Value, result: Value) ![]const u8 {
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.NoHomeDirectory;
    const params = try std.json.Stringify.valueAlloc(a, .{ .uri = uri }, .{});
    const response = try rpc.readAppResource(server, a, io, params);
    var resource = readResource(response, uri) orelse return error.InvalidAppResource;
    if (resource.object.get("text")) |text| {
        if (text != .string or text.string.len > 3 * 1024 * 1024) return error.AppTooLarge;
    } else {
        const blob = resource.object.get("blob") orelse return error.InvalidAppResource;
        if (blob != .string) return error.InvalidAppResource;
        const decoder = std.base64.standard.Decoder;
        const size = try decoder.calcSizeForSlice(blob.string);
        if (size > 3 * 1024 * 1024) return error.AppTooLarge;
        const text = try a.alloc(u8, size);
        try decoder.decode(text, blob.string);
        _ = resource.object.swapRemove("blob");
        try resource.object.put(a, "text", .{ .string = text });
    }
    const payload = try std.json.Stringify.valueAlloc(a, .{ .resource = resource, .arguments = input, .result = result }, .{});
    if (payload.len > max_snapshot) return error.AppTooLarge;
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(payload.len));
    _ = encoder.encode(encoded, payload);
    const template = @embedFile("mcp_app_host.html");
    const marker = "GRAFF_APP_PAYLOAD";
    const split = std.mem.indexOf(u8, template, marker).?;
    const html = try std.mem.concat(a, u8, &.{ template[0..split], encoded, template[split + marker.len ..] });
    const dir = try std.fmt.allocPrint(a, "{s}/.graff/mcp-apps", .{home});
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().setFilePermissions(io, dir, @enumFromInt(0o700), .{});
    var random: [16]u8 = undefined;
    io.random(&random);
    const id = std.fmt.bytesToHex(random, .lower);
    const path = try std.fmt.allocPrint(a, "{s}/{s}.html", .{ dir, id });
    try @import("credential_store.zig").replaceFile(io, Io.Dir.cwd(), path, html, @enumFromInt(0o600));
    return path;
}

test "MCP app resource metadata supports nested and legacy keys, rejects non-ui URLs" {
    const a = std.testing.allocator;
    const modern = try std.json.parseFromSlice(Value, a, "{\"_meta\":{\"ui\":{\"resourceUri\":\"ui://test/app\"}}}", .{});
    defer modern.deinit();
    try std.testing.expectEqualStrings("ui://test/app", resourceUri(modern.value).?);
    const legacy = try std.json.parseFromSlice(Value, a, "{\"_meta\":{\"ui/resourceUri\":\"ui://legacy\"}}", .{});
    defer legacy.deinit();
    try std.testing.expectEqualStrings("ui://legacy", resourceUri(legacy.value).?);
    const bad = try std.json.parseFromSlice(Value, a, "{\"_meta\":{\"ui\":{\"resourceUri\":\"https://invalid\"}}}", .{});
    defer bad.deinit();
    try std.testing.expect(resourceUri(bad.value) == null);
}

test "MCP app resources require matching URI and app MIME type" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"result\":{\"contents\":[{\"uri\":\"ui://a\",\"mimeType\":\"text/html;profile=mcp-app\",\"text\":\"<h1>ok</h1>\"}]}}", .{});
    defer parsed.deinit();
    try std.testing.expect(readResource(parsed.value, "ui://a") != null);
    try std.testing.expect(readResource(parsed.value, "ui://b") == null);
}

test "app-only MCP tools stay out of the model catalog" {
    const p = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"_meta\":{\"ui\":{\"visibility\":[\"app\"]}}}", .{});
    defer p.deinit();
    try std.testing.expect(!modelVisible(p.value));
    try std.testing.expect(modelVisible(.{ .object = .empty }));
}
