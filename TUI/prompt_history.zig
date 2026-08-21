//! TUI prompt-history sidecar (#577). Recalling a line restores the image
//! paths that were attached when it was submitted; only a path that still
//! exists is put back on the composer. Split out of dispatch.zig (600-line
//! cap). Modeled on src/readline_history.zig.

const std = @import("std");

const app = @import("app.zig");
const image = @import("image.zig");
const Model = app.Model;

pub fn deinit(self: *Model) void {
    for (self.prompt_hist_images.items) |paths| freePaths(self, paths);
    self.prompt_hist_images.deinit();
    clearDraft(self);
}

pub fn remember(self: *Model, line: []const u8) void {
    const dup = self.alloc.dupe(u8, line) catch return;
    self.prompt_hist.append(dup) catch {
        self.alloc.free(dup);
        return;
    };
    recordImages(self);
    self.hist_idx = null;
    clearDraft(self);
}

pub fn recallPrev(self: *Model) void {
    if (self.prompt_hist.items.len == 0) return;
    if (self.hist_idx == null) snapshotDraft(self);
    const next_i: usize = if (self.hist_idx) |i| (if (i == 0) 0 else i - 1) else self.prompt_hist.items.len - 1;
    self.hist_idx = next_i;
    apply(self, self.prompt_hist.items[next_i], imagesAt(self, next_i));
}

pub fn recallNext(self: *Model) void {
    const i = self.hist_idx orelse return;
    if (i + 1 >= self.prompt_hist.items.len) {
        self.hist_idx = null;
        apply(self, self.draft_text orelse "", self.draft_images orelse &.{});
        return;
    }
    self.hist_idx = i + 1;
    apply(self, self.prompt_hist.items[i + 1], imagesAt(self, i + 1));
}

fn recordImages(self: *Model) void {
    while (self.prompt_hist_images.items.len + 1 < self.prompt_hist.items.len) {
        self.prompt_hist_images.append(&.{}) catch return;
    }
    var paths = std.array_list.Managed([]const u8).init(self.alloc);
    for (self.images.items) |p| {
        const owned = self.alloc.dupe(u8, p) catch continue;
        paths.append(owned) catch self.alloc.free(owned);
    }
    const slice = paths.toOwnedSlice() catch {
        for (paths.items) |p| self.alloc.free(p);
        paths.deinit();
        self.prompt_hist_images.append(&.{}) catch {};
        return;
    };
    self.prompt_hist_images.append(slice) catch {
        freePaths(self, slice);
    };
}

fn snapshotDraft(self: *Model) void {
    clearDraft(self);
    self.draft_text = self.alloc.dupe(u8, self.input.getValue()) catch null;
    if (self.images.items.len == 0) return;
    var paths = std.array_list.Managed([]const u8).init(self.alloc);
    for (self.images.items) |p| {
        const owned = self.alloc.dupe(u8, p) catch continue;
        paths.append(owned) catch self.alloc.free(owned);
    }
    self.draft_images = paths.toOwnedSlice() catch {
        for (paths.items) |p| self.alloc.free(p);
        paths.deinit();
        return;
    };
}

fn clearDraft(self: *Model) void {
    if (self.draft_text) |t| {
        self.alloc.free(t);
        self.draft_text = null;
    }
    if (self.draft_images) |paths| {
        freePaths(self, paths);
        self.draft_images = null;
    }
}

fn apply(self: *Model, text: []const u8, paths: []const []const u8) void {
    self.input.setValue(text) catch {};
    replaceImages(self, paths);
}

fn replaceImages(self: *Model, paths: []const []const u8) void {
    for (self.images.items) |p| self.alloc.free(p);
    self.images.clearRetainingCapacity();
    for (paths) |p| {
        if (!image.pathBacked(p)) continue;
        const owned = self.alloc.dupe(u8, p) catch continue;
        self.images.append(owned) catch self.alloc.free(owned);
    }
}

fn imagesAt(self: *const Model, idx: usize) []const []const u8 {
    if (idx < self.prompt_hist_images.items.len) return self.prompt_hist_images.items[idx];
    return &.{};
}

fn freePaths(self: *Model, paths: []const []const u8) void {
    for (paths) |p| self.alloc.free(p);
    if (paths.len > 0) self.alloc.free(paths);
}

fn writeTmp(tmp: anytype, name: []const u8, data: []const u8, buf: []u8) ![]const u8 {
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    const n = try tmp.dir.realPath(io, buf);
    if (n + 1 + name.len > buf.len) return error.NameTooLong;
    buf[n] = '/';
    @memcpy(buf[n + 1 ..][0..name.len], name);
    return buf[0 .. n + 1 + name.len];
}

test "remember + recall restores backed image paths and drops missing ones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const live = try writeTmp(&tmp, "shot.png", "png", &path_buf);

    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.attachImage(live);
    m.attachImage("/no/such/image-577.png");
    remember(&m, "what is this");
    try std.testing.expectEqual(@as(usize, 1), m.prompt_hist.items.len);
    try std.testing.expectEqual(@as(usize, 2), m.images.items.len);

    for (m.images.items) |p| m.alloc.free(p);
    m.images.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), m.images.items.len);

    recallPrev(&m);
    try std.testing.expectEqualStrings("what is this", m.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), m.images.items.len);
    try std.testing.expectEqualStrings(live, m.images.items[0]);
}

test "down past newest restores the draft and its attachments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const older = try writeTmp(&tmp, "a.png", "a", &a_buf);
    const draft_path = try writeTmp(&tmp, "b.png", "b", &b_buf);

    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.attachImage(older);
    remember(&m, "older");
    for (m.images.items) |p| m.alloc.free(p);
    m.images.clearRetainingCapacity();

    m.attachImage(draft_path);
    m.input.setValue("draft in progress") catch {};
    recallPrev(&m);
    try std.testing.expectEqualStrings("older", m.input.getValue());
    try std.testing.expectEqualStrings(older, m.images.items[0]);

    recallNext(&m);
    try std.testing.expectEqualStrings("draft in progress", m.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), m.images.items.len);
    try std.testing.expectEqualStrings(draft_path, m.images.items[0]);
}
