//! Rendering an MCP `tools/call` result's `content` array into the text the
//! model reads, plus the image blocks inside it (#249). Split out of mcp.zig
//! rather than grown there: that file was already within 30 lines of the
//! 600-line ceiling.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const vision = @import("vision.zig");

/// Where a staged image goes and what the active model can do with it. The
/// registry owns the slot; only the per-turn handoff can reach the agent.
pub const Stage = struct {
    arena: Allocator,
    slot: *?vision.PendingImage,
    label: []const u8,
    supports_vision: bool,
};

/// Render `result.content` into `w`.
///
/// Image blocks used to fall straight through this walk — it only looked for a
/// `text` field — so an image-only result reached the model as the empty string
/// with no hint that pixels had ever come back (#249). Now the first one is
/// staged as a real vision attachment and every one of them is named in the
/// text. Living outside `Registry.call` also makes the mixed text+image walk
/// testable without a live server.
pub fn renderContent(w: *Io.Writer, content: Value, stage: Stage) !void {
    if (content != .array) return;
    for (content.array.items) |block| {
        if (block != .object) continue;
        if (block.object.get("text")) |txt| if (txt == .string) {
            if (w.buffered().len > 0) try w.writeByte('\n');
            try w.writeAll(txt.string);
        };
        if (block.object.get("type")) |kind| if (kind == .string) {
            if (std.mem.eql(u8, kind.string, "resource_link")) {
                try separator(w);
                try w.print("[MCP resource link] {s}: {s}", .{ field(block.object, "name", "resource"), field(block.object, "uri", "URI unavailable") });
                if (block.object.get("description")) |desc| if (desc == .string) try w.print("\n{s}", .{desc.string});
            } else if (std.mem.eql(u8, kind.string, "resource")) {
                try separator(w);
                if (block.object.get("resource")) |resource| {
                    if (resource == .object) {
                        try w.print("[MCP resource] {s}", .{field(resource.object, "uri", "URI unavailable")});
                        if (resource.object.get("text")) |text| {
                            if (text == .string) try w.print("\n{s}", .{text.string});
                        } else if (resource.object.get("blob") != null) {
                            try w.print("\n[binary resource ({s}); payload not rendered]", .{field(resource.object, "mimeType", "unknown MIME type")});
                        }
                    } else try w.writeAll("[MCP resource unavailable: malformed resource]");
                } else try w.writeAll("[MCP resource unavailable: missing resource]");
            } else if (std.mem.eql(u8, kind.string, "audio")) {
                try separator(w);
                try w.print("[MCP audio ({s}); payload not rendered]", .{field(block.object, "mimeType", "unknown MIME type")});
            }
        };
        if (vision.mcpImageBlock(block)) |img| {
            const fate: vision.McpImageFate = if (!stage.supports_vision)
                .no_vision
            else if (stage.slot.* != null) .already_staged else .staged;
            if (fate == .staged) stage.slot.* = img.stage(stage.arena, stage.label) catch null;
            if (w.buffered().len > 0) try w.writeByte('\n');
            try vision.mcpImageNote(w, img, fate);
        }
    }
}

fn separator(w: *Io.Writer) !void {
    if (w.buffered().len > 0) try w.writeByte('\n');
}

fn field(object: std.json.ObjectMap, key: []const u8, fallback: []const u8) []const u8 {
    const value = object.get(key) orelse return fallback;
    return if (value == .string) value.string else fallback;
}

/// Offsets remain valid after the allocating writer transfers its buffer.
pub const StructuredRange = struct { start: usize, end: usize };

/// Keep the human-readable result and its independent structured payload.
/// A plain JSON text mirror stays byte-identical; mixed text/images/resources
/// cannot suppress structuredContent. Scratch dies with the response arena.
pub fn renderResult(w: *Io.Writer, result: std.json.ObjectMap, stage: Stage, scratch: Allocator) !?StructuredRange {
    const start = w.buffered().len;
    if (result.get("content")) |content| try renderContent(w, content, stage);
    const structured = result.get("structuredContent") orelse return null;
    const json = try std.json.Stringify.valueAlloc(scratch, structured, .{});
    const body = std.mem.trim(u8, w.buffered()[start..], " \t\r\n");
    if (body.len > 0) {
        const mirror = std.json.parseFromSliceLeaky(Value, scratch, body, .{}) catch null;
        if (mirror) |value| {
            const canonical = try std.json.Stringify.valueAlloc(scratch, value, .{});
            if (std.mem.eql(u8, json, canonical)) return .{ .start = start, .end = w.buffered().len };
        }
        try w.writeAll("\n[structuredContent]\n");
    }
    const json_start = w.buffered().len;
    try w.writeAll(json);
    return .{ .start = json_start, .end = w.buffered().len };
}
