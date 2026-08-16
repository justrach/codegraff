//! Tests for keys.zig — the dispatcher itself sits at the 600-line ceiling, so
//! its test block lives here. Reached from keys.zig's test block, which is
//! reached from root.zig: a module nobody references never runs its tests.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const keys = @import("keys.zig");
const Key = key_mod.Key;
const Model = app.Model;
const Effect = app.Effect;

const handle = keys.handle;

/// The Escape key through the PUBLIC door. `keys.esc` is private, and it should
/// stay that way: what a test wants pinned is what pressing Escape does, not
/// which internal helper happens to implement it.
fn esc(m: *Model) Effect {
    return handle(m, .escape);
}

test "Esc on a draft arms clear, second press clears" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.now_ms = 1000;
    m.input.setValue("draft") catch {};
    _ = esc(&m);
    try std.testing.expectEqual(app.EscArm.clear, m.esc_arm);
    try std.testing.expectEqualStrings("draft", m.input.getValue());
    m.now_ms = 1200;
    _ = esc(&m);
    try std.testing.expectEqualStrings("", m.input.getValue());
}

test "Ctrl+C quits when idle" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(Effect.quit, handle(&m, .{ .ctrl = 'c' }));
    try m.input.setValue("ab");
    _ = handle(&m, .{ .char = 'x' });
    try std.testing.expectEqual(Effect.stay, handle(&m, .{ .ctrl = 'z' }));
    try std.testing.expectEqualStrings("ab", m.input.getValue());
}

test "Ctrl+D quits an empty composer and is ignored with a draft (#549)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.input.setValue("half a thought");
    try std.testing.expectEqual(Effect.stay, handle(&m, .{ .ctrl = 'd' }));
    try std.testing.expectEqualStrings("half a thought", m.input.getValue());
    try m.input.setValue("   ");
    try std.testing.expectEqual(Effect.quit, handle(&m, .{ .ctrl = 'd' }));
    try m.input.setValue("");
    try std.testing.expectEqual(Effect.quit, handle(&m, .{ .ctrl = 'd' }));
}

test "Tab toggles focus" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(app.Focus.prompt, m.focus);
    _ = handle(&m, .tab);
    try std.testing.expectEqual(app.Focus.scrollback, m.focus);
    _ = handle(&m, .tab);
    try std.testing.expectEqual(app.Focus.prompt, m.focus);
}

test "Shift+Tab cycles Normal Plan Always-approve" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(app.AgentMode.normal, m.mode);
    _ = handle(&m, .shift_tab);
    try std.testing.expectEqual(app.AgentMode.plan, m.mode);
    _ = handle(&m, .shift_tab);
    try std.testing.expectEqual(app.AgentMode.always_approve, m.mode);
    _ = handle(&m, .shift_tab);
    try std.testing.expectEqual(app.AgentMode.normal, m.mode);
}

test "model overlay Enter picks the selected name" {
    engine.g_models = "grok-4, gpt-5.5";
    engine.g_model_name = "grok-4";
    defer {
        engine.g_models = "";
        engine.g_model_name = "";
        engine.g_model_fn = null;
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    m.overlay_sel = 1;
    _ = handle(&m, .enter);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqualStrings("gpt-5.5", engine.g_model_name);
}

test "model overlay type-to-search picks the filtered name" {
    engine.g_models = "grok-4, gpt-5.5, deepseek-v4-pro";
    engine.g_model_name = "grok-4";
    defer {
        engine.g_models = "";
        engine.g_model_name = "";
        engine.g_model_fn = null;
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    _ = handle(&m, .{ .char = 'd' });
    _ = handle(&m, .{ .char = 'e' });
    _ = handle(&m, .{ .char = 'e' });
    try std.testing.expectEqualStrings("dee", m.overlay_filter);
    _ = handle(&m, .enter);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqualStrings("deepseek-v4-pro", engine.g_model_name);
}

test "PgUp leaves follow; PgDn returns to the live tail" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_height = 24;
    try std.testing.expect(m.follow);
    _ = handle(&m, .page_up);
    try std.testing.expect(!m.follow);
    try std.testing.expect(m.scroll > 0);
    _ = handle(&m, .page_down);
    try std.testing.expect(m.follow);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
}

test "Cmd+Delete and Ctrl+U kill the draft, not the viewport" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_height = 24;
    try m.input.setValue("keep scrolling separate");
    m.input.cursor = m.input.getValue().len;
    _ = handle(&m, .delete_to_start);
    try std.testing.expectEqualStrings("", m.input.getValue());
    try std.testing.expect(m.follow);
    try m.input.setValue("word two");
    m.input.cursor = m.input.getValue().len;
    _ = handle(&m, .{ .ctrl = 'u' });
    try std.testing.expectEqualStrings("", m.input.getValue());
    try std.testing.expect(m.follow);
}

// The click-behaviour tests live beside the drag tests in selection.zig: a
// click and a drag are two readings of the same press, and they only stay
// separable if they are pinned together.

test "slash selection clamps to the filtered list and stays visible (#522)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.input.setValue("/");
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter("/", &idx);
    try std.testing.expect(n > 8); // the bug needs more commands than visible rows
    var presses: usize = 0;
    while (presses < n + 10) : (presses += 1) _ = handle(&m, .down);
    try std.testing.expectEqual(n - 1, m.slash_sel);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const menu = try @import("chrome.zig").slashMenu(&m, arena.allocator(), 80);
    try std.testing.expect(std.mem.indexOf(u8, menu, "› ") != null);
}

test "empty Up scrolls transcript and keeps prompt focus" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_height = 24;
    try std.testing.expect(m.focus == .prompt);
    _ = handle(&m, .up);
    try std.testing.expect(!m.follow);
    try std.testing.expect(m.scroll > 0);
    try std.testing.expect(m.focus == .prompt);
    _ = handle(&m, .down);
    try std.testing.expect(m.follow);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
}

test "bracketed paste lands in the prompt as text" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.focus = .scrollback;
    _ = handle(&m, .paste_start);
    _ = handle(&m, .{ .char = 'h' });
    _ = handle(&m, .{ .char = 'i' });
    _ = handle(&m, .enter);
    _ = handle(&m, .{ .char = '!' });
    _ = handle(&m, .paste_end);
    try std.testing.expectEqualStrings("hi\n!", m.input.getValue());
    try std.testing.expect(m.focus == .prompt);
    try std.testing.expect(!m.pasting);
}

test "pasted image path becomes an attachment chip" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = handle(&m, .paste_start);
    for ("/tmp/pic.png") |c| _ = handle(&m, .{ .char = c });
    _ = handle(&m, .paste_end);
    try std.testing.expectEqual(@as(usize, 1), m.images.items.len);
    try std.testing.expectEqualStrings("/tmp/pic.png", m.images.items[0]);
    try std.testing.expectEqualStrings("", m.input.getValue());
}

test "Ctrl+R walks prompt history" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.prompt_hist.append(try std.testing.allocator.dupe(u8, "older"));
    try m.prompt_hist.append(try std.testing.allocator.dupe(u8, "newer"));
    _ = handle(&m, .{ .ctrl = 'r' });
    try std.testing.expectEqualStrings("newer", m.input.getValue());
    _ = handle(&m, .up);
    try std.testing.expectEqualStrings("older", m.input.getValue());
}
