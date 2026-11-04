//! `graff computer` and `/computer` (ADR 0314): nanocua's switches from graff,
//! by running the app's own `nanocua ctl`. Status, stop and turning things off
//! happen at once. `allow` only asks: the question appears in nanocua's window
//! and only a person's click there answers it, because agents have shells and
//! could run this command as easily as anyone. macOS's permissions stay the
//! user's to flip in System Settings: `grant` opens the prompt.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const nanocua_default = @import("nanocua_default.zig");
const process_runner = @import("process_runner.zig");

pub const usage =
    \\usage: graff computer [status] [--json]
    \\  status                     what's on, and what macOS has granted
    \\  stop                       refuse every agent's calls, at once
    \\  off <input|whole_screen>   turn a switch off, at once
    \\  allow <input|whole_screen|resume>   ask; you answer in nanocua's window
    \\  grant <accessibility|screen>   open macOS's prompt for a permission
    \\  open                       bring nanocua's window forward
    \\
;

/// `allow` waits for the click: a question lasts a minute, and starting the
/// app may come first.
const deadline_ms: u64 = 90_000;
const output_cap: usize = 64 * 1024;

const not_installed_text = "nanocua isn't installed. It ships with graff's signed macOS releases: run `graff update`.\n";
const not_macos_text = "Computer use is macOS-only for now.\n";

pub const Parsed = struct {
    /// What goes after `nanocua ctl`.
    words: []const []const u8,
    json: bool = false,
    from: []const u8 = "graff",
};

/// Null asks for the usage. Words are checked here, so nothing but the commands
/// above ever reaches the app, and a mistake answers here without starting it.
pub fn parse(arena: Allocator, args: []const []const u8) !?Parsed {
    var out: Parsed = .{ .words = &.{} };
    var words: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
        } else if (std.mem.startsWith(u8, arg, "--from=")) {
            out.from = arg["--from=".len..];
        } else try words.append(arena, arg);
    }
    if (words.items.len == 0) try words.append(arena, "status");
    if (!known(words.items)) return null;
    out.words = words.items;
    return out;
}

fn oneOf(word: []const u8, comptime options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, word, o)) return true;
    return false;
}

fn known(words: []const []const u8) bool {
    if (words.len == 1) return oneOf(words[0], &.{ "status", "stop", "open" });
    if (words.len != 2) return false;
    if (std.mem.eql(u8, words[0], "off")) return oneOf(words[1], &.{ "input", "whole_screen" });
    if (std.mem.eql(u8, words[0], "allow")) return oneOf(words[1], &.{ "input", "whole_screen", "resume" });
    if (std.mem.eql(u8, words[0], "grant")) return oneOf(words[1], &.{ "accessibility", "screen" });
    return false;
}

pub fn argv(arena: Allocator, program: []const u8, p: Parsed) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, &.{ program, "ctl" });
    try out.appendSlice(arena, p.words);
    if (p.json) try out.append(arena, "--json");
    try out.append(arena, try std.fmt.allocPrint(arena, "--from={s}", .{p.from}));
    return out.items;
}

/// What's said when there's no app to ask.
fn absent(json: bool, supported: bool) []const u8 {
    if (json) return if (supported)
        "{\"installed\":false,\"running\":false}\n"
    else
        "{\"installed\":false,\"running\":false,\"outcome\":\"unsupported\"}\n";
    return if (supported) not_installed_text else not_macos_text;
}

/// True if the command ran; its output or the reason it didn't goes to `out`.
pub fn run(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, args: []const []const u8, out: *Io.Writer) !bool {
    const p = try parse(arena, args) orelse {
        try out.writeAll(usage);
        return false;
    };
    const supported = builtin.os.tag == .macos;
    const program = (if (supported) nanocua_default.find(io, arena, home) else null) orelse {
        try out.writeAll(absent(p.json, supported));
        return false;
    };
    if (!p.json and std.mem.eql(u8, p.words[0], "allow")) {
        try out.writeAll("Asking: answer in nanocua's window. The question lasts a minute.\n");
        try out.flush();
    }
    const r = process_runner.runCapped(gpa, io, try argv(arena, program, p), output_cap, output_cap, deadline_ms) catch |err| {
        try out.print("Couldn't run nanocua: {t}\n", .{err});
        return false;
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try out.writeAll(r.stdout);
    if (r.timed_out) try out.writeAll("nanocua didn't answer in time.\n");
    const exited_ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok and r.stderr.len > 0) try out.writeAll(r.stderr);
    return exited_ok and !r.timed_out;
}

/// `graff computer …`.
pub fn command(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, args: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    const ok = try run(io, gpa, arena, home, args, &w.interface);
    try w.interface.flush();
    if (!ok) std.process.exit(1);
}

/// `/computer …`, on the REPL and the TUI.
pub fn slash(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, line: []const u8, out: *Io.Writer) !void {
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, line["/computer".len..], " \t");
    while (it.next()) |word| try words.append(arena, word);
    _ = try run(io, gpa, arena, home, words.items, out);
    try out.flush();
}

const testing = std.testing;

test "only the commands nanocua knows get through" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqualStrings("status", (try parse(a, &.{})).?.words[0]);
    const allow = (try parse(a, &.{ "allow", "whole_screen", "--json", "--from=Harness" })).?;
    try testing.expect(allow.json);
    try testing.expectEqualStrings("Harness", allow.from);
    try testing.expectEqualStrings("whole_screen", allow.words[1]);
    for ([_][]const []const u8{
        &.{"nonsense"},
        &.{"allow"},
        &.{ "allow", "everything" },
        &.{ "off", "resume" },
        &.{ "grant", "camera" },
        &.{ "stop", "now" },
        &.{ "status", "extra", "words" },
    }) |bad| try testing.expect((try parse(a, bad)) == null);
}

test "what runs: the app's ctl, saying who asks" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const got = try argv(a, "/x/nanocua", (try parse(a, &.{ "grant", "screen", "--json" })).?);
    const want = [_][]const u8{ "/x/nanocua", "ctl", "grant", "screen", "--json", "--from=graff" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "no app: a person is told how, a program reads that it's missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const home = try a.dupe(u8, buf[0..n]);
    var aw: Io.Writer.Allocating = .init(a);
    try testing.expect(!try run(testing.io, testing.allocator, a, home, &.{}, &aw.writer));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "isn't") != null or std.mem.indexOf(u8, aw.written(), "macOS-only") != null);
    aw.clearRetainingCapacity();
    try testing.expect(!try run(testing.io, testing.allocator, a, home, &.{"--json"}, &aw.writer));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{});
    try testing.expect(!parsed.object.get("installed").?.bool);
    aw.clearRetainingCapacity();
    try testing.expect(!try run(testing.io, testing.allocator, a, home, &.{"nonsense"}, &aw.writer));
    try testing.expectEqualStrings(usage, aw.written());
}

test "/computer splits its words" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var aw: Io.Writer.Allocating = .init(a);
    try slash(testing.io, testing.allocator, a, try a.dupe(u8, buf[0..n]), "/computer  allow \t nonsense", &aw.writer);
    try testing.expectEqualStrings(usage, aw.written());
}
