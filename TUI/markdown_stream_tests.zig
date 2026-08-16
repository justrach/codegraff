//! Streaming-markdown conformance: the pager renders assistant prose from the
//! ACCUMULATED text every frame, so a chunked arrival sequence must land on
//! exactly the bytes a one-shot render produces, and every intermediate frame
//! has to be a legal frame on its own.
//!
//! Two properties are pinned here:
//!   IDEMPOTENCE  — feeding a document in N-byte chunks and rendering after
//!                  each chunk ends byte-identical to rendering it once.
//!   PREFIX SAFETY — every intermediate frame is valid UTF-8, carries no C0
//!                  control the model smuggled in, never holds a truncated
//!                  escape sequence, and closes every SGR weight it opened.

const std = @import("std");

const markdown = @import("markdown.zig");
const theme_mod = @import("theme.zig");

/// Documents that exercise every state the renderer threads across lines:
/// fences (closed, open, CRLF, block-comment), tables, nested lists, inline
/// markers (matched and dangling), emoji and CJK.
const fixtures = [_][]const u8{
    // 0 — a closed fence with strings, escapes, numbers and a comment.
    "# Title\nintro text\n```zig\nconst x: u32 = 0x1f; // note\nconst s = \"a\\nb\";\n```\ntail line\n",
    // 1 — a fence that never closes: the stream ended mid-block.
    "before\n```py\ndef f(x):\n    return x + 1\n",
    // 2 — CRLF everywhere, fence included.
    "para one\r\n```js\r\nlet a = 1; /* open\r\nstill comment */ let b = 2;\r\n```\r\nafter\r\n",
    // 3 — a pipe table plus a dangling partial row.
    "| Path | What |\n| --- | --- |\n| src/ | the product |\n| `TUI/` | pager |\n",
    // 4 — nested lists, emoji, CJK.
    "- top level 🚀\n  - nested 日本語 item\n  - another ✓ one\n- back out 中文字\n",
    // 5 — inline markers: matched, dangling, and adjacent.
    "a `code` b **bold** c `open d **half e ``\nsecond **line** with `tick`\n",
    // 6 — emoji and CJK INSIDE a fence, where the lexer walks bytes.
    "```go\nfmt.Println(\"日本語 🚀 done\")\n```\n",
    // 7 — prose carrying raw terminal control the model must never be able to
    // paint with, plus a bare CR mid-line.
    "safe \x1b[31mred?\x1b[0m and \x07bell\rreturn\nnext line\n",
    // 8 — a fence whose info string is a grok citation path.
    "```12:34:src/main.rs\nlet v: Vec<u8> = vec![1, 2, 3];\n```\n",
    // 9 — headings, rules and a fence opened immediately after a table.
    "## Heading\n| a | b |\n|---|---|\n| 1 | 2 |\n```sh\necho \"hi \\\n```\n",
};

fn oneShot(a: std.mem.Allocator, src: []const u8, th: theme_mod.Theme, width: usize) ![]const u8 {
    return markdown.renderThemed(a, src, th, width);
}

/// Walk the frame the way a terminal would and reject anything a live pager
/// could not survive.
fn checkFrame(frame: []const u8) !void {
    try std.testing.expect(std.unicode.utf8ValidateSlice(frame));
    var i: usize = 0;
    var open_bold = false;
    while (i < frame.len) {
        const b = frame[i];
        if (b == 0x1b) {
            const end = theme_mod.skipEsc(frame, i);
            // A truncated escape reaches the terminal as garbage and swallows
            // the glyphs behind it: the last byte must be a real final byte.
            try std.testing.expect(end > i + 1);
            const fin = frame[end - 1];
            try std.testing.expect(fin >= 0x40 and fin <= 0x7e);
            const seq = frame[i..end];
            if (std.mem.eql(u8, seq, theme_mod.bold)) open_bold = true;
            if (std.mem.eql(u8, seq, "\x1b[22m") or std.mem.eql(u8, seq, theme_mod.reset)) open_bold = false;
            i = end;
            continue;
        }
        if (b == '\n') {
            // Weight must not bleed across a row: run.zig pads from whatever
            // state the row left behind.
            try std.testing.expect(!open_bold);
            i += 1;
            continue;
        }
        // \t is legal prose; every other C0 (CR, BEL, NUL…) moves or rings the
        // terminal and must have been filtered out of the model's text.
        try std.testing.expect(b >= 0x20 or b == '\t');
        try std.testing.expect(b != 0x7f);
        i += 1;
    }
    try std.testing.expect(!open_bold);
}

