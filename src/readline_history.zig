//! Prompt history + unsent-draft navigation for the line editor (#101), and
//! the staged-image sidecar that lets a replayed prompt carry its attachment
//! back with it (#108). Split out of readline.zig, which sat at 599 of its
//! 600-line cap and so could not absorb any further change. Pure over std plus
//! the PendingImage type — no terminal, agent, or session state — which is what
//! makes it directly unit-testable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const PendingImage = @import("vision.zig").PendingImage;

/// One history step: the text the buffer should show, plus the image that was
/// staged when that text was submitted (#108). `image` is borrowed from the
/// agent's session arena; the caller re-stages it on the agent as-is.
pub const Step = struct { text: []const u8, image: ?PendingImage = null };

/// History + unsent-draft navigation for the line editor (#101). Mirrors the
/// GUI's promptHistoryNavigation.ts: stepping UP out of the fresh slot snapshots
/// the half-typed draft; stepping DOWN past the newest entry restores it instead
/// of clearing the line. `idx == history.len` is the fresh (editing) slot.
/// `images` is index-aligned with `history` and may be shorter — entries loaded
/// from ~/.simple-harness-history predate this process and carry no image.
pub const HistoryNav = struct {
    idx: usize,
    draft: ?[]const u8 = null, // owned snapshot of the unsent line; freed by the caller
    draft_image: ?PendingImage = null, // the attachment staged alongside that draft (#108)

    pub fn init(history_len: usize) HistoryNav {
        return .{ .idx = history_len };
    }

    /// UP / older. `current`/`current_image` are the live buffer and the image
    /// staged on the agent right now. Returns the step the buffer should show
    /// next, or null to leave it unchanged (already at the oldest). Leaving the
    /// fresh slot snapshots both halves of the draft to restore later.
    pub fn up(
        self: *HistoryNav,
        gpa: Allocator,
        history: []const []const u8,
        images: []const ?PendingImage,
        current: []const u8,
        current_image: ?PendingImage,
    ) ?Step {
        if (self.idx == 0) return null;
        if (self.idx == history.len) { // leaving the fresh slot: keep the draft
            if (self.draft) |d| gpa.free(d);
            self.draft = gpa.dupe(u8, current) catch null;
            self.draft_image = current_image;
        }
        self.idx -= 1;
        return .{ .text = history[self.idx], .image = imageAt(images, self.idx) };
    }

    /// DOWN / newer. Returns the step to show next, or null to leave the buffer
    /// unchanged (already at the fresh slot). Past the newest entry, restores the
    /// snapshotted draft (or "" when there was none) instead of clearing it.
    pub fn down(self: *HistoryNav, history: []const []const u8, images: []const ?PendingImage) ?Step {
        if (self.idx >= history.len) return null;
        self.idx += 1;
        if (self.idx == history.len) return .{ .text = self.draft orelse "", .image = self.draft_image };
        return .{ .text = history[self.idx], .image = imageAt(images, self.idx) };
    }
};

fn imageAt(images: []const ?PendingImage, idx: usize) ?PendingImage {
    return if (idx < images.len) images[idx] else null;
}

/// Images staged with each submitted history entry, index-aligned with the
/// caller's `history` list (#108). Kept beside the text rather than in it so
/// ~/.simple-harness-history stays plain text: a line replayed from an earlier
/// run simply has no image here. Backed by the agent's session arena, which
/// already owns the base64 payloads, so nothing is freed independently.
pub const ImageSidecar = struct {
    items: std.ArrayList(?PendingImage) = .empty,

    /// Remember the image (if any) submitted with the entry now at `index`.
    /// Pads with null so the first image of a session still lands at the right
    /// index when history was loaded from disk.
    pub fn record(self: *ImageSidecar, arena: Allocator, index: usize, img: ?PendingImage) void {
        while (self.items.items.len < index) self.items.append(arena, null) catch return;
        if (index < self.items.items.len) {
            self.items.items[index] = img;
            return;
        }
        self.items.append(arena, img) catch {};
    }

    pub fn slice(self: *const ImageSidecar) []const ?PendingImage {
        return self.items.items;
    }
};

/// The one interactive history's sidecar. A module global because mainloop owns
/// `history` and readLine returns between every entry, so there is nowhere else
/// for per-entry attachments to live (#108).
pub var g_history_images: ImageSidecar = .{};

/// Would appending `line` just repeat the newest entry? Consecutive duplicates
/// are suppressed, but text equality alone is not the right identity (#108):
/// the same words with a different (or no) attachment are a different prompt,
/// so replaying one and resending it must not collapse the two.
pub fn repeatsLast(
    history: []const []const u8,
    images: []const ?PendingImage,
    line: []const u8,
    img: ?PendingImage,
) bool {
    if (history.len == 0) return false;
    const last = history.len - 1;
    if (!std.mem.eql(u8, history[last], line)) return false;
    return sameImage(imageAt(images, last), img);
}

fn sameImage(a: ?PendingImage, b: ?PendingImage) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x.media_type, y.media_type) and std.mem.eql(u8, x.b64, y.b64) and std.mem.eql(u8, x.url, y.url);
}

const no_images: []const ?PendingImage = &.{};

