//! Preserve single-use rotated `$CODEX_HOME/auth.json` tokens across private
//! `imagegen` `CODEX_HOME` runs.
//!
//! `imagegen_codex.prepareHome` links (or, when symlinks are unavailable,
//! copies) `real_home/auth.json` into a per-run `private_home/auth.json`.
//! ChatGPT OAuth `refresh_token` grants are single-use: if `codex exec`
//! refreshes an expired token mid-run, Codex writes a temp file in
//! `private_home` and atomically `rename`s it over `private_home/auth.json`,
//! replacing the symlink with a regular file holding the newly rotated
//! `refresh_token`. Deleting `private_home` without syncing that rotated file
//! back leaves `real_home/auth.json` permanently dead (`refresh_token_reused`).
//!
//! `syncRotatedAuth` runs right before `unlinkHome` in `runCodex`'s `defer`.
//! When `private_home/auth.json` is a non-symlink regular file containing valid
//! OAuth credentials that differ from `real_home/auth.json`, it atomically
//! persists the rotated record back to `real_home/auth.json` (mode `0600`,
//! preserving any co-owned top-level keys) under `oauth.oauth_refresh_mutex`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const credential_store = @import("credential_store.zig");
const oauth = @import("oauth.zig");
const workspace_switch = @import("workspace_switch.zig");

const max_auth_bytes: usize = 256 * 1024;

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

/// Compare the `YYYY-MM-DDTHH:MM:SS` prefix of two RFC3339 UTC timestamps so
/// `"2026-11-08T17:04:51Z"` (`'Z' = 0x5A`) never compares as newer than
/// `"2026-11-08T17:04:51.900Z"` (`'.' = 0x2E`) within the same second.
fn strictlyNewerRfc3339Sec(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len < 19 or rhs.len < 19) return false;
    if (lhs[4] != '-' or lhs[10] != 'T' or rhs[4] != '-' or rhs[10] != 'T') return false;
    return std.mem.order(u8, lhs[0..19], rhs[0..19]) == .gt;
}

