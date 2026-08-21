//! Tests for markdown.zig — the renderer's own file sits at the 600-line
//! ceiling, so its test block lives here. Reached from markdown.zig's test
//! block, which is reached from root.zig: a module nobody references never
//! runs its tests at all.

const std = @import("std");

const diff = @import("diff.zig");
const syntax = @import("syntax.zig");
const theme_mod = @import("theme.zig");

const markdown = @import("markdown.zig");
const render = markdown.render;
const renderThemed = markdown.renderThemed;
const renderTinted = markdown.renderTinted;
const renderUser = markdown.renderUser;

test "render paints headers, code, bold, and bullets" {
    const text = try render(std.testing.allocator, "# Title\n- item\n`code` and **bold**\n```zig\nconst x = 1;\n```", theme_mod.emerald);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "•") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "code") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "▏ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, theme_mod.emerald) != null);
}

test "the code band stays open to the row end and is released on the next line" {
    const th = theme_mod.of(.night);
    const code_bg = syntax.codeBg(false);
    const out = try renderThemed(std.testing.allocator, "intro\n```\nabc\ndef\n```\nafter", th, 40);
    defer std.testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    var rows: usize = 0;
    var was_band = false;
    var band_rows: usize = 0;
    while (it.next()) |ln| : (rows += 1) {
        const band = std.mem.indexOf(u8, ln, code_bg) != null;
        if (band) {
            // run.zig pads a row from whatever background the line left active,
            // so a band row must NOT hand the canvas back before it ends.
            try std.testing.expect(std.mem.indexOf(u8, ln, th.bg) == null);
            band_rows += 1;
        } else if (was_band) {
            // The first row off the band reclaims the theme canvas up front.
            try std.testing.expect(std.mem.startsWith(u8, ln, th.bg));
        }
        was_band = band;
    }
    try std.testing.expectEqual(@as(usize, 2), band_rows); // abc, def
    // intro, opening separator, abc, def, closing separator, after
    try std.testing.expectEqual(@as(usize, 6), rows);
}

test "a wrapped fence line carries its band onto every continuation row" {
    const th = theme_mod.of(.night);
    const bg = syntax.codeBg(false);
    const src =
        \\```zig
        \\const message = try std.fmt.allocPrint(gpa, "hello {s} world", .{name});
        \\```
    ;
    const body = try renderThemed(std.testing.allocator, src, th, 36);
    defer std.testing.allocator.free(body);
    const wrapped = try theme_mod.wrapToWidth(std.testing.allocator, body, 36);
    defer std.testing.allocator.free(wrapped);
    var it = std.mem.splitScalar(u8, wrapped, '\n');
    var code_rows: usize = 0;
    while (it.next()) |ln| {
        if (theme_mod.visibleLen(ln) == 0) continue; // fence separators
        code_rows += 1;
        // A syntax-coloured line spends an SGR per token; the old byte-capped
        // tracker had dropped the background long before the wrap point.
        try std.testing.expect(std.mem.indexOf(u8, ln, bg) != null);
    }
    try std.testing.expect(code_rows > 1); // it really did wrap
}

test "no code background leaks past a closed fence or off the last fence row" {
    const th = theme_mod.of(.night);
    const code_bg = syntax.codeBg(false);
    const closed = try renderThemed(std.testing.allocator, "```\nx\n```\ntail", th, 40);
    defer std.testing.allocator.free(closed);
    // The band ends with the fence, the next row takes the canvas back, and no
    // later row re-opens codeBg.
    var it = std.mem.splitScalar(u8, closed, '\n');
    var seen_band = false;
    var restored = false;
    while (it.next()) |ln| {
        const band = std.mem.indexOf(u8, ln, code_bg) != null;
        if (band) {
            try std.testing.expect(!restored); // never re-opened
            seen_band = true;
            continue;
        }
        if (seen_band and !restored) {
            try std.testing.expect(std.mem.startsWith(u8, ln, th.bg));
            restored = true;
        }
    }
    try std.testing.expect(seen_band and restored);
    // A message that ends mid-fence keeps its band (that row IS code) and adds
    // no stray row after it for the theme bg to land on.
    const open = try renderThemed(std.testing.allocator, "```\nx", th, 40);
    defer std.testing.allocator.free(open);
    try std.testing.expect(std.mem.indexOf(u8, open, th.bg) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, open, "\n"));
}

