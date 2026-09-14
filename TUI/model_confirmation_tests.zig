//! /model confirmation regressions, driven through terminal command dispatch.
//! Imported by the parent test root; callbacks never contact a provider.
const std = @import("std");
const engine = @import("engine.zig");
const sim = @import("sim.zig");

const Fixture = struct {
    provider: []const u8 = "seat-a",
    model: []const u8 = "model-a",
    requested: []const u8 = "model-a",
    fail: bool = false,
    picker: bool = false,
    calls: usize = 0,
    valid_request: bool = true,

    fn select(ctx: ?*anyopaque, alloc: std.mem.Allocator, provider: []const u8, name: []const u8) ?engine.Picked {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        // Typed commands must leave routing to the backend, unlike picker rows.
        const expected_provider = if (self.picker) self.provider else "";
        self.valid_request = self.valid_request and std.mem.eql(u8, provider, expected_provider) and std.mem.eql(u8, name, self.requested);
        if (self.fail) return null;
        return .{
            .model = alloc.dupe(u8, self.model) catch return null,
            .provider = self.provider,
        };
    }
};

const Saved = struct {
    ctx: ?*anyopaque,
    callback: ?engine.ModelFn,
    model: []const u8,
    provider: []const u8,

    fn install(fixture: *Fixture) Saved {
        const saved: Saved = .{
            .ctx = engine.g_turn_ctx,
            .callback = engine.g_model_fn,
            .model = engine.g_model_name,
            .provider = engine.g_model_provider,
        };
        engine.g_turn_ctx = fixture;
        engine.g_model_fn = Fixture.select;
        engine.g_model_name = "model-a";
        engine.g_model_provider = "seat-a";
        return saved;
    }

    fn restore(self: Saved) void {
        engine.g_turn_ctx = self.ctx;
        engine.g_model_fn = self.callback;
        engine.g_model_name = self.model;
        engine.g_model_provider = self.provider;
    }
};

fn submit(term: *sim.Term, name: []const u8) !void {
    _ = term.typeText("/model ");
    _ = term.typeText(name);
    _ = term.enter();
    try std.testing.expect(term.model.pending == null);
    try std.testing.expect(term.model.bg == null);
}

fn expectConfirmation(term: *sim.Term, expected: []const u8) !void {
    const history = term.model.history.items;
    try std.testing.expect(history.len > 0);
    const last = history[history.len - 1];
    try std.testing.expectEqual(.system, last.kind);
    try std.testing.expectEqualStrings(expected, last.text);
}

fn successfulSelection(fixture: *Fixture, expected: []const u8, repetitions: usize) !void {
    const saved = Saved.install(fixture);
    defer saved.restore();
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 100, 30);
    defer term.deinit();
    for (0..repetitions) |_| {
        try submit(&term, fixture.requested);
        try expectConfirmation(&term, expected);
        try std.testing.expectEqualStrings(fixture.model, engine.g_model_name);
        try std.testing.expectEqualStrings(fixture.provider, engine.g_model_provider);
    }
    try std.testing.expectEqual(repetitions, fixture.calls);
    try std.testing.expect(fixture.valid_request);
}

test "model confirmation: repeated resolved selection is already using" {
    var fixture: Fixture = .{};
    // The second result is freshly allocated while the previous model is owned
    // by the UI: compare values before adoption frees the previous allocation.
    try successfulSelection(&fixture, "already using model-a · seat-a", 2);
}

test "model confirmation: alias resolving to current selection is already using" {
    var fixture: Fixture = .{ .requested = "friendly-alias" };
    try successfulSelection(&fixture, "already using model-a · seat-a", 1);
}

test "model confirmation: provider-only change is switched to" {
    var fixture: Fixture = .{ .provider = "seat-b" };
    try successfulSelection(&fixture, "switched to model-a · seat-b", 1);
}

test "model confirmation: actual model change is switched to" {
    var fixture: Fixture = .{ .model = "model-b", .requested = "model-b" };
    try successfulSelection(&fixture, "switched to model-b · seat-a", 1);
}

