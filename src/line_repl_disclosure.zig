//! Explicit raw-result disclosure for the default line REPL (#601).
//!
//! Semantic tool rows remain the transcript. Results whose raw bytes contain
//! more than the interpreted row are retained in a small process-local ring;
//! an empty Enter reveals the newest unseen one. Nothing is printed live.

const std = @import("std");
const Io = std.Io;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const max_entries = 16;

const Entry = struct {
    name: []u8,
    detail: []u8,
    raw: []u8,
    shown: bool = false,
};

var mutex: Io.Mutex = .init;
var entries: [max_entries]?Entry = @splat(null);
var count: usize = 0;

fn freeEntry(entry: Entry) void {
    const alloc = std.heap.page_allocator;
    alloc.free(entry.name);
    alloc.free(entry.detail);
    alloc.free(entry.raw);
}

fn clearLocked() void {
    for (entries[0..count]) |entry| freeEntry(entry.?);
    entries = @splat(null);
    count = 0;
}

/// Test/session reset. The live ring is otherwise bounded and old entries are
/// freed as new tool results replace them.
pub fn reset(io: Io) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    clearLocked();
}

/// Retain a result only when its interpreted row hid something. Returns true
/// when the caller should draw the `↵ raw` disclosure affordance.
pub fn record(io: Io, name: []const u8, detail: []const u8, raw: []const u8, interpreted: []const u8) bool {
    if (raw.len == 0 or std.mem.eql(u8, raw, interpreted)) return false;
    const alloc = std.heap.page_allocator;
    const owned_name = alloc.dupe(u8, name) catch return false;
    const owned_detail = alloc.dupe(u8, detail) catch {
        alloc.free(owned_name);
        return false;
    };
    const owned_raw = alloc.dupe(u8, raw) catch {
        alloc.free(owned_name);
        alloc.free(owned_detail);
        return false;
    };

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (count == max_entries) {
        freeEntry(entries[0].?);
        for (1..max_entries) |i| entries[i - 1] = entries[i];
        entries[max_entries - 1] = null;
        count -= 1;
    }
    entries[count] = .{ .name = owned_name, .detail = owned_detail, .raw = owned_raw };
    count += 1;
    return true;
}

fn skipEscape(text: []const u8, start: usize) usize {
    if (start + 1 >= text.len) return text.len;
    if (text[start + 1] == '[') {
        var i = start + 2;
        while (i < text.len) : (i += 1) {
            if (text[i] >= 0x40 and text[i] <= 0x7e) return i + 1;
        }
        return text.len;
    }
    if (text[start + 1] == ']') {
        var i = start + 2;
        while (i < text.len) : (i += 1) {
            if (text[i] == 0x07) return i + 1;
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
        }
        return text.len;
    }
    return @min(start + 2, text.len);
}

/// Raw means uninterpreted, not unsafe: terminal controls and invalid UTF-8
/// never get a chance to repaint the user's terminal.
fn sanitized(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte == 0x1b) {
            i = skipEscape(text, i);
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            if (byte == '\n' or byte == '\t') try out.append(byte);
            i += 1;
            continue;
        }
        if (byte < 0x80) {
            try out.append(byte);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        _ = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        try out.appendSlice(text[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice();
}

fn render(out: *Io.Writer, entry: Entry) !void {
    const alloc = std.heap.page_allocator;
    const name = try sanitized(alloc, entry.name);
    defer alloc.free(name);
    const detail = try sanitized(alloc, entry.detail);
    defer alloc.free(detail);
    const raw = try sanitized(alloc, entry.raw);
    defer alloc.free(raw);

    try out.print("  {s}┌ raw {s}", .{ style.dim, name });
    if (detail.len > 0) try out.print(" · {s}", .{detail});
    try out.print("{s}\n", .{style.reset});
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| try out.print("  {s}│{s} {s}\n", .{ style.dim, style.reset, line });
    try out.print("  {s}└{s}\n", .{ style.dim, style.reset });
    try out.flush();
}

/// Empty Enter is consumed by disclosure. A non-empty line continues through
/// the ordinary command/model path unchanged.
pub fn handleInput(io: Io, out: *Io.Writer, line: []const u8) bool {
    if (line.len != 0) return false;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var i = count;
    while (i > 0) {
        i -= 1;
        const entry = &entries[i].?;
        if (entry.shown) continue;
        render(out, entry.*) catch return true;
        entry.shown = true;
        break;
    }
    return true;
}
