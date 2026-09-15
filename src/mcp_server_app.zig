//! Optional presentation for the stdio task tool; no execution authority.
const std = @import("std");
const Value = std.json.Value;
pub const uri = "ui://codegraff/task-result";
pub const mime = "text/html;profile=mcp-app";
pub const resource = .{ .uri = uri, .name = "task_result", .title = "Codegraff task result", .description = "Inspect task output, limits and completion status.", .mimeType = mime };

fn get(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

pub fn supported(params: Value) bool {
    const types = get(get(get(get(params, "capabilities"), "extensions"), "io.modelcontextprotocol/ui"), "mimeTypes");
    if (types != .array) return false;
    for (types.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, mime)) return true;
    }
    return false;
}

pub fn catalog(a: std.mem.Allocator, source: []const u8, apps: bool) !Value {
    const value = try std.json.parseFromSliceLeaky(Value, a, source, .{});
    const tool = &value.object.get("tools").?.array.items[0];
    try tool.object.put(a, "title", .{ .string = "Run a Codegraff task" });
    if (apps) {
        const meta = try std.json.parseFromSliceLeaky(Value, a,
            \\{"ui":{"resourceUri":"ui://codegraff/task-result","visibility":["model"]}}
        , .{});
        try tool.object.put(a, "_meta", meta);
    }
    const schema = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"object","properties":{"text":{"type":"string"},"status":{"type":"string","enum":["completed","failed","timed_out","cancelled"]},"output_truncated":{"type":"boolean"},"timeout_seconds":{"type":"integer"},"max_model_calls":{"type":"integer"}},"required":["text","status","output_truncated","timeout_seconds","max_model_calls"],"additionalProperties":false}
    , .{});
    try tool.object.put(a, "outputSchema", schema);
    return value;
}

const template = @embedFile("mcp_task_app.html");
const marker = "/* CODEGRAFF_THEME */";
const theme_offset = std.mem.indexOf(u8, template, marker).?;
const html = template[0..theme_offset] ++ @embedFile("ui_theme") ++ template[theme_offset + marker.len ..];

const payload = .{ .contents = .{.{
    .uri = uri,
    .mimeType = mime,
    .text = html,
    ._meta = .{ .ui = .{
        .csp = .{ .connectDomains = [0][]const u8{}, .resourceDomains = [0][]const u8{} },
        .prefersBorder = true,
    } },
}} };

pub fn contents() @TypeOf(payload) {
    return payload;
}
