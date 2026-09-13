const std = @import("std");
const Agent = @import("agent.zig").Agent;

pub fn messageMutationAlloc(self: *Agent) std.mem.Allocator {
    return self.message_mutation_arena orelse self.arena;
}
