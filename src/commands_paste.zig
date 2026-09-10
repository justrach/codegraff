//! `/paste`: stage a clipboard image, naming access/extract/convert failures
//! separately from an empty clipboard (#843).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const vision = @import("vision.zig");

pub fn tryHandle(root: *Agent, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/paste")) return false;
    if (builtin.os.tag != .macos) {
        try out.writeAll("clipboard image paste is macOS-only — use /image <path>\n");
        try out.flush();
        return true;
    }
    if (!vision.visionCapable(root.provider)) {
        try out.print("⚠ {s} can't see images — /model to a vision model (claude-*, gpt-5*) first\n", .{root.provider.model});
        try out.flush();
        return true;
    }
    switch (vision.grabClipboardImage(root.io, root.gpa)) {
        .empty => {
            vision.tracePaste(root, "no_image", "none", 0, "");
            try out.writeAll("no image on the clipboard — copy an image first (text? just paste it normally)\n");
        },
        .failed => |kind| {
            vision.tracePaste(root, "failed", @tagName(kind), 0, "");
            try out.print("{s}\n", .{vision.pasteFailMessage(kind)});
        },
        .ok => |grab| {
            defer grab.release(root.io, root.gpa);
            var pbuf: [320]u8 = undefined;
            const pasted = vision.stageImagePath(root, grab.path);
            vision.tracePasteResult(root, grab.flavor, pasted);
            switch (pasted) {
                .ok => |o| try out.print("📎 clipboard image attached ({s}, via {s}) — sent with your next message\n", .{ vision.fmtBytes(pbuf[0..16], o.bytes), grab.flavor.name() }),
                .no_vision => try out.print("⚠ {s} can't see images\n", .{root.provider.model}),
                .too_large, .not_found, .read_error => try out.print("{s}\n", .{vision.stageMessage(&pbuf, pasted, "the clipboard image")}),
            }
        },
    }
    try out.flush();
    return true;
}