/// Accumulate `src` in `chunk`-byte deltas, rendering after each one, and
/// return the final frame. Every intermediate frame is checked.
fn streamRender(
    a: std.mem.Allocator,
    src: []const u8,
    th: theme_mod.Theme,
    width: usize,
    chunk: usize,
) ![]const u8 {
    var acc = std.array_list.Managed(u8).init(a);
    defer acc.deinit();
    var last: []const u8 = "";
    var i: usize = 0;
    while (i < src.len) {
        const n = @min(chunk, src.len - i);
        try acc.appendSlice(src[i .. i + n]);
        i += n;
        last = try markdown.renderThemed(a, acc.items, th, width);
        try checkFrame(last);
    }
    return last;
}

test "idempotence: chunked arrival lands on the one-shot render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]theme_mod.Id{ .night, .day }) |id| {
        const th = theme_mod.of(id);
        for (fixtures) |src| {
            const want = try oneShot(a, src, th, 60);
            try checkFrame(want);
            var chunk: usize = 1;
            while (chunk <= 7) : (chunk += 1) {
                const got = try streamRender(a, src, th, 60, chunk);
                try std.testing.expectEqualStrings(want, got);
            }
        }
    }
}

test "prefix safety: a split at EVERY byte boundary renders a legal frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    for (fixtures) |src| {
        const want = try oneShot(a, src, th, 48);
        var k: usize = 0;
        while (k <= src.len) : (k += 1) {
            // The rolling window: the model stopped exactly here.
            const head = try markdown.renderThemed(a, src[0..k], th, 48);
            try checkFrame(head);
            // …and then the rest arrives in one go.
            const settled = try markdown.renderThemed(a, src, th, 48);
            try std.testing.expectEqualStrings(want, settled);
        }
        _ = arena.reset(.retain_capacity);
    }
}

test "a glyph split across chunks never leaves replacement garbage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    const src = "emoji 🚀 and 日本語 text";
    var k: usize = 0;
    while (k <= src.len) : (k += 1) {
        const head = try markdown.renderThemed(a, src[0..k], th, 40);
        // Valid UTF-8 at every boundary: a half-written glyph is HELD BACK
        // until its tail arrives rather than painted as U+FFFD.
        try std.testing.expect(std.unicode.utf8ValidateSlice(head));
    }
    const full = try markdown.renderThemed(a, src, th, 40);
    try std.testing.expect(std.mem.indexOf(u8, full, "🚀") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "日本語") != null);
}

test "CRLF: a carriage return never reaches the frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    const out = try markdown.renderThemed(a, "alpha\r\nbeta\r\n```zig\r\nconst x = 1;\r\n```\r\n", th, 40);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\r') == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const") != null);
    // A CR line ending must not survive as a visible column either.
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| try std.testing.expect(theme_mod.visibleLen(ln) <= 40);
}

test "model text cannot smuggle its own SGR or cursor control into the frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    const out = try markdown.renderThemed(a, "hi \x1b[2Jwiped \x1b[38;2;255;0;0mred\x1b[0m done", th, 40);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;255;0;0m") == null);
    // The literal parameter bytes must not be left behind as text either.
    try std.testing.expect(std.mem.indexOf(u8, out, "[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "wiped") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "done") != null);
    // A truncated escape at the very end of a delta is dropped whole — no
    // half-sequence on the wire, no leftover parameter bytes as text.
    const cut = try markdown.renderThemed(a, "tail \x1b[9987", th, 40);
    try std.testing.expect(std.mem.indexOf(u8, cut, "9987") == null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "tail") != null);
    try checkFrame(cut);
}

test "an unterminated fence renders as tentative code and settles when it closes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    const syntax = @import("syntax.zig");
    const bg = syntax.codeBg(false);
    const open = try markdown.renderThemed(a, "```zig\nconst x = 1;", th, 40);
    try std.testing.expect(std.mem.indexOf(u8, open, bg) != null); // already code
    const closed = try markdown.renderThemed(a, "```zig\nconst x = 1;\n```\nafter", th, 40);
    // The code row is byte-identical before and after the fence closes: the
    // block settles, it does not re-render differently.
    const open_row = std.mem.sliceTo(open[std.mem.indexOf(u8, open, bg).?..], '\n');
    const closed_row = std.mem.sliceTo(closed[std.mem.indexOf(u8, closed, bg).?..], '\n');
    try std.testing.expectEqualStrings(open_row, closed_row);
}

