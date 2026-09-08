//! Constraint scope classification (#789).
//!
//! Implicit rejections stay local. Durable project policy requires standing
//! language ("never … in this project") or an explicit `scope=project` argument.

const std = @import("std");

pub const Scope = enum {
    turn,
    task,
    session,
    project,
    /// Pre-#789 records: still injected, listed as review-needed.
    legacy,

    pub fn parse(s: []const u8) Scope {
        if (std.mem.eql(u8, s, "turn")) return .turn;
        if (std.mem.eql(u8, s, "task")) return .task;
        if (std.mem.eql(u8, s, "session")) return .session;
        if (std.mem.eql(u8, s, "project")) return .project;
        if (std.mem.eql(u8, s, "legacy")) return .legacy;
        return .legacy;
    }

    pub fn durable(self: Scope) bool {
        return self == .project;
    }
};

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Classify user language. An explicit `hint` from the tool argument wins
/// when it is a known scope; otherwise language decides.
pub fn classify(text: []const u8, hint: ?[]const u8) Scope {
    if (hint) |h| {
        const t = std.mem.trim(u8, h, " \t");
        if (t.len > 0 and !std.mem.eql(u8, t, "legacy")) {
            const s = Scope.parse(t);
            if (s != .legacy) return s;
        }
    }
    var buf: [512]u8 = undefined;
    const n = @min(text.len, buf.len);
    for (text[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const s = buf[0..n];

    if (has(s, "right now") or has(s, "this turn") or has(s, "just this once") or
        has(s, "for now") or (has(s, "not this") and has(s, "now")))
        return .turn;
    if (has(s, "for this task") or has(s, "this task") or has(s, "this goal") or
        has(s, "for this run") or has(s, "this job"))
        return .task;
    if (has(s, "in this project") or has(s, "for this project") or
        has(s, "across this project") or has(s, "every future") or
        has(s, "from now on") or std.mem.startsWith(u8, std.mem.trim(u8, s, " \t"), "never ") or
        has(s, "always ") or has(s, "standing "))
        return .project;
    if (has(s, "this session") or has(s, "for this session") or has(s, "while we") or has(s, "here"))
        return .session;
    return .session;
}

/// Whether a stored item should ride the current injection.
pub fn visible(scope: Scope, item_session: []const u8, item_task: []const u8, session: []const u8, task: []const u8) bool {
    return switch (scope) {
        .project, .legacy => true,
        .session => item_session.len == 0 or std.mem.eql(u8, item_session, session),
        .task => task.len > 0 and (item_task.len == 0 or std.mem.eql(u8, item_task, task)),
        .turn => false,
    };
}

test "#789: right now stays a turn; never-in-project is durable" {
    try std.testing.expectEqual(Scope.turn, classify("I don't want this right now", null));
    try std.testing.expectEqual(Scope.task, classify("For this task, do not add dots", null));
    try std.testing.expectEqual(Scope.project, classify("Never do X in this project", null));
    try std.testing.expectEqual(Scope.session, classify("no dots", null));
    try std.testing.expectEqual(Scope.session, classify("not vanilla JS", null));
    try std.testing.expectEqual(Scope.project, classify("no dots", "project"));
    try std.testing.expect(classify("Never add scroll hints", null).durable());
    try std.testing.expect(!classify("I don't want this right now", null).durable());
}

test "#789: here / this session stay local and do not widen" {
    try std.testing.expectEqual(Scope.session, classify("do not do that here", null));
    try std.testing.expectEqual(Scope.session, classify("for this session skip the linter", null));
    try std.testing.expect(!visible(.turn, "", "", "s", "t"));
    try std.testing.expect(visible(.project, "", "", "s", "t"));
    try std.testing.expect(visible(.legacy, "", "", "s", "t"));
    try std.testing.expect(visible(.session, "s1", "", "s1", ""));
    try std.testing.expect(visible(.session, "", "", "", ""));
    try std.testing.expect(!visible(.session, "s1", "", "s2", ""));
    try std.testing.expect(visible(.task, "", "goal-a", "s", "goal-a"));
    try std.testing.expect(!visible(.task, "", "goal-a", "s", "goal-b"));
}
