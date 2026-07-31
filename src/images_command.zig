//! The Agent-facing half of `/images` (#103): find the most recent turn, scan it
//! with the pure extractor in images.zig, and open what it finds in a browser.
//! Kept out of images.zig on purpose - that module's header states it stays pure
//! (no Agent/IO) so the load-bearing URL logic is unit-testable without a
//! browser. Kept out of commands_model.zig because that file is at the 600-line
//! cap.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const images = @import("images.zig");
const oauth_helpers = @import("oauth_helpers.zig");

/// Serialized JSON of the most recent turn (from the user's last typed prompt to
/// the end) — what /images scans for image URLs. Provider-agnostic: URLs in
/// assistant text and tool outputs survive JSON serialization intact.
fn recentTurnText(root: *Agent, arena: Allocator) []const u8 {
    const msgs = root.messages.items;
    var start: usize = 0;
    var k = msgs.len;
    while (k > 0) : (k -= 1) {
        // Stop at the genuinely most-recent user turn — plain text OR an image
        // attachment (array content) — but not an anthropic tool_result-only user
        // message; cleanUserTurn is exactly that discriminator.
        if (Agent.cleanUserTurn(msgs[k - 1])) {
            start = k - 1;
            break;
        }
    }
    var aw: Io.Writer.Allocating = .init(arena);
    for (msgs[start..]) |m| {
        // A fresh Stringify per message: one instance can only serialize a single
        // top-level value. Newline-delimited is fine — we only scan for URLs.
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.write(m) catch {};
        aw.writer.writeByte('\n') catch {};
    }
    return aw.writer.buffered();
}

/// `/images` — returns true (handled) always; the caller dispatches on the line.
pub fn run(root: *Agent, out: *Io.Writer) !bool {
    // Transient: serialize + scan the last turn in a scratch arena freed on
    // return, so /images never accumulates in the long-lived session arena (#124).
    var scratch = std.heap.ArenaAllocator.init(root.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const urls = images.extractImageUrls(sa, recentTurnText(root, sa)) catch &[_][]const u8{};
    if (urls.len == 0) {
        try out.writeAll("no image URLs in the last response — /images opens images from the most recent turn's output (e.g. a `gh issue view` with attachments)\n");
        try out.flush();
        return true;
    }
    // GRAFF_NO_BROWSER (headless/SSH) suppresses the spawn; the command then
    // just lists the URLs, which also lets a test assert them without opening
    // real browser tabs.
    const suppress = main_mod.g_no_browser;
    // Cap the spawn so a reply full of image URLs can't flood the browser with
    // tabs; the full list is always printed so the rest are one copy away.
    const max_open = 8;
    if (!suppress) {
        const n = @min(urls.len, max_open);
        for (urls[0..n]) |u| oauth_helpers.openBrowser(root.io, u);
    }
    if (urls.len == 1) {
        try out.print("{s} {s}\n", .{ if (suppress) "image:" else "opening", urls[0] });
    } else {
        try out.print("{s} {d} images:\n", .{ if (suppress) "found" else "opening", urls.len });
        for (urls, 1..) |u, n| try out.print("  {d}. {s}\n", .{ n, u });
        if (!suppress and urls.len > max_open)
            try out.print("(opened the first {d}; open the rest from the list above)\n", .{max_open});
    }
    try out.flush();
    return true;
}
