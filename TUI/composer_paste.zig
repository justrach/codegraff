//! Origin-aware bracketed-paste finalization for the TUI composer (#792).
//!
//! The decoder owns paste framing. This module owns the exact inserted range:
//! text receives a removable trailing separator, pasted file paths become
//! semantic spans, and an image consumes only its own pasted bytes.

const std = @import("std");
const app = @import("app.zig");
const dispatch = @import("dispatch.zig");
const image = @import("image.zig");
const Model = app.Model;

pub fn begin(self: *Model) void {
    self.input.beginPaste();
}

pub fn finish(self: *Model) void {
    const range = self.input.pasteRange() orelse {
        self.input.endPaste();
        return;
    };
    defer self.input.endPaste();
    if (range.start == range.end) return;

    const raw = self.input.getValue()[range.start..range.end];
    const path = normalizePath(self.alloc, raw) orelse {
        self.input.ensurePasteSeparator();
        return;
    };
    defer self.alloc.free(path);

    if (dispatch.looksLikeImagePath(path) and image.attachDropped(self, path)) {
        _ = self.input.replacePaste(range, "", false);
        return;
    }
    if (!pathExists(path)) {
        self.input.ensurePasteSeparator();
        return;
    }
    if (self.input.replacePaste(range, path, true)) self.input.ensurePasteSeparator();
}

fn pathExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Normalize the one-path forms terminals emit for Finder paste/drop. Mixed
/// prose and multiline payloads remain ordinary pasted text.
fn normalizePath(alloc: std.mem.Allocator, raw: []const u8) ?[]u8 {
    var src = std.mem.trim(u8, raw, " \t\r\n");
    if (src.len < 2 or std.mem.indexOfAny(u8, src, "\r\n") != null) return null;
    if ((src[0] == '\'' and src[src.len - 1] == '\'') or (src[0] == '"' and src[src.len - 1] == '"')) {
        src = src[1 .. src.len - 1];
    }
    if (std.mem.startsWith(u8, src, "file://")) src = src["file://".len..];

    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == 0 or (c < 0x20 and c != '\t')) return null;
        if (c == '%' and i + 2 < src.len) {
            const hi = hexNibble(src[i + 1]);
            const lo = hexNibble(src[i + 2]);
            if (hi != null and lo != null) {
                const decoded = (hi.? << 4) | lo.?;
                if (decoded == 0 or decoded < 0x20) return null;
                out.append(decoded) catch return null;
                i += 3;
                continue;
            }
        }
        if (c == '\\' and i + 1 < src.len) {
            out.append(src[i + 1]) catch return null;
            i += 2;
            continue;
        }
        out.append(c) catch return null;
        i += 1;
    }
    if (out.items.len == 0 or out.items[0] != '/') return null;
    return out.toOwnedSlice() catch null;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
