//! Background jobs must not borrow the REPL turn's stack approval object or
//! provider strings. Session services remain borrowed until job teardown.
const std = @import("std");
const tools = @import("tools.zig");
const Provider = @import("provider.zig").Provider;
const Approvals = @import("approvals.zig").Approvals;

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    history: ?std.heap.ArenaAllocator = null,
    approvals: Approvals = .{},

    pub fn init(gpa: std.mem.Allocator) Owned {
        return .{ .arena = .init(gpa) };
    }

    pub fn releaseHistory(self: *Owned) void {
        if (self.history) |*arena| arena.deinit();
        self.history = null;
    }

    pub fn deinit(self: *Owned) void {
        self.releaseHistory();
        self.arena.deinit();
    }

    pub fn provider(self: *Owned, source: Provider) !Provider {
        var copy = source;
        inline for (.{ "id", "url", "api_key", "model", "account" }) |field|
            @field(copy, field) = try self.arena.allocator().dupe(u8, @field(source, field));
        return copy;
    }

    pub fn context(self: *Owned, source: tools.ToolCtx) !tools.ToolCtx {
        const a = self.arena.allocator();
        var copy = source;
        copy.provider = try self.provider(source.provider);
        if (source.subagent_provider) |p| copy.subagent_provider = try self.provider(p);
        if (source.agent_cwd) |cwd| copy.agent_cwd = try a.dupe(u8, cwd);
        copy.tools_used = null;
        copy.plan_read_owner = null;
        copy.worker_family = try a.dupe(u8, source.worker_family);
        copy.session_name = try a.dupe(u8, source.session_name);
        copy.parent_tool_call_id = try a.dupe(u8, source.parent_tool_call_id);
        copy.parent_task = try a.dupe(u8, source.parent_task);
        copy.parent_messages = &.{}; // the caller's history moves on once this call returns
        if (source.fork_source) |snapshot| {
            self.history = .init(source.gpa);
            copy.fork_source = try snapshot.clone(self.history.?.allocator());
        }
        if (source.worker_id) |id| copy.worker_id = try a.dupe(u8, id);
        if (source.approvals) |ap| {
            ap.mutex.lockUncancelable(source.io);
            defer ap.mutex.unlock(source.io);
            self.approvals.yolo = ap.yolo;
            for (ap.prefixes.items) |p| try self.approvals.prefixes.append(a, try a.dupe(u8, p));
            for (ap.plan_read_roots.items) |p| try self.approvals.plan_read_roots.append(a, try a.dupe(u8, p));
            copy.approvals = &self.approvals;
        }
        return copy;
    }
};
