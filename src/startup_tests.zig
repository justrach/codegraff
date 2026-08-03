//! Focused regression tests for startup.zig's credential-loading scope
//! decisions. Split out (rather than grown in startup.zig itself) to stay
//! under the 600-line file ceiling; main.zig is itself pinned at 600 lines,
//! so this is pulled into the test root via main_test.zig's own hook
//! instead of main.zig's directly (see main_test.zig's trailing test {}).
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const resolveKeys = @import("startup.zig").resolveKeys;

test "resolveKeys does not load Kimi/xAI OAuth credentials for an explicit unrelated provider" {
    // #274: loadKimiOAuth/loadXaiOAuth refresh in place (a synchronous
    // network round-trip) when the stored credential is near expiry. Before
    // the startup.zig fix, resolveKeys read them unconditionally, so an
    // unrelated explicit `--model codegraff` still paid for that read/
    // refresh whenever a kimi login file happened to exist. This proves the
    // on-disk file is not even opened once selection cannot route to kimi: a
    // valid, far-from-expiry credential on disk must NOT surface in the
    // resolved keys.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPath(io, &real_buf);
    const home = try arena.dupe(u8, real_buf[0..real_len]);

    try tmp.dir.createDirPath(io, ".kimi/credentials");
    const now_s = @divTrunc(Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000);
    const kimi_json = try std.fmt.allocPrint(
        arena,
        "{{\"access_token\":\"kimi-test-token\",\"refresh_token\":\"r\",\"expires_at\":{d}}}",
        .{now_s + 3600},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = ".kimi/credentials/graff-oauth.json", .data = kimi_json });

    const TestEnv = struct {
        home: []const u8,
        pub fn get(self: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "HOME")) return self.home;
            if (std.mem.eql(u8, key, "CODEGRAFF_API_KEY")) return "test-codegraff-key";
            return null;
        }
    };
    const env: TestEnv = .{ .home = home };

    const resolved = try resolveKeys(io, gpa, arena, env, "codegraff", null);
    try std.testing.expect(resolved.keys.get("kimi") == null);
    try std.testing.expectEqualStrings("codegraff", resolved.default_provider.id);

    // …and the mirror: an explicit --subagent-provider kimi is exactly as
    // explicit as --model, so the SAME launch shape (unrelated root provider)
    // must now load the kimi login — root sol + kimi workers used to fatal
    // "no key/login for subagent model 'k3' via 'kimi'" despite a valid
    // on-disk kimi credential, because the selective scope read only the
    // root model flag.
    const hinted = try resolveKeys(io, gpa, arena, env, "codegraff", "kimi");
    try std.testing.expectEqualStrings("kimi-test-token", hinted.keys.get("kimi").?);
    try std.testing.expectEqualStrings("codegraff", hinted.default_provider.id);

    // Scope units for the same rule (pub-flipped in startup.zig for this).
    const startup = @import("startup.zig");
    try std.testing.expect(startup.storedKeyMayAffectSelection("kimi", "gpt-5.6-sol", "kimi"));
    try std.testing.expect(!startup.storedKeyMayAffectSelection("kimi", "gpt-5.6-sol", null));
    try std.testing.expect(startup.startupStoredKeyScope("deepseek", true, "kimi").includes(6, "kimi"));
}
