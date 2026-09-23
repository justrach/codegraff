//! A dependent workflow chain borrows one worktree until every stage finishes.
const std = @import("std");
const tools = @import("tools.zig");
const worktree = @import("agent_worktree.zig");

pub const Scope = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    tree: worktree.AgentWorktree,
    finished: bool = false,

    pub fn init(ctx: tools.ToolCtx) !Scope {
        var arena = std.heap.ArenaAllocator.init(ctx.gpa);
        errdefer arena.deinit();
        const tree = try worktree.agentWorktreeCreateAt(ctx.gpa, ctx.io, arena.allocator(), "workflow", ctx.agent_cwd orelse ".");
        return .{ .arena = arena, .gpa = ctx.gpa, .io = ctx.io, .tree = tree };
    }

    pub fn context(self: *const Scope, parent: tools.ToolCtx) tools.ToolCtx {
        var child = parent;
        child.agent_cwd = self.tree.path;
        return child;
    }

    pub fn finish(self: *Scope, out: tools.ToolOutput) !tools.ToolOutput {
        const outcome = worktree.agentWorktreeFinish(self.gpa, self.io, self.tree);
        self.finished = true;
        if (!outcome.kept) return out;
        defer self.gpa.free(out.text);
        return .{
            .text = try std.fmt.allocPrint(self.gpa, "{s}\n\n[workflow changes retained — path: {s}, branch: {s}; review and merge explicitly; not applied to the caller checkout]", .{ out.text, self.tree.path, self.tree.branch }),
            .is_error = out.is_error,
        };
    }

    pub fn deinit(self: *Scope) void {
        if (!self.finished) _ = worktree.agentWorktreeFinish(self.gpa, self.io, self.tree);
        self.arena.deinit();
    }
};
