//! Assemble streamed chat tool calls by explicit ID, even when a provider
//! reuses a wire index. ID-less fragments follow the latest call at that index.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Call = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
    invalid: bool = false,
    thought_signature: []const u8 = "",
    extra_content: ?Value = null,

    pub fn acceptName(self: *Call, name: []const u8) void {
        if (name.len == 0) return;
        if (self.name.len > 0 and !std.mem.eql(u8, self.name, name)) {
            self.invalid = true; // A contradictory name cannot be executed safely.
            return;
        }
        self.name = name;
    }

    pub fn arguments(self: Call) []const u8 {
        return if (self.invalid) "[" else self.args.items;
    }
};

pub const Calls = struct {
    items: std.ArrayList(Call) = .empty,
    index_slots: std.ArrayList(?usize) = .empty,

    fn matchingId(self: *Calls, id: []const u8) ?usize {
        if (id.len == 0) return null;
        for (self.items.items, 0..) |call, slot| {
            if (std.mem.eql(u8, call.id, id)) return slot;
        }
        return null;
    }

    pub fn forFragment(self: *Calls, alloc: Allocator, tc: Value) !*Call {
        const index: ?usize = if (tc.object.get("index")) |ix|
            (if (ix == .integer and ix.integer >= 0) @as(usize, @intCast(ix.integer)) else null)
        else
            null;
        const id: []const u8 = if (tc.object.get("id")) |v|
            (if (v == .string) v.string else "")
        else
            "";
        var slot = self.matchingId(id);
        if (slot == null) {
            if (index) |ix| {
                while (self.index_slots.items.len <= ix) try self.index_slots.append(alloc, null);
                if (self.index_slots.items[ix]) |current| {
                    // Only a fresh nonempty ID starts another call at this index.
                    if (id.len == 0 or self.items.items[current].id.len == 0 or
                        std.mem.eql(u8, self.items.items[current].id, id))
                    {
                        slot = current;
                    } else if (!@import("tool_call_args.zig").isObjectString(std.heap.page_allocator, self.items.items[current].args.items)) {
                        self.items.items[current].invalid = true;
                    }
                }
            }
        }
        if (slot == null and index == null and id.len == 0 and self.items.items.len > 0)
            slot = self.items.items.len - 1;
        if (slot == null) {
            slot = self.items.items.len;
            try self.items.append(alloc, .{});
        }
        if (index) |ix| {
            while (self.index_slots.items.len <= ix) try self.index_slots.append(alloc, null);
            self.index_slots.items[ix] = slot;
        }
        const call = &self.items.items[slot.?];
        if (id.len > 0) call.id = id;
        return call;
    }
};
