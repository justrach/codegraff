//! Per-invocation immutable policy ceilings. No process globals, environment
//! mutation, trusted-settings copies, or cross-workspace caches.
const std = @import("std");
const policy = @import("hard_policy.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const failed: policy.Document = .{ .problem = "hard policy: unable to capture inherited policy; operation denied" };

/// Load local settings separately from the inherited ceiling: ordering within
/// one operator document still works, but child allows cannot relax ancestors.
pub fn load(io: Io, a: Allocator, cwd: ?[]const u8, inherited: ?*const policy.Document) policy.Document {
    var dir = if (cwd) |path| Io.Dir.cwd().openDir(io, path, .{}) catch return failed else Io.Dir.cwd();
    defer if (cwd != null) dir.close(io);
    var doc = policy.loadAt(io, a, dir);
    doc.ceiling = inherited;
    return doc;
}

pub fn capture(io: Io, a: Allocator, cwd: ?[]const u8, inherited: ?*const policy.Document) *const policy.Document {
    const doc = a.create(policy.Document) catch return &failed;
    doc.* = load(io, a, cwd, inherited);
    return doc;
}

/// Detached workers outlive a root turn. Own every policy byte, not a pointer
/// into the spawning history/scratch arena (and never the full settings file).
pub fn clone(a: Allocator, source: *const policy.Document) Allocator.Error!*const policy.Document {
    const doc = try a.create(policy.Document);
    const statements = try a.alloc(policy.Statement, source.statements.len);
    for (source.statements, statements) |s, *dest| dest.* = .{
        .action = try a.dupe(u8, s.action),
        .resource = try a.dupe(u8, s.resource),
        .effect = s.effect,
    };
    doc.* = .{
        .statements = statements,
        .problem = if (source.problem) |p| try a.dupe(u8, p) else null,
        .ceiling = if (source.ceiling) |parent| try clone(a, parent) else null,
    };
    return doc;
}

pub fn check(io: Io, a: Allocator, cwd: ?[]const u8, inherited: ?*const policy.Document, action: []const u8, resource: []const u8) ?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const doc = load(io, scratch.allocator(), cwd, inherited);
    const reason = doc.denial(scratch.allocator(), action, resource) orelse return null;
    return a.dupe(u8, reason) catch "hard policy denied operation";
}

/// Root agents remain live to explicit user workspace changes; only children
/// carry the immutable snapshot captured before isolated cwd construction.
pub fn checkAgent(agent: anytype, a: Allocator, action: []const u8, resource: []const u8) ?[]const u8 {
    return check(agent.io, a, agent.agent_cwd, agent.hard_policy, action, resource);
}

pub fn captureAgent(agent: anytype) *const policy.Document {
    return capture(agent.io, agent.historyAlloc(), agent.agent_cwd, agent.hard_policy);
}
