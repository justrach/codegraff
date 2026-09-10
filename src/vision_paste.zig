//! Ctrl-V / `/paste` outcome types. Split out of vision.zig so that file
//! stays under the 600-line ceiling while #843 can name an access/export/
//! conversion failure separately from an empty clipboard.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const clip = @import("vision_clipboard.zig");

pub const Grab = clip.Grab;
pub const FailKind = clip.FailKind;
pub const GrabAttempt = clip.GrabAttempt;

/// Why a Ctrl-V clipboard paste did or did not produce an image (#258, #843).
/// Ordered so the cheapest, most-likely-wrong condition is decided first.
pub const ClipboardPasteSource = union(enum) {
    image: Grab,
    no_image,
    failed: FailKind,
    no_vision,
    unsupported_platform,
};

pub const no_vision_message = "this model can't see images — /model to a vision one (claude-*, gpt-5*)";

/// Decide a Ctrl-V paste WITHOUT touching the clipboard unless it can help.
///
/// The vision check comes first deliberately: on a non-vision model the paste
/// can never succeed, so shelling out to the clipboard would spend a subprocess
/// (and on macOS, a pasteboard read of whatever the user last copied) purely to
/// produce an error. `grabber` is injected so the ordering is testable without
/// a real clipboard. It must return `GrabAttempt`.
pub fn clipboardPasteSource(io: Io, gpa: Allocator, supports_vision: bool, is_macos: bool, grabber: anytype) ClipboardPasteSource {
    if (!supports_vision) return .no_vision;
    if (!is_macos) return .unsupported_platform;
    return switch (grabber(io, gpa)) {
        .ok => |g| .{ .image = g },
        .empty => .no_image,
        .failed => |k| .{ .failed = k },
    };
}

pub fn pasteFailMessage(kind: FailKind) []const u8 {
    return switch (kind) {
        .access => "couldn't read the clipboard — grant Automation access for osascript, then try again",
        .extract => "the clipboard image could not be exported — try Copy again, or save it and /image <path>",
        .convert => "the clipboard image could not be converted — try a PNG or JPEG",
    };
}

/// The user-facing line for every non-image paste outcome, so the caller's
/// switch stays one prong instead of four parallel string literals.
pub fn pasteMessage(source: ClipboardPasteSource) []const u8 {
    return switch (source) {
        .no_vision => no_vision_message,
        .unsupported_platform => "clipboard image paste is macOS-only — use /image <path>",
        .no_image => "no image on the clipboard — copy an image first (this is Ctrl-V; ⌘V can't be captured)",
        .failed => |k| pasteFailMessage(k),
        .image => "",
    };
}

test "clipboardPasteSource: vision is checked before the clipboard is touched (#258)" {
    const MockGrabber = struct {
        var calls: usize = 0;
        var result: GrabAttempt = .{ .ok = .{ .path = "/tmp/test.png", .flavor = .png, .owned = false } };

        fn grab(_: Io, _: Allocator) GrabAttempt {
            calls += 1;
            return result;
        }
    };
    const expectTag = struct {
        fn expect(expected: std.meta.Tag(ClipboardPasteSource), actual: ClipboardPasteSource) !void {
            try std.testing.expectEqual(expected, std.meta.activeTag(actual));
        }
    }.expect;

    MockGrabber.calls = 0;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try expectTag(.no_vision, clipboardPasteSource(io, gpa, false, true, MockGrabber.grab));
    try expectTag(.no_vision, clipboardPasteSource(io, gpa, false, false, MockGrabber.grab));
    try expectTag(.unsupported_platform, clipboardPasteSource(io, gpa, true, false, MockGrabber.grab));
    try std.testing.expectEqual(@as(usize, 0), MockGrabber.calls);

    try expectTag(.image, clipboardPasteSource(io, gpa, true, true, MockGrabber.grab));
    try std.testing.expectEqual(@as(usize, 1), MockGrabber.calls);

    MockGrabber.result = .empty;
    try expectTag(.no_image, clipboardPasteSource(io, gpa, true, true, MockGrabber.grab));
    try std.testing.expectEqual(@as(usize, 2), MockGrabber.calls);

    MockGrabber.result = .{ .failed = .extract };
    try expectTag(.failed, clipboardPasteSource(io, gpa, true, true, MockGrabber.grab));
    try std.testing.expectEqual(@as(usize, 3), MockGrabber.calls);
}

test "pasteMessage: empty clipboard and extraction failure are distinct (#843)" {
    const cases = [_]ClipboardPasteSource{
        .no_vision,
        .unsupported_platform,
        .no_image,
        .{ .failed = .access },
        .{ .failed = .extract },
        .{ .failed = .convert },
    };
    for (cases, 0..) |a, i| {
        try std.testing.expect(pasteMessage(a).len > 0);
        for (cases[i + 1 ..]) |b|
            try std.testing.expect(!std.mem.eql(u8, pasteMessage(a), pasteMessage(b)));
    }
    try std.testing.expectEqualStrings(no_vision_message, pasteMessage(.no_vision));
    try std.testing.expectEqualStrings(pasteFailMessage(.extract), pasteMessage(.{ .failed = .extract }));
}
