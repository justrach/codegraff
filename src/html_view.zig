//! `render_html` — the model draws something for the user, and the desktop
//! app renders it inline in the transcript instead of making them imagine it.
//!
//! The snapshot is the model's page VERBATIM: no wrapper document, no host
//! script, no handshake. Isolation is a response header, not a shell — the
//! desktop's `/api/views` serves this file with a CSP `sandbox` plus
//! `default-src 'none'`, so the page runs in an opaque origin with no network
//! and no reach into the app, whether it is framed by the transcript or opened
//! straight from disk in a browser.
//!
//! Same private-snapshot shape as an MCP app result (mcp_apps.zig): a random
//! 32-hex id under `$HOME/.graff/views`, 0700 directory, 0600 file, and a
//! result line carrying only the path. Nothing about the page enters model
//! context a second time.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const tools = @import("tools.zig");

pub const tool_name = "render_html";
pub const tool_desc =
    "Draw something for the user as a live HTML page and show it in the desktop transcript. Reach for it when a result is easier to SEE than to read — a chart, a diagram, a timeline, a before/after comparison, a small layout mock, or something they can poke at — not for ordinary prose, code, or a file list, which belong in your reply. The page is saved as one private local snapshot and rendered in an isolated frame: no network at all (inline images as data: URIs; no CDNs, no fonts, no fetch), no access to the app or its APIs, no forms, no popups, and links stay inside the frame. Make it self-contained — one document with its own inline <style>/<script> — and keep it under 1 MB. One call makes one view; the user can close it and the saved path stays openable later.";
pub const tool_schema =
    \\{"type": "object", "properties": {"html": {"type": "string", "description": "The complete page: markup plus whatever inline <style>/<script> it needs. It must stand alone — nothing is fetched and nothing outside it is available."}}, "required": ["html"]}
;

/// Catalog entry for this tool. schema.zig sits on the 600-line ceiling, so
/// the spec lives with the module that owns it and is spliced in there as
/// `@import("html_view.zig").spec` — the same one-line pattern `skill_docs`
/// and `imagegen` use, minus the import.
pub const spec: @import("schema.zig").ToolSpec = .{ .name = tool_name, .desc = tool_desc, .schema = tool_schema };

/// One call, one page. A view is for a pane, not a 40 MB canvas.
const max_html = 1024 * 1024;
pub const dir_name = ".graff/views";

/// The home the session resolved: the MCP registry already carries it, the
/// fleet pins it before any prompt, and credential_store pins it at startup.
/// A tool running on a pool thread has no environment map of its own.
fn homeDir(ctx: tools.ToolCtx) []const u8 {
    if (ctx.registry) |reg| if (reg.home.len > 0) return reg.home;
    if (@import("fleet.zig").g_home) |h| if (h.len > 0) return h;
    return @import("credential_store.zig").g_home;
}

/// Why this page cannot be rendered, or null when it can. Separate from exec
/// so the wording is testable without a whole ToolCtx.
fn refusal(html: []const u8, a: Allocator) !?[]u8 {
    if (std.mem.trim(u8, html, " \t\r\n").len == 0)
        return try a.dupe(u8, "render_html needs the page in `html` — an empty string draws nothing.");
    if (html.len > max_html)
        return try std.fmt.allocPrint(a, "that page is {d} KB and the limit is {d} KB per view. Inline less (base64 media is what usually blows the budget) or draw it as two views.", .{ html.len / 1024, max_html / 1024 });
    return null;
}

/// The one line the transcript and the model see. The page itself never
/// travels in it — the GUI matches the opaque path.
fn marker(a: Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "[Rendered view]({s}) — this page is now shown in the desktop transcript; it renders with no network and no access to the app.", .{path});
}

