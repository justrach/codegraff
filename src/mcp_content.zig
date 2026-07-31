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