pub fn syncRotatedAuth(io: Io, arena: Allocator, private_home: []const u8, real_home: []const u8) void {
    if (private_home.len == 0 or real_home.len == 0) return;
    if (workspace_switch.samePath(io, private_home, real_home)) return;

    const priv_auth = std.fmt.allocPrint(arena, "{s}/auth.json", .{private_home}) catch return;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Still a symlink -> codex never replaced it; leave `real_home/auth.json` untouched.
    if (Io.Dir.cwd().readLink(io, priv_auth, &link_buf)) |_| return else |err| {
        if (err != error.NotLink) return;
    }

    const st = Io.Dir.cwd().statFile(io, priv_auth, .{}) catch return;
    if (st.kind != .file or st.size == 0 or st.size > max_auth_bytes) return;

    oauth.oauth_refresh_mutex.lockUncancelable(io);
    defer oauth.oauth_refresh_mutex.unlock(io);

    const priv_bytes = Io.Dir.cwd().readFileAlloc(io, priv_auth, arena, .limited(max_auth_bytes)) catch return;
    const real_auth = std.fmt.allocPrint(arena, "{s}/auth.json", .{real_home}) catch return;
    const real_bytes = Io.Dir.cwd().readFileAlloc(io, real_auth, arena, .limited(max_auth_bytes)) catch null;
    if (real_bytes) |rb| {
        if (std.mem.eql(u8, priv_bytes, rb)) return;
    }

    const priv_val = std.json.parseFromSliceLeaky(Value, arena, priv_bytes, .{ .allocate = .alloc_always }) catch return;
    if (priv_val != .object) return;
    var priv_obj = priv_val.object;
    const priv_tokens_val = priv_obj.get("tokens") orelse return;
    if (priv_tokens_val != .object) return;
    const priv_tokens = priv_tokens_val.object;
    const priv_access = strField(priv_tokens, "access_token") orelse return;
    const priv_refresh = strField(priv_tokens, "refresh_token") orelse return;
    const priv_acct = strField(priv_tokens, "account_id") orelse "";

    var merged_extra = false;
    if (real_bytes) |rb| {
        if (std.json.parseFromSliceLeaky(Value, arena, rb, .{ .allocate = .alloc_always })) |real_val| {
            if (real_val == .object) {
                if (real_val.object.get("tokens")) |rt| if (rt == .object) {
                    const real_acct = strField(rt.object, "account_id") orelse "";
                    if (real_acct.len > 0 and priv_acct.len > 0 and !std.mem.eql(u8, real_acct, priv_acct)) return;
                    const real_access = strField(rt.object, "access_token") orelse "";
                    const real_refresh = strField(rt.object, "refresh_token") orelse "";
                    if (std.mem.eql(u8, real_access, priv_access) and std.mem.eql(u8, real_refresh, priv_refresh)) return;
                    if (strField(real_val.object, "last_refresh")) |real_lr| {
                        if (strField(priv_obj, "last_refresh")) |priv_lr| {
                            if (strictlyNewerRfc3339Sec(real_lr, priv_lr)) return;
                        }
                    }
                };
                // #402: keep any co-owned top-level keys from `real_home/auth.json`.
                var it = real_val.object.iterator();
                while (it.next()) |entry| {
                    if (!priv_obj.contains(entry.key_ptr.*)) {
                        priv_obj.put(arena, entry.key_ptr.*, entry.value_ptr.*) catch return;
                        merged_extra = true;
                    }
                }
            }
        } else |_| {}
    }

    const payload: []const u8 = if (merged_extra) blk: {
        var aw: Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.write(Value{ .object = priv_obj }) catch return;
        break :blk aw.writer.buffered();
    } else priv_bytes;

    Io.Dir.cwd().createDirPath(io, real_home) catch {};
    credential_store.replaceFile(io, Io.Dir.cwd(), real_auth, payload, credential_store.private_file) catch {
        credential_store.replaceFile(io, Io.Dir.cwd(), real_auth, payload, credential_store.private_file) catch {};
    };
}

const testing = std.testing;

test "syncRotatedAuth: atomic rename over private symlink persists single-use refresh_token back to real CODEX_HOME" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    const codex = @import("imagegen_codex.zig");
    const real_home = try std.fmt.allocPrint(arena, "{s}/real-codex", .{base});
    const priv_home = try std.fmt.allocPrint(arena, "{s}/run-1/home", .{base});
    try Io.Dir.cwd().createDirPath(io, real_home);
    const real_auth = try std.fmt.allocPrint(arena, "{s}/auth.json", .{real_home});
    const initial =
        \\{"auth_mode":"chatgpt","tokens":{"id_token":"id-1","access_token":"acc-old","refresh_token":"rt-single-1","account_id":"acct-1"},"last_refresh":"2026-11-08T10:00:00Z","agent_identity":"keep-me"}
    ;
    try credential_store.replaceFile(io, Io.Dir.cwd(), real_auth, initial, credential_store.private_file);

    // 1. Unchanged symlink (or copy): syncRotatedAuth + unlinkHome leaves real auth untouched.
    try codex.prepareHome(io, arena, priv_home, real_home);
    syncRotatedAuth(io, arena, priv_home, real_home);
    codex.unlinkHome(io, arena, priv_home);
    try testing.expectEqualStrings(initial, try Io.Dir.cwd().readFileAlloc(io, real_auth, arena, .limited(4096)));

    // 2. Simulate `codex exec` refreshing OAuth via atomic temp + rename over `priv_home/auth.json`.
    const priv_home_2 = try std.fmt.allocPrint(arena, "{s}/run-2/home", .{base});
    try codex.prepareHome(io, arena, priv_home_2, real_home);
    const priv_auth_2 = try std.fmt.allocPrint(arena, "{s}/auth.json", .{priv_home_2});
    const rotated =
        \\{"auth_mode":"chatgpt","tokens":{"id_token":"id-2","access_token":"acc-new","refresh_token":"rt-single-2","account_id":"acct-1"},"last_refresh":"2026-11-08T10:05:00.450Z"}
    ;
    // Note: write to a sibling temp path in `priv_home_2` and rename over `priv_auth_2`,
    // matching Codex's own atomic replacement (NOT credential_store.replaceFile, which
    // intentionally follows symlinks via `writeDestination`).
    const staged_tmp = try std.fmt.allocPrint(arena, "{s}/auth.json.tmp", .{priv_home_2});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = staged_tmp, .data = rotated });
    try Io.Dir.cwd().rename(staged_tmp, Io.Dir.cwd(), priv_auth_2, io);

    syncRotatedAuth(io, arena, priv_home_2, real_home);
    codex.unlinkHome(io, arena, priv_home_2);
    try Io.Dir.cwd().deleteTree(io, try std.fmt.allocPrint(arena, "{s}/run-2", .{base}));

    const synced_raw = try Io.Dir.cwd().readFileAlloc(io, real_auth, arena, .limited(4096));
    const synced = try std.json.parseFromSliceLeaky(Value, arena, synced_raw, .{});
    const tok = synced.object.get("tokens").?.object;
    try testing.expectEqualStrings("acc-new", tok.get("access_token").?.string);
    try testing.expectEqualStrings("rt-single-2", tok.get("refresh_token").?.string);
    // Co-owned top-level field from `real_home/auth.json` also survived (#402).
    try testing.expectEqualStrings("keep-me", synced.object.get("agent_identity").?.string);
}

