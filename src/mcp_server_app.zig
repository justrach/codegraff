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
        \\{"type":"object","properties":{"text":{"type":"string"},"status":{"type":"string","enum":["completed","failed","timed_out","cancelled"]},"output_truncated":{"type":"boolean"},"timeout_seconds":{"type":"integer"},"max_model_calls":{"type":"integer"},"context_chars":{"type":"integer"},"context_summarized":{"type":"boolean"},"context_used_chars":{"type":"integer"},"usage_reported":{"type":"boolean","description":"False: this result carries no per-task usage or settled charge for CHILD EXECUTION. Preprocessing is reported separately in `preprocess`."},"usage_unavailable_reason":{"type":"string","description":"Why per-task child usage is unavailable, and what is authoritative instead. Present whenever usage_reported is false."},"preprocess":{"type":"object","description":"What preparing the context cost, when it had to be summarized. Distinct from child execution; a settled charge counted once, never a list-rate estimate.","properties":{"cost_usd":{"type":["number","null"],"description":"Settled charge for summarization, or null when none was available."},"usage_complete":{"type":"boolean"},"input_tokens":{"type":"integer"},"output_tokens":{"type":"integer"},"unavailable_reason":{"type":"string","description":"Empty when a settled charge is present; otherwise why it is not."}},"required":["cost_usd","usage_complete","input_tokens","output_tokens","unavailable_reason"],"additionalProperties":false}},"required":["text","status","output_truncated","timeout_seconds","max_model_calls","context_chars","context_summarized","context_used_chars","usage_reported","usage_unavailable_reason","preprocess"],"additionalProperties":false}
    , .{});
    try tool.object.put(a, "outputSchema", schema);
    return value;
}

/// The page and its theme ship gzipped (build.zig); the theme is spliced in
/// where the page marks it.
pub fn contents(a: std.mem.Allocator) !Contents {
    const gunzip = @import("update_archive.zig").gunzip;
    const template = try gunzip(a, @embedFile("mcp_task_app.gz"));
    const marker = "/* CODEGRAFF_THEME */";
    const at = std.mem.indexOf(u8, template, marker).?;
    const html = try std.mem.concat(a, u8, &.{ template[0..at], try gunzip(a, @embedFile("ui_theme.gz")), template[at + marker.len ..] });
    return .{ .contents = .{.{ .text = html }} };
}

pub const Contents = struct {
    contents: [1]struct {
        uri: []const u8 = uri,
        mimeType: []const u8 = mime,
        text: []const u8,
        _meta: struct {
            ui: struct {
                csp: struct { connectDomains: [0][]const u8 = .{}, resourceDomains: [0][]const u8 = .{} } = .{},
                prefersBorder: bool = true,
            } = .{},
        } = .{},
    },
};