/// Write the page to one private snapshot and return its path (caller-owned).
pub fn write(io: Io, a: Allocator, home: []const u8, html: []const u8) ![]const u8 {
    if (home.len == 0) return error.NoHomeDirectory;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const dir = try std.fmt.allocPrint(scratch.allocator(), "{s}/{s}", .{ home, dir_name });
    try Io.Dir.cwd().createDirPath(io, dir);
    // Windows inherits the user profile ACL; Zig does not implement POSIX chmod there.
    if (@import("builtin").os.tag != .windows)
        try Io.Dir.cwd().setFilePermissions(io, dir, @enumFromInt(0o700), .{});
    var random: [16]u8 = undefined;
    io.random(&random);
    const path = try std.fmt.allocPrint(scratch.allocator(), "{s}/{s}.html", .{ dir, std.fmt.bytesToHex(random, .lower) });
    try @import("credential_store.zig").replaceFile(io, Io.Dir.cwd(), path, html, @enumFromInt(0o600));
    return try a.dupe(u8, path);
}

pub fn exec(ctx: tools.ToolCtx, input: Value) !tools.ToolOutput {
    const html = tools.strField(input, "html") orelse "";
    if (try refusal(html, ctx.gpa)) |text| return .{ .text = text, .is_error = true };
    const path = write(ctx.io, ctx.gpa, homeDir(ctx), html) catch |err| return .{
        .text = try std.fmt.allocPrint(ctx.gpa, "could not save the view: {s}", .{@errorName(err)}),
        .is_error = true,
    };
    return .{ .text = try marker(ctx.gpa, path) };
}

const testing = std.testing;

fn tmpHome(a: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "render_html writes the page verbatim to one private snapshot" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(a, &tmp);
    defer a.free(home);
    const html = "<!doctype html><h1>Flow</h1><style>h1{color:#059669}</style>";
    const path = try write(testing.io, a, home, html);
    defer a.free(path);
    // Opaque id, fixed shape — this is what the GUI's link matcher accepts.
    const suffix = try std.fmt.allocPrint(a, "{s}/{s}", .{ home, dir_name });
    defer a.free(suffix);
    try testing.expect(std.mem.startsWith(u8, path, suffix));
    const id = path[suffix.len + 1 ..];
    try testing.expectEqual(@as(usize, 32 + 5), id.len);
    try testing.expect(std.mem.endsWith(u8, id, ".html"));
    for (id[0..32]) |c| try testing.expect(std.ascii.isHex(c));
    // The file is the model's bytes, unchanged (no wrapper injected).
    const saved = try Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(4096));
    defer a.free(saved);
    try testing.expectEqualStrings(html, saved);
    if (@import("builtin").os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(testing.io, path, .{});
        try testing.expectEqual(@as(u32, 0o600), st.permissions.toMode() & 0o777);
    }
}

test "two calls never collide on one id" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(a, &tmp);
    defer a.free(home);
    const first = try write(testing.io, a, home, "<p>one</p>");
    defer a.free(first);
    const second = try write(testing.io, a, home, "<p>two</p>");
    defer a.free(second);
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "an empty page, an oversized page and a home-less session are refused" {
    const a = testing.allocator;
    const empty = (try refusal("   \n", a)).?;
    defer a.free(empty);
    try testing.expect(std.mem.indexOf(u8, empty, "empty string") != null);
    const big = try a.alloc(u8, max_html + 1);
    defer a.free(big);
    @memset(big, 'x');
    const oversized = (try refusal(big, a)).?;
    defer a.free(oversized);
    try testing.expect(std.mem.indexOf(u8, oversized, "limit") != null);
    try testing.expect((try refusal("<p>fine</p>", a)) == null);
    try testing.expectError(error.NoHomeDirectory, write(testing.io, a, "", "<p>x</p>"));
}

test "the marker carries the path and never the page" {
    const a = testing.allocator;
    const text = try marker(a, "/home/u/.graff/views/0123456789abcdef0123456789abcdef.html");
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "/.graff/views/0123456789abcdef0123456789abcdef.html") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<") == null);
}
