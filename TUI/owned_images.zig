//! Owned clipboard exports outlive every live draft/history consumer.
const std = @import("std");
const Model = @import("app.zig").Model;

pub fn attach(self: *Model, path: []const u8, owned: bool) void {
    if (!owned) return self.attachImage(path);
    const copy = self.alloc.dupe(u8, path) catch {
        remove(path);
        return;
    };
    self.owned_images.append(copy) catch {
        self.alloc.free(copy);
        remove(path);
        return;
    };
    const before = self.images.items.len;
    self.attachImage(path);
    if (self.images.items.len == before) collect(self);
}

fn remove(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
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

pub fn collect(self: *Model) void {
    // Pending consumers may already hold a snapshot outside the model arrays.
    if (self.pending != null or self.bg != null) return;
    var i: usize = 0;
    while (i < self.owned_images.items.len) {
        const path = self.owned_images.items[i];
        if (referenced(self, path)) {
            i += 1;
            continue;
        }
        remove(path);
        self.alloc.free(self.owned_images.orderedRemove(i));
    }
}

fn replayReferenced(self: *const Model, path: []const u8) bool {
    for (self.history.items) |entry| {
        if (entry.kind == .user and std.mem.indexOf(u8, entry.text, path) != null) return true;
    }
    return false;
}

pub fn deinit(self: *Model, settled: bool) void {
    for (self.owned_images.items) |path| {
        // Saved turns retain path markers. UI teardown is not proof that
        // those replay consumers (or an abandoned worker) have released them.
        if (settled and !replayReferenced(self, path)) remove(path);
        self.alloc.free(path);
    }
    self.owned_images.deinit();
}
