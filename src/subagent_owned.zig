//! Background jobs must not borrow the REPL turn's stack approval object or
//! provider strings. Session services remain borrowed until job teardown.
const std = @import("std");
const tools = @import("tools.zig");
const Provider = @import("provider.zig").Provider;
const Approvals = @import("approvals.zig").Approvals;

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    approvals: Approvals = .{},

    pub fn init(gpa: std.mem.Allocator) Owned {
        return .{ .arena = .init(gpa) };
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
