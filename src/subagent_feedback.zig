//! Bounded, owned feedback for one live background child. Only its own worker
//! mutates history. Completion and enqueue share the same lock so an accepted
//! message cannot fall into the gap after the final response was checked.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_message_bytes = 16 * 1024;
pub const max_pending_bytes = 64 * 1024;
pub const max_pending_messages = 32;

pub fn deliverToAgent(agent: anytype) !void {
    if (agent.feedback) |inbox| {
        if (try inbox.deliver(agent.gpa, agent.io, agent.messageMutationAlloc(), &agent.messages)) agent.completed = null;
    }
}

pub const Inbox = struct {
    mutex: Io.Mutex = .init,
    pending: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    delivered: usize = 0,
    closed: bool = false,

    pub fn enqueue(self: *Inbox, gpa: Allocator, io: Io, text: []const u8) !void {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyMessage;
        if (text.len > max_message_bytes) return error.MessageTooLarge;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return error.AgentFinished;
        if (self.pending.items.len >= max_pending_messages or text.len > max_pending_bytes - self.bytes) return error.InboxFull;
        const owned = try gpa.dupe(u8, text);
        errdefer gpa.free(owned);
        try self.pending.append(gpa, owned);
        self.bytes += owned.len;
    }

    pub fn deliver(self: *Inbox, gpa: Allocator, io: Io, arena: Allocator, history: *std.json.Array) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.pending.items.len == 0) return false;
        // Prepare the entire batch before committing history or consuming the
        // inbox. Allocation failure must leave every accepted message queued.
        const batch = try arena.alloc(std.json.Value, self.pending.items.len);
        defer arena.free(batch);
        try history.ensureUnusedCapacity(batch.len);
        for (self.pending.items, batch) |text, *message| {
            const body = try std.fmt.allocPrint(arena, "[Parent task feedback]\n{s}", .{text});
            message.* = try @import("messages.zig").textMessage(arena, "user", body);
        }
        for (batch) |message| history.appendAssumeCapacity(message);
        self.delivered += batch.len;
        for (self.pending.items) |text| gpa.free(text);
        self.pending.clearRetainingCapacity();
        self.bytes = 0;
        return true;
    }

    /// Called only after the child has a final answer. Pending feedback wins
    /// another step; otherwise close admission before publishing completion.
    pub fn tryFinish(self: *Inbox, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.pending.items.len != 0) return false;
        self.closed = true;
        return true;
    }

    /// Error/cancel/teardown closes admission too. Return the undelivered count
    /// so the final report can distinguish queued feedback from applied work.
    pub fn close(self: *Inbox, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        return self.pending.items.len;
    }

    /// The pump has been joined and the job removed from the live registry.
    pub fn deinit(self: *Inbox, gpa: Allocator) void {
        for (self.pending.items) |text| gpa.free(text);
        self.pending.deinit(gpa);
    }
};
