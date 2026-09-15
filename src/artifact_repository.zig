//! Repository identity comes from the CLI that will perform the mutation.
//! Missing evidence stays unknown; it never releases an ownership claim.
const std = @import("std");
const evidence = @import("pr_evidence.zig");
const A = std.mem.Allocator;

pub fn valid(identity: []const u8) bool {
    if (identity.len == 0 or identity.len > 2048) return false;
    var parts = std.mem.splitScalar(u8, identity, '/');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_' and (count != 0 or c != ':')) return false;
        count += 1;
    }
    return count == 3;
}

pub fn fromUrl(a: A, url: []const u8) !?[]const u8 {
    const raw = if (std.mem.startsWith(u8, url, "https://")) url[8..] else if (std.mem.startsWith(u8, url, "http://")) url[7..] else return null;
    const trimmed = std.mem.trimEnd(u8, raw, "/");
    if (!valid(trimmed)) return null;
    return try std.ascii.allocLowerString(a, trimmed);
}

pub fn resolve(a: A, io: std.Io, cwd: []const u8, repo: ?[]const u8) ?[]const u8 {
    if (repo) |r| if (r.len == 0 or r.len > 2048) return null;
    const target = evidence.Target{ .cwd = cwd, .selector = "" };
    const argv: []const []const u8 = if (repo) |r| &.{ "gh", "repo", "view", "--json", "url", "--", r } else &.{ "gh", "repo", "view", "--json", "url" };
    const json = evidence.capture(std.heap.page_allocator, io, a, target, argv) catch return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return null;
    if (value != .object) return null;
    const url = value.object.get("url") orelse return null;
    if (url != .string) return null;
    return fromUrl(a, url.string) catch null;
}

pub const PullRequest = struct { repo: []const u8, number: []const u8, branch: []const u8, head_repo: ?[]const u8 };

pub fn pullRequest(a: A, io: std.Io, target: evidence.Target) ?PullRequest {
    const fields = "number,url,headRefName,headRepository";
    const argv: []const []const u8 = if (target.selector.len > 0) &.{ "gh", "pr", "view", target.selector, "--json", fields } else &.{ "gh", "pr", "view", "--json", fields };
    const json = evidence.capture(std.heap.page_allocator, io, a, target, argv) catch return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return null;
    if (value != .object) return null;
    const name = value.object.get("headRefName") orelse return null;
    const number = value.object.get("number") orelse return null;
    const url = value.object.get("url") orelse return null;
    if (name != .string or name.string.len == 0 or number != .integer or number.integer <= 0 or url != .string) return null;
    const id = std.fmt.allocPrint(a, "{d}", .{number.integer}) catch return null;
    const split = std.mem.lastIndexOf(u8, url.string, "/pull/") orelse return null;
    if (!std.mem.eql(u8, url.string[split + 6 ..], id)) return null;
    const repo = (fromUrl(a, url.string[0..split]) catch null) orelse return null;
    var head_repo: ?[]const u8 = null;
    if (value.object.get("headRepository")) |head| if (head == .object) {
        if (head.object.get("nameWithOwner")) |full| if (full == .string) {
            const host_end = std.mem.indexOfScalar(u8, repo, '/').?;
            const identity = std.fmt.allocPrint(a, "{s}/{s}", .{ repo[0..host_end], full.string }) catch return null;
            if (valid(identity)) head_repo = std.ascii.allocLowerString(a, identity) catch return null;
        };
    };
    return .{ .repo = repo, .number = id, .branch = name.string, .head_repo = head_repo };
}

test "repository identity includes host and normalizes only observed URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("github.com/owner/repo", (try fromUrl(a, "https://GitHub.com/Owner/Repo/")).?);
    try std.testing.expectEqualStrings("git.example:8443/owner/repo", (try fromUrl(a, "https://git.example:8443/owner/repo")).?);
    for ([_][]const u8{ "owner/repo", "https://github.com/owner", "https://github.com/owner/repo/pull/1", "https://secret@github.com/owner/repo", "https://github.com/owner/repo?x=1" }) |url|
        try std.testing.expect(try fromUrl(a, url) == null);
}
