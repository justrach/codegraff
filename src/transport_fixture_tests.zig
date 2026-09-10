//! Source contracts for transport replay fixtures (#848/#846) and the packed
//! SDK install smoke (#834). The PTY / npm smokes are not in tier 1; these
//! tests keep the fixture helpers from regressing to “any parent is stale”
//! or “fixture version = SDK version”.

const std = @import("std");
const Io = std.Io;

fn readRepo(path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
}

test "#848/#846: mock records a per-connection prewarm and accepts only that anchor" {
    const mock = try readRepo("scripts/codex_ws_mock.py");
    defer std.testing.allocator.free(mock);
    try std.testing.expect(std.mem.indexOf(u8, mock, "prewarm_ids") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock, "def has_fresh_parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock, "def assert_fresh_anchor") != null);
    const rec = std.mem.indexOf(u8, mock, "self.prewarm_ids[connection_id]").?;
    const count = std.mem.indexOf(u8, mock, "self.ws_turns += 1").?;
    try std.testing.expect(rec < count);
}

test "#848/#846: recovery fixtures allow this socket's prewarm, not any parent" {
    const mid = try readRepo("scripts/codex_ws_test.py");
    defer std.testing.allocator.free(mid);
    try std.testing.expect(std.mem.indexOf(u8, mid, "if not mock.has_fresh_parent(request):") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, mid, "if not mock.has_fresh_parent(request):"));
    try std.testing.expect(std.mem.indexOf(u8, mid, "if \"previous_response_id\" in request.body:") == null);

    const err = try readRepo("scripts/codex_ws_error_test.py");
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "or not mock.has_fresh_parent(rebuilt)") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "or \"previous_response_id\" in rebuilt.body") == null);
    try std.testing.expect(std.mem.indexOf(u8, err, "resp_chain_1") != null);
}

test "#834: packed-install fixtures use optionalDependency versions offline" {
    const src = try readRepo("sdk/ts/scripts/test-packed-install.mjs");
    defer std.testing.allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "optionalDependencies?.[packageName]") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\"--version\", version") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\"--offline\"") != null);
}