test "HistoryNav: up snapshots the draft, down past newest restores it (#101)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{ "first", "second" };
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);

    // up from the fresh slot → newest entry, draft snapshotted
    try std.testing.expectEqualStrings("second", nav.up(gpa, &history, no_images, "draft in progress", null).?.text);
    // up again → older entry
    try std.testing.expectEqualStrings("first", nav.up(gpa, &history, no_images, "second", null).?.text);
    // up at the oldest → no change
    try std.testing.expect(nav.up(gpa, &history, no_images, "first", null) == null);
    // down → back to newest
    try std.testing.expectEqualStrings("second", nav.down(&history, no_images).?.text);
    // down past newest → the draft is restored, NOT cleared (the bug)
    try std.testing.expectEqualStrings("draft in progress", nav.down(&history, no_images).?.text);
    // down at the fresh slot → no change
    try std.testing.expect(nav.down(&history, no_images) == null);
}

test "HistoryNav: no draft → fresh slot returns empty, no leak (#101)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{"only"};
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);
    try std.testing.expectEqualStrings("only", nav.up(gpa, &history, no_images, "", null).?.text);
    try std.testing.expectEqualStrings("", nav.down(&history, no_images).?.text); // empty draft → empty line, as today
}

test "HistoryNav: empty history navigates nowhere (#102)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{};
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);
    try std.testing.expect(nav.up(gpa, &history, no_images, "draft", null) == null);
    try std.testing.expect(nav.down(&history, no_images) == null);
    try std.testing.expect(nav.draft == null); // nothing to restore, so nothing snapshotted
}

test "HistoryNav: repeated up clamps at the oldest, keeping the draft (#102)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{ "first", "second", "third" };
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);
    try std.testing.expectEqualStrings("third", nav.up(gpa, &history, no_images, "draft in progress", null).?.text);
    try std.testing.expectEqualStrings("second", nav.up(gpa, &history, no_images, "third", null).?.text);
    try std.testing.expectEqualStrings("first", nav.up(gpa, &history, no_images, "second", null).?.text);
    for (0..3) |_| try std.testing.expect(nav.up(gpa, &history, no_images, "first", null) == null);
    try std.testing.expectEqual(@as(usize, 0), nav.idx); // pinned at the oldest, not wrapped
    // and the draft survived the clamped attempts
    try std.testing.expectEqualStrings("second", nav.down(&history, no_images).?.text);
    try std.testing.expectEqualStrings("third", nav.down(&history, no_images).?.text);
    try std.testing.expectEqualStrings("draft in progress", nav.down(&history, no_images).?.text);
}

test "HistoryNav: replay re-stages the entry's image, text-only clears it (#108)" {
    const gpa = std.testing.allocator;
    const shot: PendingImage = .{ .media_type = "image/png", .b64 = "iVBORw0KGgo=", .label = "/tmp/shot.png" };
    const history = [_][]const u8{ "[Image] what is this?", "plain question" };
    const images = [_]?PendingImage{ shot, null };
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);

    // newest entry is text-only → replaying it must clear a staged image
    const newest = nav.up(gpa, &history, &images, "", shot).?;
    try std.testing.expectEqualStrings("plain question", newest.text);
    try std.testing.expect(newest.image == null);

    // the image prompt replays with its attachment, not just the "[Image]" text
    const older = nav.up(gpa, &history, &images, "plain question", null).?;
    try std.testing.expectEqualStrings("[Image] what is this?", older.text);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", older.image.?.b64);
    try std.testing.expectEqualStrings("image/png", older.image.?.media_type);

    // back down past the newest: the draft's own attachment comes back too
    _ = nav.down(&history, &images);
    const back = nav.down(&history, &images).?;
    try std.testing.expectEqualStrings("", back.text);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", back.image.?.b64);
}

test "ImageSidecar: records past disk-loaded entries and stays aligned (#108)" {
    const gpa = std.testing.allocator;
    const shot: PendingImage = .{ .media_type = "image/png", .b64 = "AAA=", .label = "/tmp/a.png" };
    var side: ImageSidecar = .{};
    defer side.items.deinit(gpa);

    // history[0..2] came from ~/.simple-harness-history (text only); this
    // session submits an image prompt at index 2.
    side.record(gpa, 2, shot);
    try std.testing.expectEqual(@as(usize, 3), side.slice().len);
    try std.testing.expect(side.slice()[0] == null);
    try std.testing.expect(side.slice()[1] == null);
    try std.testing.expectEqualStrings("AAA=", side.slice()[2].?.b64);
    side.record(gpa, 3, null);
    try std.testing.expect(side.slice()[3] == null);
}

test "repeatsLast: same text with a different image stays distinct (#108)" {
    const a: PendingImage = .{ .media_type = "image/png", .b64 = "AAA=", .label = "/tmp/a.png" };
    const b: PendingImage = .{ .media_type = "image/png", .b64 = "BBB=", .label = "/tmp/b.png" };
    const history = [_][]const u8{"describe this"};
    const images = [_]?PendingImage{a};
    try std.testing.expect(repeatsLast(&history, &images, "describe this", a)); // identical resend → one entry
    try std.testing.expect(!repeatsLast(&history, &images, "describe this", b)); // new image → new entry
    try std.testing.expect(!repeatsLast(&history, &images, "describe this", null)); // image dropped → new entry
    try std.testing.expect(!repeatsLast(&history, &images, "something else", a));
    try std.testing.expect(!repeatsLast(&.{}, no_images, "first ever", null));
    // text-only history (no sidecar entry at all) still de-dupes as before
    try std.testing.expect(repeatsLast(&history, no_images, "describe this", null));
}
