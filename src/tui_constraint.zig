//! Host side of TUI `/never` / `/constraint`: the pager delegates to the
//! existing user-owned playbook command instead of duplicating ledger rules.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Agent = @import("agent.zig").Agent;
const playbook_glue = @import("playbook_glue.zig");
const repl_glue = @import("repl_glue.zig");

/// Run a constraint command without entering the line-REPL picker: the
/// fullscreen TUI owns stdin, so bare `/never` returns the scoped text list.
/// Caller frees the returned text.
pub fn runSlash(root: *Agent, gpa: Allocator, line: []const u8) ?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const saved_in = root.in;
    root.in = null;
    defer root.in = saved_in;
    const handled = playbook_glue.commandWithPromptAllocator(root, scratch_state.allocator(), root.arena, line, &aw.writer) catch
        return gpa.dupe(u8, "constraint command failed; rerun /never to verify ledger state") catch null;
    if (!handled) return null;
    return aw.toOwnedSlice() catch null;
}

/// `engine.ConstraintFn` — reaches the live root through `ReplCtx.root`.
pub fn constraintCb(ctx: ?*anyopaque, gpa: Allocator, line: []const u8) ?[]const u8 {
    const c: *repl_glue.ReplCtx = @ptrCast(@alignCast(ctx orelse return null));
    const root = c.root orelse return gpa.dupe(u8, "constraint review needs a live session") catch null;
    return runSlash(root, gpa, line);
}