test "highlighting state is per BLOCK, not per chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    const syntax = @import("syntax.zig");
    const comment = syntax.color(.comment, false);
    // The block comment opens on one line and closes on the next; the lexer
    // must carry that across the line break no matter how the bytes arrived.
    const src = "```js\nlet a = 1; /* open\nstill inside\n*/ let b = 2;\n```\n";
    const want = try markdown.renderThemed(a, src, th, 60);
    try std.testing.expect(std.mem.indexOf(u8, want, comment) != null);
    var chunk: usize = 1;
    while (chunk <= 5) : (chunk += 1) {
        const got = try streamRender(a, src, th, 60, chunk);
        try std.testing.expectEqualStrings(want, got);
    }
    // A SECOND fence restarts the lexer: an open block comment in the first
    // one must not colour the second one's first line.
    const two = try markdown.renderThemed(a, "```js\n/* open\n```\n```js\nlet c = 3;\n```\n", th, 60);
    var rows = std.mem.splitScalar(u8, two, '\n');
    var body: []const u8 = "";
    while (rows.next()) |ln| {
        // The last banded row is the second fence's only code line; its tokens
        // are SGR-separated, so match on the band, not on the text.
        if (std.mem.indexOf(u8, ln, syntax.codeBg(false)) != null) body = ln;
    }
    try std.testing.expect(body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body, comment) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, syntax.color(.keyword, false)) != null);
}

test "inline emphasis split across chunks stays literal, then settles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    // Half a marker pair is TEXT: it must not open a weight that then runs on
    // into the rest of the message.
    for ([_][]const u8{ "a **bol", "a **bold*", "a `open", "a *" }) |half| {
        const frame = try markdown.renderThemed(a, half, th, 40);
        try std.testing.expect(std.mem.indexOf(u8, frame, theme_mod.bold) == null);
        try checkFrame(frame);
    }
    // The closing marker arrives and the span settles into a closed weight.
    const done = try markdown.renderThemed(a, "a **bold** b", th, 40);
    try std.testing.expect(std.mem.indexOf(u8, done, theme_mod.bold) != null);
    try std.testing.expect(std.mem.indexOf(u8, done, "\x1b[22m") != null);
    try checkFrame(done);
    // …and the marker itself is gone, not left on screen.
    try std.testing.expect(std.mem.indexOf(u8, done, "**") == null);
}

test "end to end: hostile assistant prose cannot corrupt a transcript row" {
    const app = @import("app.zig");
    const scrollback = @import("scrollback.zig");
    var m: app.Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.assistant, "row one\rWIPED \x1b[2J\x1b[38;2;255;0;0mred\r\n```zig\r\nconst x = 1; // 日本語 🚀\r\n```\r\ndone");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try scrollback.render(&m, arena.allocator(), 40, 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, frame, '\r') == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[38;2;255;0;0m") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(frame));
    try std.testing.expect(std.mem.indexOf(u8, frame, "日本語") != null);
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |ln| try std.testing.expect(theme_mod.visibleLen(ln) <= 40);
}

test "renderUser is chunk-safe too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "look at \x1b[31m@[/tmp/a.png]\r /goal 日本語 🚀";
    var k: usize = 0;
    while (k <= src.len) : (k += 1) {
        const head = try markdown.renderUser(a, src[0..k], theme_mod.emerald, theme_mod.zinc200);
        try std.testing.expect(std.unicode.utf8ValidateSlice(head));
        try std.testing.expect(std.mem.indexOfScalar(u8, head, '\r') == null);
        try std.testing.expect(std.mem.indexOf(u8, head, "[31m") == null);
    }
}