test "syncRotatedAuth: copy-fallback unchanged, copy-fallback rotated, corrupt file, and newer real refresh" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    const real_home = try std.fmt.allocPrint(arena, "{s}/real", .{base});
    const priv_home = try std.fmt.allocPrint(arena, "{s}/priv", .{base});
    try Io.Dir.cwd().createDirPath(io, real_home);
    try Io.Dir.cwd().createDirPath(io, priv_home);
    const real_auth = try std.fmt.allocPrint(arena, "{s}/auth.json", .{real_home});
    const priv_auth = try std.fmt.allocPrint(arena, "{s}/auth.json", .{priv_home});

    const v1 =
        \\{"auth_mode":"chatgpt","tokens":{"access_token":"a1","refresh_token":"r1","account_id":"acct-1"},"last_refresh":"2026-11-08T12:00:00Z"}
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = real_auth, .data = v1 });
    // Copy-fallback unchanged: regular file with identical bytes does not rewrite real_auth.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = priv_auth, .data = v1 });
    const before_stat = try Io.Dir.cwd().statFile(io, real_auth, .{});
    syncRotatedAuth(io, arena, priv_home, real_home);
    const after_stat = try Io.Dir.cwd().statFile(io, real_auth, .{});
    try testing.expectEqual(before_stat.inode, after_stat.inode);

    // Corrupt / non-credential JSON in private home is ignored.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = priv_auth, .data = "{not-json" });
    syncRotatedAuth(io, arena, priv_home, real_home);
    try testing.expectEqualStrings(v1, try Io.Dir.cwd().readFileAlloc(io, real_auth, arena, .limited(4096)));

    // Copy-fallback rotated: regular file with newer tokens syncs back.
    const v2 =
        \\{"auth_mode":"chatgpt","tokens":{"access_token":"a2","refresh_token":"r2","account_id":"acct-1"},"last_refresh":"2026-11-08T12:01:00Z"}
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = priv_auth, .data = v2 });
    syncRotatedAuth(io, arena, priv_home, real_home);
    try testing.expectEqualStrings(v2, try Io.Dir.cwd().readFileAlloc(io, real_auth, arena, .limited(4096)));

    // Newer concurrent refresh already in `real_home` is never downgraded by an older private copy.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = priv_auth, .data = v1 });
    syncRotatedAuth(io, arena, priv_home, real_home);
    try testing.expectEqualStrings(v2, try Io.Dir.cwd().readFileAlloc(io, real_auth, arena, .limited(4096)));
}