test "model confirmation: failure retains error and current selection" {
    var fixture: Fixture = .{};
    const saved = Saved.install(&fixture);
    defer saved.restore();
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 100, 30);
    defer term.deinit();
    // Establish an owned selection first, then ensure failure leaves it intact.
    try submit(&term, fixture.requested);
    const owned = term.model.model_override.?;
    fixture.fail = true;
    fixture.requested = "unavailable";
    try submit(&term, fixture.requested);
    const history = term.model.history.items;
    const last = history[history.len - 1];
    try std.testing.expectEqual(.err, last.kind);
    try std.testing.expectEqualStrings("couldn't switch to 'unavailable'", last.text);
    try std.testing.expectEqualStrings("model-a", engine.g_model_name);
    try std.testing.expectEqualStrings("seat-a", engine.g_model_provider);
    try std.testing.expect(term.model.model_override.?.ptr == owned.ptr);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expect(fixture.valid_request);
}

fn pick(term: *sim.Term) !void {
    _ = term.typeText("/model");
    _ = term.enter();
    try std.testing.expectEqual(.model, term.model.overlay);
    _ = term.enter();
    try std.testing.expect(term.model.pending == null);
    try std.testing.expect(term.model.bg == null);
}

fn pickerSelection(fixture: *Fixture, expected: []const u8, repetitions: usize) !void {
    fixture.picker = true;
    const saved = Saved.install(fixture);
    defer saved.restore();
    const previous = engine.g_model_entries;
    defer engine.g_model_entries = previous;
    const rows = [_]engine.ModelEntry{.{ .name = fixture.requested, .provider = fixture.provider, .has_key = true }};
    engine.g_model_entries = &rows;
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 100, 30);
    defer term.deinit();
    for (0..repetitions) |_| {
        try pick(&term);
        try expectConfirmation(&term, expected);
        try std.testing.expectEqualStrings(if (repetitions > 1) "already using this model" else fixture.model, term.model.toast);
        try std.testing.expectEqualStrings(fixture.model, engine.g_model_name);
        try std.testing.expectEqualStrings(fixture.provider, engine.g_model_provider);
    }
    try std.testing.expectEqual(repetitions, fixture.calls);
    try std.testing.expect(fixture.valid_request);
}

test "model confirmation: picker same row twice is already using" {
    var fixture: Fixture = .{};
    try pickerSelection(&fixture, "already using model-a · seat-a", 2);
}

test "model confirmation: picker provider change retains model arrow" {
    var fixture: Fixture = .{ .provider = "seat-b" };
    try pickerSelection(&fixture, "model → model-a · seat-b", 1);
}

test "model confirmation: picker model change retains model arrow" {
    var fixture: Fixture = .{ .model = "model-b", .requested = "model-b" };
    try pickerSelection(&fixture, "model → model-b · seat-a", 1);
}

test "model confirmation: failed picker retains owned selection and error toast" {
    var fixture: Fixture = .{};
    const saved = Saved.install(&fixture);
    defer saved.restore();
    const previous = engine.g_model_entries;
    defer engine.g_model_entries = previous;
    const rows = [_]engine.ModelEntry{.{ .name = "unavailable", .provider = "seat-b", .has_key = true }};
    engine.g_model_entries = &rows;
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 100, 30);
    defer term.deinit();
    try submit(&term, fixture.requested);
    const owned = term.model.model_override.?;
    const history_len = term.model.history.items.len;
    fixture.fail = true;
    fixture.picker = true;
    fixture.provider = "seat-b";
    fixture.requested = "unavailable";
    try pick(&term);
    try std.testing.expectEqualStrings("couldn't switch", term.model.toast);
    try std.testing.expectEqualStrings("model-a", engine.g_model_name);
    try std.testing.expectEqualStrings("seat-a", engine.g_model_provider);
    try std.testing.expect(term.model.model_override.?.ptr == owned.ptr);
    try std.testing.expectEqual(history_len, term.model.history.items.len);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expect(fixture.valid_request);
}
