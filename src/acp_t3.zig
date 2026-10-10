//! ACP client profile for T3 Code (`clientInfo.name` "t3-code…"). T3 owns
//! the session folder, worktrees, model choice and approval mode, and it
//! appends its own context block to every prompt. These hooks fit graff's v1
//! session to that; every other client keeps the default behavior.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const util = @import("util.zig");
const proto = @import("acp_protocol.zig");

var on: bool = false;

/// Read once per `initialize`; T3's probes use suffixed names ("t3-code-provider-test").
pub fn note(params: ?Value) void {
    on = isT3(params);
}

pub fn active() bool {
    return on;
}

fn isT3(params: ?Value) bool {
    const p = params orelse return false;
    if (p != .object) return false;
    const info = p.object.get("clientInfo") orelse return false;
    if (info != .object) return false;
    const name = util.strFieldObj(info.object, "name") orelse return false;
    return std.mem.startsWith(u8, name, "t3-code");
}

/// T3 sends a slash command as the first text block and appends a context
/// block after it; the command is that first block alone. Anything else
/// (including room-framed text) passes through unchanged.
pub fn slashText(prompt: ?Value, flattened: []const u8, framed: []const u8) []const u8 {
    if (!on or !std.mem.eql(u8, flattened, framed)) return framed;
    const blocks = prompt orelse return framed;
    if (blocks != .array or blocks.array.items.len < 2) return framed;
    const first = blocks.array.items[0];
    if (first != .object or !std.mem.eql(u8, util.strFieldObj(first.object, "type") orelse "", "text")) return framed;
    const text = util.strFieldObj(first.object, "text") orelse return framed;
    return if (std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t\r\n"), "/")) text else framed;
}

/// T3 renders replies as Markdown, which folds a command's table into one
/// paragraph; multi-line command output goes out as a text block.
pub fn slashReply(arena: Allocator, plain: []const u8) ![]const u8 {
    if (!on or std.mem.indexOfScalar(u8, std.mem.trim(u8, plain, "\n"), '\n') == null) return plain;
    return std.fmt.allocPrint(arena, "```text\n{s}\n```", .{std.mem.trimEnd(u8, plain, "\n")});
}

/// T3 diffs and checkpoints the folder it names; graff's auto-isolated tree
/// would hide every edit from it.
pub fn keepsIsolatedTree() bool {
    return !on;
}

/// T3 has its own `/model` (driven by the model config option) and its own
/// approval modes, which `/yolo` would silently bypass.
const hidden = [_][]const u8{ "model", "yolo" };

pub fn commands(arena: Allocator, all: []const proto.AvailableCommand) ![]const proto.AvailableCommand {
    if (!on) return all;
    var out: std.ArrayList(proto.AvailableCommand) = .empty;
    outer: for (all) |c| {
        for (hidden) |h| if (std.mem.eql(u8, c.name, h)) continue :outer;
        try out.append(arena, c);
    }
    return out.items;
}

test "profile turns on only for T3 Code's client names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer on = false;
    for ([_][]const u8{ "{\"clientInfo\":{\"name\":\"t3-code\"}}", "{\"clientInfo\":{\"name\":\"t3-code-provider-test\"}}" }) |json| {
        note(try std.json.parseFromSliceLeaky(Value, a, json, .{}));
        try std.testing.expect(active());
    }
    for ([_][]const u8{ "{\"clientInfo\":{\"name\":\"zed\"}}", "{}", "{\"clientInfo\":\"t3-code\"}" }) |json| {
        note(try std.json.parseFromSliceLeaky(Value, a, json, .{}));
        try std.testing.expect(!active());
    }
    note(null);
    try std.testing.expect(!active());
}

test "T3 slash command is the first block; context, prose and room text pass through" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer on = false;
    const prompt = try std.json.parseFromSliceLeaky(Value, a, "[{\"type\":\"text\",\"text\":\"/models\"},{\"type\":\"text\",\"text\":\"<runtime_info>x</runtime_info>\"}]", .{});
    const flat = "/models\n\n<runtime_info>x</runtime_info>";
    try std.testing.expectEqualStrings(flat, slashText(prompt, flat, flat)); // other clients
    on = true;
    try std.testing.expectEqualStrings("/models", slashText(prompt, flat, flat));
    try std.testing.expectEqualStrings("[room] /models", slashText(prompt, flat, "[room] /models"));
    const prose = try std.json.parseFromSliceLeaky(Value, a, "[{\"type\":\"text\",\"text\":\"fix it\"},{\"type\":\"text\",\"text\":\"ctx\"}]", .{});
    try std.testing.expectEqualStrings("fix it\n\nctx", slashText(prose, "fix it\n\nctx", "fix it\n\nctx"));
}

test "T3 fences multi-line command output; one-liners and other clients unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer on = false;
    try std.testing.expectEqualStrings("a\nb\n", try slashReply(a, "a\nb\n"));
    on = true;
    try std.testing.expectEqualStrings("```text\na\nb\n```", try slashReply(a, "a\nb\n"));
    try std.testing.expectEqualStrings("effort: high\n", try slashReply(a, "effort: high\n"));
}

test "T3 hides its own duplicates from the command list and drops isolated trees" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    defer on = false;
    const all = proto.slashCommands();
    try std.testing.expect(keepsIsolatedTree());
    try std.testing.expectEqual(all.len, (try commands(arena_state.allocator(), all)).len);
    on = true;
    try std.testing.expect(!keepsIsolatedTree());
    const shown = try commands(arena_state.allocator(), all);
    try std.testing.expectEqual(all.len - hidden.len, shown.len);
    for (shown) |c| for (hidden) |h| try std.testing.expect(!std.mem.eql(u8, c.name, h));
}
