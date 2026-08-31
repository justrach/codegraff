//! Fullscreen `/resume SOURCE [--branch DEST]` projection.

const std = @import("std");
const app = @import("app.zig");
const engine = @import("engine.zig");

pub fn run(self: *app.Model, spec: []const u8) void {
    if (spec.len == 0) {
        self.push(.system, "usage: /resume SOURCE [--branch DEST]") catch {};
        return;
    }
    const callback = engine.g_resume_fn orelse {
        self.push(.system, "resume isn't available (offline)") catch {};
        return;
    };
    var out: engine.ResumeOut = .{};
    if (!callback(engine.g_turn_ctx, self.alloc, spec, &out)) {
        if (out.note.len > 0) {
            self.push(.err, out.note) catch {};
            self.alloc.free(out.note);
        } else self.push(.err, "resume failed") catch {};
        return;
    }
    self.clearHistory();
    for (out.turns) |turn| {
        self.push(if (turn.role == .user) .user else .assistant, turn.text) catch {};
        self.alloc.free(turn.text);
    }
    if (out.turns.len > 0) self.alloc.free(out.turns);
    self.turns = self.userTurnCount();
    if (self.session_name) |old| self.alloc.free(old);
    self.session_name = out.session_name;
    if (self.goal) |old| self.alloc.free(old);
    self.goal = if (out.goal.len > 0) out.goal else null;
    self.strict = out.strict;
    self.ultracode = out.ultracode;
    if (out.note.len > 0) {
        self.push(.system, out.note) catch {};
        self.alloc.free(out.note);
    }
}

fn fakeResume(_: ?*anyopaque, gpa: std.mem.Allocator, spec: []const u8, out: *engine.ResumeOut) bool {
    if (!std.mem.eql(u8, spec, "base --branch child")) return false;
    const turns = gpa.alloc(engine.Turn, 2) catch return false;
    turns[0] = .{ .role = .user, .text = gpa.dupe(u8, "baseline prompt") catch return false };
    turns[1] = .{ .role = .assistant, .text = gpa.dupe(u8, "baseline answer") catch return false };
    out.* = .{
        .turns = turns,
        .session_name = gpa.dupe(u8, "child") catch return false,
        .note = gpa.dupe(u8, "branched base → child") catch return false,
    };
    return true;
}

test "fullscreen resume replaces transcript and selects the branch" {
    const saved = engine.g_resume_fn;
    defer engine.g_resume_fn = saved;
    engine.g_resume_fn = fakeResume;
    var model: app.Model = undefined;
    model.setup(std.testing.allocator);
    defer model.deinit();
    try model.push(.user, "stale prompt");
    run(&model, "base --branch child");
    try std.testing.expectEqualStrings("child", model.session_name.?);
    try std.testing.expectEqual(@as(usize, 3), model.history.items.len);
    try std.testing.expectEqualStrings("baseline prompt", model.history.items[0].text);
    try std.testing.expectEqualStrings("baseline answer", model.history.items[1].text);
    try std.testing.expectEqualStrings("branched base → child", model.history.items[2].text);
}