test "renderUser chips @[path] and paints slash commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.png", .data = "png" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_n = try tmp.dir.realPath(io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const live = try std.fmt.bufPrint(&path_buf, "{s}/a.png", .{dir_buf[0..dir_n]});
    const src = try std.fmt.allocPrint(std.testing.allocator, "@[{s}] /goal look at this", .{live});
    defer std.testing.allocator.free(src);
    const text = try renderUser(std.testing.allocator, src, theme_mod.emerald, theme_mod.zinc200);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Image #1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, live) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, theme_mod.emerald ++ "[Image #1]") != null);
}

test "renderUser leaves an unbacked @[path] uncolored (#577)" {
    const text = try renderUser(std.testing.allocator, "@[/no/such/image-577.png] look", theme_mod.emerald, theme_mod.zinc200);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Image #1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, theme_mod.emerald ++ "[Image #1]") == null);
}

test "render paints a Grok-style box table and hides raw pipes" {
    const src = "| Path | What |\n| --- | --- |\n| src/ | the product |\n| `TUI/` | pager |\n";
    const text = try render(std.testing.allocator, src, theme_mod.emerald);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pager") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| --- |") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| Path |") == null);
}

test "a wide table fits the terminal: grid intact, one visual line per row (#tables)" {
    const th = theme_mod.of(.night);
    const md = "| Transport | Grok (this wire) | Codex / Claude |\n|---|---|---|\n| Item delta (previous_response_id) with a very long explanation cell that used to blow the grid | no (stalls) everywhere on narrow terminals | yes, if props match and the moon is right |";
    const out = try renderThemed(std.testing.allocator, md, th, 60);
    defer std.testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    var rows: usize = 0;
    while (it.next()) |ln| : (rows += 1) {
        try std.testing.expect(theme_mod.visibleLen(ln) <= 60);
    }
    try std.testing.expectEqual(@as(usize, 5), rows); // top rule, header, mid rule, body, bottom rule
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2026}") != null); // over-long cells clip with an ellipsis
}

test "a diff fence bands its edits instead of taking the code canvas" {
    const th = theme_mod.of(.night);
    const src = "before\n```diff\n@@ -1,2 +1,2 @@\n const keep = 0;\n-const old = 1;\n+const new = 2;\n```\nafter";
    const out = try renderThemed(std.testing.allocator, src, th, 40);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, diff.addBg(false)) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, diff.delBg(false)) != null);
    // A patch is not code: it never picks up the fence's own background.
    try std.testing.expect(std.mem.indexOf(u8, out, syntax.codeBg(false)) == null);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| {
        try std.testing.expect(theme_mod.visibleLen(ln) <= 40);
        if (std.mem.indexOf(u8, ln, "after") == null) continue;
        // The prose under the fence inherits neither band.
        try std.testing.expect(std.mem.indexOf(u8, ln, diff.addBg(false)) == null);
        try std.testing.expect(std.mem.indexOf(u8, ln, diff.delBg(false)) == null);
    }
}

test "an undeclared fence that IS a patch bands; a bullet list never does" {
    const th = theme_mod.of(.night);
    const patch = try renderThemed(std.testing.allocator, "```\n--- a/x\n+++ b/x\n-gone\n+here\n```", th, 40);
    defer std.testing.allocator.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, diff.addBg(false)) != null);
    // Lines that merely START with `-` are a list, not a diff (#diff).
    const list = try renderThemed(std.testing.allocator, "- one\n- two\n- three", th, 40);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, diff.delBg(false)) == null);
    // …and a zig fence still gets syntax colors on the code canvas.
    const code = try renderThemed(std.testing.allocator, "```zig\nconst x = 1;\n```", th, 40);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, syntax.codeBg(false)) != null);
    try std.testing.expect(std.mem.indexOf(u8, code, diff.addBg(false)) == null);
}
