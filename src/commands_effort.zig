//! Provider-aware /effort and /reasoning selector.
const std = @import("std");
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const ReasoningEffort = main_mod.ReasoningEffort;
const pickers = @import("pickers.zig");
const er = @import("effort_route.zig");

const reasoning_levels = [_]pickers.PickItem{
    .{ .name = "Low", .desc = "Fast responses with lighter reasoning" },
    .{ .name = "Medium", .desc = "Balances speed and reasoning depth for everyday tasks" },
    .{ .name = "High", .desc = "Greater reasoning depth for complex problems" },
    .{ .name = "Extra high", .desc = "Extra high reasoning depth for complex problems" },
    .{ .name = "Max", .desc = "Maximum reasoning depth for the hardest problems" },
    .{ .name = "Ultra", .desc = "Maximum reasoning with automatic task delegation" },
};

fn normalized(root: *Agent, requested: []const u8) ?ReasoningEffort {
    const tag = er.normalize(root.provider.id, root.provider.model, requested);
    const effort = std.meta.stringToEnum(ReasoningEffort, tag) orelse return null;
    return if (er.allows(root.provider.id, root.provider.model, tag)) effort else .high;
}

pub fn handle(root: *Agent, arena: std.mem.Allocator, line: []const u8, out: *std.Io.Writer) !bool {
    if (!std.mem.startsWith(u8, line, "/effort") and !std.mem.startsWith(u8, line, "/reasoning")) return false;
    const prefix: []const u8 = if (std.mem.startsWith(u8, line, "/effort")) "/effort" else "/reasoning";
    const arg = std.mem.trim(u8, line[prefix.len..], " \t");
    const levels = er.levels(root.provider.id, root.provider.model);
    if (arg.len == 0 and main_mod.use_color and root.in != null) {
        const title = try std.fmt.allocPrint(arena, "Reasoning level for {s} ›", .{root.provider.model});
        var rows: [reasoning_levels.len]pickers.PickItem = undefined;
        var tags: [reasoning_levels.len]ReasoningEffort = undefined;
        const current = normalized(root, @tagName(root.reasoning)).?;
        var cur: usize = 0;
        for (levels, 0..) |tag, i| {
            const effort = std.meta.stringToEnum(ReasoningEffort, tag).?;
            tags[i] = effort;
            rows[i] = reasoning_levels[@intFromEnum(effort)];
            if (effort == current) cur = i;
        }
        const idx = pickers.listPickerAt(root, arena, out, title, rows[0..levels.len], cur) orelse return true;
        root.reasoning = tags[idx];
    } else if (arg.len != 0) {
        const requested = if (std.mem.eql(u8, arg, "med"))
            "medium"
        else if (std.mem.eql(u8, arg, "extra") or std.mem.eql(u8, arg, "extra-high") or std.mem.eql(u8, arg, "extra high"))
            "xhigh"
        else
            arg;
        root.reasoning = normalized(root, requested) orelse {
            try out.writeAll("usage: /effort ");
            for (levels, 0..) |tag, i| {
                if (i != 0) try out.writeByte('|');
                try out.writeAll(tag);
            }
            try out.writeByte('\n');
            try out.flush();
            return true;
        };
    } else {
        const current = normalized(root, @tagName(root.reasoning)).?;
        try out.print("reasoning effort: {s}\n", .{reasoning_levels[@intFromEnum(current)].name});
        try out.flush();
        return true;
    }
    _ = @import("repl_glue.zig").saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
    try out.print("reasoning effort: {s}{s}\n", .{
        reasoning_levels[@intFromEnum(root.reasoning)].name,
        if (!root.effortApplies()) " (current model ignores it — applies to xai, codex, deepseek, codegraff)" else "",
    });
    try out.flush();
    return true;
}