test "runCodex cleanup syncs rotated single-use refresh_token back to real CODEX_HOME before deleting scratch" {
    const imagegen = @import("imagegen.zig");
    const run_mod = @import("imagegen_run.zig");
    const tools = @import("tools.zig");
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const home = try std.fmt.allocPrint(arena, "{s}/codex", .{base});
    const work = try std.fmt.allocPrint(arena, "{s}/work", .{base});
    try Io.Dir.cwd().createDirPath(io, home);
    try Io.Dir.cwd().createDirPath(io, work);
    const auth_path = try std.fmt.allocPrint(arena, "{s}/auth.json", .{home});
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = auth_path,
        .data = "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"old-a\",\"refresh_token\":\"old-rt\",\"account_id\":\"acct-1\"},\"last_refresh\":\"2026-11-08T09:00:00Z\"}",
    });

    const RotatingCodex = struct {
        fn privateHome(argv: []const []const u8) ?[]const u8 {
            for (argv) |arg| {
                if (std.mem.startsWith(u8, arg, "CODEX_HOME=")) return arg["CODEX_HOME=".len..];
            }
            return null;
        }

        fn run(a: Allocator, run_io: Io, argv: []const []const u8, _: u64, _: ?[]const u8) anyerror!run_mod.Outcome {
            if (std.mem.eql(u8, argv[0], "sips"))
                return .{ .exit_code = 0, .stdout = "f\n  pixelWidth: 64\n  pixelHeight: 64\n" };
            const priv = privateHome(argv) orelse return error.TestMissingCodexHome;
            const tmp_auth = try std.fmt.allocPrint(a, "{s}/auth.json.tmp", .{priv});
            const dst_auth = try std.fmt.allocPrint(a, "{s}/auth.json", .{priv});
            try Io.Dir.cwd().writeFile(run_io, .{
                .sub_path = tmp_auth,
                .data = "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"new-a\",\"refresh_token\":\"rotated-rt\",\"account_id\":\"acct-1\"},\"last_refresh\":\"2026-11-08T09:05:00Z\"}",
            });
            try Io.Dir.cwd().rename(tmp_auth, Io.Dir.cwd(), dst_auth, run_io);

            const dir = try std.fmt.allocPrint(a, "{s}/generated_images/s1", .{priv});
            try Io.Dir.cwd().createDirPath(run_io, dir);
            const png = "\x89PNG\r\n\x1a\n" ++ @as([4096]u8, @splat('z'));
            try Io.Dir.cwd().writeFile(run_io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/gen.png", .{dir}), .data = png });
            return .{ .exit_code = 0, .stdout = "done" };
        }
    };

    const saved = .{ imagegen.available, imagegen.codex_ready, imagegen.codex_home, imagegen.scratch_root, imagegen.api_key_present, run_mod.hook };
    defer {
        imagegen.available = saved[0];
        imagegen.codex_ready = saved[1];
        imagegen.codex_home = saved[2];
        imagegen.scratch_root = saved[3];
        imagegen.api_key_present = saved[4];
        run_mod.hook = saved[5];
    }
    imagegen.available = true;
    imagegen.codex_ready = true;
    imagegen.codex_home = home;
    imagegen.scratch_root = base;
    imagegen.api_key_present = false;
    run_mod.hook = RotatingCodex.run;

    var client: std.http.Client = undefined;
    const ctx: tools.ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = work,
    };
    var input = try std.json.parseFromSlice(Value, gpa, "{\"prompt\":\"circle\",\"out\":\"rot.png\"}", .{});
    defer input.deinit();
    const r = try imagegen.execImagegen(ctx, input.value);
    defer gpa.free(r.text);
    try testing.expect(!r.is_error);

    const updated = try Io.Dir.cwd().readFileAlloc(io, auth_path, arena, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, updated, "\"rotated-rt\"") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "\"new-a\"") != null);
}
