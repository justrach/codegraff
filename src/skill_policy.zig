//! Hard restrictions are independent of user skill opt-outs and cached catalogs.
const std = @import("std");
const skills = @import("skill_docs.zig");
const policy = @import("hard_policy.zig");

pub fn filter(io: std.Io, arena: std.mem.Allocator, list: *std.ArrayList(skills.Skill)) void {
    const doc = policy.loadAt(io, arena, std.Io.Dir.cwd());
    var i: usize = 0;
    while (i < list.items.len) {
        if (!doc.allows("skill.use", list.items[i].name)) _ = list.orderedRemove(i) else i += 1;
    }
}

pub fn refusal(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !?@import("tools.zig").ToolOutput {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const reason = policy.check(io, scratch.allocator(), "skill.use", name) orelse return null;
    return .{ .text = try gpa.dupe(u8, reason), .is_error = true };
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, sk: skills.Skill) !@import("tools.zig").ToolOutput {
    if (try refusal(gpa, io, sk.name)) |blocked| return blocked;
    return .{ .text = try skills.render(gpa, io, sk) };
}

pub fn exec(gpa: std.mem.Allocator, io: std.Io, input: std.json.Value, cwd: ?[]const u8, inherited: ?*const policy.Document) !@import("tools.zig").ToolOutput {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const doc = @import("hard_policy_context.zig").load(io, a, cwd, inherited);
    const requested = std.mem.trim(u8, @import("tools.zig").strField(input, "name") orelse "", " \t\r\n");
    if (requested.len > 0) {
        // Resolve case-insensitive requests before checking the canonical
        // policy resource, including the cached fast path.
        for (skills.g_skills) |sk| {
            if (!std.ascii.eqlIgnoreCase(sk.name, requested)) continue;
            if (doc.denial(a, "skill.use", sk.name)) |reason| return .{ .text = try gpa.dupe(u8, reason), .is_error = true };
            return .{ .text = try skills.render(gpa, io, sk) };
        }
        if (doc.denial(a, "skill.use", requested)) |reason| return .{ .text = try gpa.dupe(u8, reason), .is_error = true };
    }
    const list = skills.scanAll(io, a);
    var visible: std.ArrayList(skills.Skill) = .empty;
    for (list) |sk| {
        if (requested.len > 0 and std.ascii.eqlIgnoreCase(sk.name, requested)) {
            if (doc.denial(a, "skill.use", sk.name)) |reason| return .{ .text = try gpa.dupe(u8, reason), .is_error = true };
            return .{ .text = try skills.render(gpa, io, sk) };
        }
        if (doc.allows("skill.use", sk.name)) try visible.append(a, sk);
    }
    return .{ .text = try skills.listing(gpa, visible.items, if (requested.len == 0) null else requested), .is_error = requested.len != 0 };
}
