//! #845: composing or queuing a follow-up must not freeze the thinking
//! indicator or interrupt the live turn. Driven through Term (AGENTS.md).

const std = @import("std");

const engine = @import("engine.zig");
const glyphs = @import("glyphs.zig");
const Term = @import("sim.zig").Term;

fn attachThinking(term: *Term, alloc: std.mem.Allocator) !*engine.Job {
    try term.model.push(.user, "think about this");
    try term.model.push(.pending, "");
    const job = try alloc.create(engine.Job);
    job.* = .{
        .gpa = alloc,
        .history = &.{},
        .params = .{},
        .stream = .{},
        .raw = .{},
        .threaded = false,
    };
    job.events.attach(alloc);
    term.model.pending = job;
    return job;
}

test "queuing a follow-up keeps the thinking indicator live (#845)" {
    const alloc = std.testing.allocator;
    var term: Term = undefined;
    term.init(alloc, 80, 24);
    defer term.deinit();
    const job = try attachThinking(&term, alloc);
    _ = job;

    term.now_ms = 0;
    const idle = try term.screen();
    defer alloc.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, glyphs.thinking[0]) != null);

    _ = term.typeText("queued follow-up");
    try std.testing.expectEqualStrings("queued follow-up", term.model.input.getValue());
    try std.testing.expect(term.model.pending != null);
    try std.testing.expect(!term.model.cancel_requested);

    term.now_ms = 500;
    const composing = try term.screen();
    defer alloc.free(composing);
    try std.testing.expect(std.mem.indexOf(u8, composing, "Thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, composing, "queued follow-up") != null);
    try std.testing.expect(std.mem.indexOf(u8, composing, glyphs.thinking[1]) != null);
    try std.testing.expect(std.mem.indexOf(u8, composing, glyphs.thinking[0]) == null);

    _ = term.enter();
    try std.testing.expectEqual(@as(usize, 1), term.model.steer_queue.items.len);
    try std.testing.expectEqualStrings("queued follow-up", term.model.steer_queue.items[0]);
    try std.testing.expectEqualStrings("", term.model.input.getValue());
    try std.testing.expect(term.model.pending != null);
    try std.testing.expect(!term.model.cancel_requested);
    try std.testing.expect(term.model.pending.? == job);

    term.now_ms = 1000;
    const queued = try term.screen();
    defer alloc.free(queued);
    try std.testing.expect(std.mem.indexOf(u8, queued, "Thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, queued, "queued") != null);
    try std.testing.expect(std.mem.indexOf(u8, queued, glyphs.thinking[0]) != null);
    try std.testing.expect(std.mem.indexOf(u8, queued, glyphs.thinking[1]) == null);
}

test "empty Enter with a queued follow-up is the interrupt; typing is not (#845)" {
    const alloc = std.testing.allocator;
    var term: Term = undefined;
    term.init(alloc, 80, 24);
    defer term.deinit();
    _ = try attachThinking(&term, alloc);

    _ = term.typeText("next");
    _ = term.enter();
    try std.testing.expectEqual(@as(usize, 1), term.model.steer_queue.items.len);
    try std.testing.expect(!term.model.cancel_requested);

    _ = term.enter();
    try std.testing.expect(term.model.cancel_requested);
    try std.testing.expect(term.model.pending != null);
}
