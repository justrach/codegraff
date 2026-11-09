//! Ownership of the workspace display path a mid-session switch adopts.
//!
//! `main.g_cwd_display` is read without a lock by the session save, tool
//! paths, permission prompts and ACP streaming, some of them on other threads.
//! A switch therefore never frees the display it replaces: every adopted path
//! stays alive until `deinit`, which the session runs after its final save, and
//! `deinit` leaves the global on static memory instead of on freed bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const main_mod = @import("main.zig");

var g_adopted: std.ArrayList([]u8) = .empty;

/// Point `g_cwd_display` at a gpa-owned copy of `path`. Best effort: on OOM the
/// previous display stays (it is still valid memory).
pub fn adopt(gpa: Allocator, path: []const u8) void {
    g_adopted.ensureUnusedCapacity(gpa, 1) catch return;
    const owned = gpa.dupe(u8, path) catch return;
    g_adopted.appendAssumeCapacity(owned);
    main_mod.g_cwd_display = owned;
}

pub fn adoptBranch(gpa: Allocator, branch: []const u8) void {
    g_adopted.ensureUnusedCapacity(gpa, 1) catch return;
    const owned = gpa.dupe(u8, branch) catch return;
    g_adopted.appendAssumeCapacity(owned);
    main_mod.g_worktree_branch = owned;
}

/// Free every display this process adopted. Teardown only: after this, no
/// reader may run, and the global no longer aliases any of the freed copies.
pub fn deinit(gpa: Allocator) void {
    for (g_adopted.items) |owned| {
        if (main_mod.g_cwd_display.ptr == owned.ptr) main_mod.g_cwd_display = ".";
        if (main_mod.g_worktree_branch) |b| if (b.ptr == owned.ptr) {
            main_mod.g_worktree_branch = null;
        };
        gpa.free(owned);
    }
    g_adopted.deinit(gpa);
    g_adopted = .empty;
}

/// Counts frees so a test can tell "retired" from "freed" without reading
/// freed memory.
const FreeCounter = struct {
    child: Allocator,
    frees: usize = 0,

    fn allocator(self: *FreeCounter) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FreeCounter = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *FreeCounter = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *FreeCounter = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *FreeCounter = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.child.rawFree(m, a, ra);
    }
};

test "#1193 a workspace switch keeps the replaced display alive until teardown" {
    var counter: FreeCounter = .{ .child = std.testing.allocator };
    const gpa = counter.allocator();
    const saved = main_mod.g_cwd_display;
    defer main_mod.g_cwd_display = saved;

    adopt(gpa, "/work/first-1193");
    const first = main_mod.g_cwd_display;
    adopt(gpa, "/work/second-1193");
    // An unlocked reader that captured the first display must still see it.
    try std.testing.expectEqual(@as(usize, 0), counter.frees);
    try std.testing.expectEqualStrings("/work/first-1193", first);
    try std.testing.expectEqualStrings("/work/second-1193", main_mod.g_cwd_display);

    const before_teardown = counter.frees;
    deinit(gpa);
    try std.testing.expect(counter.frees > before_teardown);
    // Teardown must not leave the global aliasing freed bytes.
    try std.testing.expectEqualStrings(".", main_mod.g_cwd_display);
}

test "#1193 teardown leaves a display it does not own untouched" {
    const saved = main_mod.g_cwd_display;
    defer main_mod.g_cwd_display = saved;
    adopt(std.testing.allocator, "/work/owned-1193");
    main_mod.g_cwd_display = "/work/static-1193";
    deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/work/static-1193", main_mod.g_cwd_display);
}
