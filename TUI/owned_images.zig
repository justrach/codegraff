//! Owned clipboard exports outlive every live draft/history consumer.
const std = @import("std");
const recovery = @import("clipboard_recovery.zig");
const Model = @import("app.zig").Model;

pub const Owned = struct {
    path: []const u8,
    identity: std.Io.File.Stat,
    retained: bool = false,
    store: ?*recovery.Store = null,
    lease: ?recovery.Lease = null,
};
var default_store: ?recovery.Store = null;
pub var test_store: ?*recovery.Store = null;
fn storeForPaste() ?*recovery.Store {
    if (@import("builtin").is_test) return test_store;
    if (default_store == null) {
        const temp = std.c.getenv("TMPDIR") orelse return null;
        if (!std.fs.path.isAbsolute(std.mem.span(temp))) return null;
        const root = std.fs.path.join(std.heap.page_allocator, &.{ std.mem.span(temp), "graff-tui-clipboard" }) catch return null;
        defer std.heap.page_allocator.free(root);
        default_store = recovery.Store.init(std.Io.Threaded.global_single_threaded.io(), std.heap.page_allocator, root) catch return null;
    }
    return &default_store.?;
}

fn identity(path: []const u8) ?std.Io.File.Stat {
    const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .follow_symlinks = false }) catch return null;
    return if (stat.kind == .file) stat else null;
}

pub fn attach(self: *Model, path: []const u8, owned: bool) void {
    if (!owned) return self.attachImage(path);
    const original = identity(path) orelse return self.attachImage(path);
    const copy = self.alloc.dupe(u8, path) catch {
        remove(.{ .path = path, .identity = original });
        return;
    };
    self.owned_images.append(.{ .path = copy, .identity = original }) catch {
        self.alloc.free(copy);
        remove(.{ .path = path, .identity = original });
        return;
    };
    const entry = &self.owned_images.items[self.owned_images.items.len - 1];
    if (storeForPaste()) |store| {
        _ = store.sweep(64);
        entry.store = store;
        entry.lease = store.record(path, original) catch null;
    }
    const before = self.images.items.len;
    self.attachImage(path);
    if (self.images.items.len == before) collect(self);
}

fn remove(owned: Owned) void {
    const current = identity(owned.path) orelse return;
    const original = owned.identity;
    // A pathname is not deletion authority after another file replaces it.
    // Also preserve edits made in place; reading a preview only changes atime.
    if (current.inode != original.inode or current.size != original.size or
        !std.meta.eql(current.mtime, original.mtime) or !std.meta.eql(current.ctime, original.ctime)) return;
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), owned.path) catch {};
}

fn contains(paths: []const []const u8, path: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

fn referenced(self: *const Model, path: []const u8) bool {
    if (contains(self.images.items, path)) return true;
    if (self.draft_images) |paths| if (contains(paths, path)) return true;
    for (self.prompt_hist_images.items) |paths| if (contains(paths, path)) return true;
    for (self.history.items) |entry| if (std.mem.indexOf(u8, entry.text, path) != null) return true;
    for (self.steer_queue.items) |text| if (std.mem.indexOf(u8, text, path) != null) return true;
    return false;
}

/// A submitted turn may be persisted independently of visible TUI history.
pub fn retain(self: *Model, text: []const u8) !void {
    for (self.owned_images.items) |*owned| {
        if (std.mem.indexOf(u8, text, owned.path) == null) continue;
        if (owned.store) |store| try store.retain(&owned.lease);
        owned.retained = true;
    }
}

pub fn collect(self: *Model) void {
    // Pending consumers may already hold a snapshot outside the model arrays.
    if (self.pending != null or self.bg != null) return;
    var i: usize = 0;
    while (i < self.owned_images.items.len) {
        var owned = self.owned_images.items[i];
        const path = owned.path;
        if (owned.retained or referenced(self, path)) {
            i += 1;
            continue;
        }
        remove(owned);
        if (owned.store) |store| store.release(&owned.lease);
        self.alloc.free(self.owned_images.orderedRemove(i).path);
    }
}

fn replayReferenced(self: *const Model, path: []const u8) bool {
    for (self.history.items) |entry| {
        if (entry.kind == .user and std.mem.indexOf(u8, entry.text, path) != null) return true;
    }
    return false;
}

pub fn deinit(self: *Model, settled: bool) void {
    for (self.owned_images.items) |*owned| {
        const path = owned.path;
        // Saved turns retain path markers. UI teardown is not proof that
        // those replay consumers (or an abandoned worker) have released them.
        if (settled and !owned.retained and !replayReferenced(self, path)) remove(owned.*);
        if (settled) if (owned.store) |store| store.release(&owned.lease);
        self.alloc.free(path);
    }
    self.owned_images.deinit();
}
