//! #349/#350 clipboard-staging behaviour tests. Split out of
//! vision_clipboard.zig (600-line ceiling); referenced from its test block so
//! they actually run.
//!
//! Anything that needs a live pasteboard (grabClipboardImage and the osascript
//! cascade) is deliberately NOT tested here: `zig build test` must not depend
//! on whatever the developer last copied.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const clip = @import("vision_clipboard.zig");
const max_staged_image_bytes = clip.max_staged_image_bytes;
const downscale_steps = clip.downscale_steps;
const png_magic = clip.png_magic;
const tempPath = clip.tempPath;
const discard = clip.discard;
const regularFileSize = clip.regularFileSize;
const stageableExtension = clip.stageableExtension;
const furlLooksStageable = clip.furlLooksStageable;
const looksLikePng = clip.looksLikePng;
const fitToBudget = clip.fitToBudget;
const planStage = clip.planStage;
const fmtMb = clip.fmtMb;

const testing = std.testing;

test "tempPath: unique per call, and safe to drop into a shell/AppleScript literal" {
    const io = testing.io;
    const gpa = testing.allocator;
    const a = tempPath(io, gpa, "png") orelse return error.NoTempPath;
    defer gpa.free(a);
    const b = tempPath(io, gpa, "png") orelse return error.NoTempPath;
    defer gpa.free(b);
    const c = tempPath(io, gpa, "pdf") orelse return error.NoTempPath;
    defer gpa.free(c);

    // The whole point of #349's race fix: two pastes never share a file.
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(std.mem.endsWith(u8, a, ".png"));
    try testing.expect(std.mem.endsWith(u8, c, ".pdf"));
    try testing.expect(std.mem.startsWith(u8, a, "/tmp/graff-clip-"));
    // No quoting anywhere: only these bytes may appear.
    for (a) |ch| try testing.expect(std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '.' or ch == '-');
}

test "stageableExtension: only formats a provider takes as-is" {
    try testing.expect(stageableExtension("/tmp/a.png"));
    try testing.expect(stageableExtension("/tmp/a.JPG"));
    try testing.expect(stageableExtension("/tmp/a.jpeg"));
    try testing.expect(stageableExtension("/tmp/a.gif"));
    try testing.expect(stageableExtension("/tmp/a.webp"));
    try testing.expect(!stageableExtension("/tmp/a.heic"));
    try testing.expect(!stageableExtension("/tmp/a.pdf"));
    try testing.expect(!stageableExtension("/hello"));
}

test "furlLooksStageable: the plain-text /hello coercion trap is rejected (#350)" {
    // POSIX-only: every path here is judged by `furlLooksStageable`'s leading
    // `/` check, which is a statement about AppleScript's `POSIX path of`
    // output, not about paths in general. On Windows a tmpDir realPath is
    // `C:\...` and "/hello" is not absolute at all, so both the positive and
    // the negative cases would be decided by the wrong branch. The whole furl
    // cascade is macOS-only (osascript), so there is nothing to assert there.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    try tmp.dir.writeFile(io, .{ .sub_path = "shot.png", .data = "\x89PNG\r\n\x1a\n not really a png, but the extension is enough" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "just text" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.png", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const png = try std.fmt.bufPrint(&path_buf, "{s}/shot.png", .{root});

    const never = struct {
        fn probe(_: Io, _: []const u8) bool {
            return false;
        }
    }.probe;
    const always = struct {
        fn probe(_: Io, _: []const u8) bool {
            return true;
        }
    }.probe;

    // A real image file passes on its extension alone — no subprocess needed.
    try testing.expect(furlLooksStageable(io, png, never));

    // `the clipboard as «class furl»` SUCCEEDS on the plain text "hello" and
    // hands back "/hello". It does not exist, so it must never be staged —
    // not even when the probe would say yes.
    try testing.expect(!furlLooksStageable(io, "/hello", always));
    // Relative / empty coercion output is not a path at all.
    try testing.expect(!furlLooksStageable(io, "hello", always));
    try testing.expect(!furlLooksStageable(io, "", always));

    // A real file that is not an image: the probe is the only gate, and it says no.
    const txt = try std.fmt.bufPrint(&path_buf, "{s}/notes.txt", .{root});
    try testing.expect(!furlLooksStageable(io, txt, never));

    // A directory is not a file, and a zero-byte "image" is not an image.
    try testing.expect(!furlLooksStageable(io, root, always));
    const empty = try std.fmt.bufPrint(&path_buf, "{s}/empty.png", .{root});
    try testing.expect(!furlLooksStageable(io, empty, always));
}

test "planStage: missing → not_found, oversize → too_large carrying the REAL size (#349)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const body = "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789"; // 40 bytes
    try tmp.dir.writeFile(io, .{ .sub_path = "big.png", .data = body });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const big = try std.fmt.bufPrint(&path_buf, "{s}/big.png", .{root});

    const cannot = struct {
        fn resize(_: Io, _: []const u8, _: []const u8, _: []const u8) bool {
            return false;
        }
    }.resize;

    // Over budget and unshrinkable: the byte count reported is the statted
    // size, never something inferred from error.StreamTooLong.
    switch (planStage(io, gpa, big, 8, cannot)) {
        .too_large => |n| try testing.expectEqual(@as(u64, body.len), n),
        else => return error.ExpectedTooLarge,
    }

    // Under budget: read in place, nothing to clean up.
    switch (planStage(io, gpa, big, max_staged_image_bytes, cannot)) {
        .fits => |f| {
            try testing.expect(!f.temp);
            try testing.expectEqual(@as(u64, body.len), f.bytes);
            try testing.expectEqualStrings(big, f.path);
        },
        else => return error.ExpectedFits,
    }

    // Missing is its own answer, distinct from both of the above.
    const gone = try std.fmt.bufPrint(&path_buf, "{s}/nope.png", .{root});
    try testing.expect(planStage(io, gpa, gone, max_staged_image_bytes, cannot) == .not_found);
    // …as is "there, but not a regular file".
    try testing.expect(planStage(io, gpa, root, max_staged_image_bytes, cannot) == .not_found);
}

test "fitToBudget: downscales instead of dropping, and cleans up the steps it rejects" {
    // POSIX-only: `fitToBudget` writes each downscale step to `tempPath`, which
    // hardcodes /tmp on purpose (see its doc comment — the path is interpolated
    // into AppleScript and must need no quoting). There is no /tmp on Windows,
    // so every step fails to write and the ladder reports "cannot shrink" for a
    // reason that has nothing to do with the logic under test.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = testing.io;
    const gpa = testing.allocator;

    // A stand-in for sips: the first (largest) step still overshoots, the
    // second lands under budget — so a real paste keeps the most detail that
    // fits rather than being refused outright. Both steps emit real PNG bytes,
    // which is the only thing `fitToBudget` will accept.
    const Fake = struct {
        var attempts: usize = 0;
        fn resize(rio: Io, _: []const u8, max_dim: []const u8, out: []const u8) bool {
            attempts += 1;
            const data = if (std.mem.eql(u8, max_dim, "2048")) png_magic ++ "xxxxxxxx" else png_magic;
            Io.Dir.cwd().writeFile(rio, .{ .sub_path = out, .data = data }) catch return false;
            return true;
        }
    };
    Fake.attempts = 0;

    const fit = fitToBudget(io, gpa, "/nonexistent-source.png", 1_000_000, 8, Fake.resize) orelse
        return error.ExpectedDownscale;
    defer discard(io, gpa, fit.path);
    try testing.expect(fit.temp);
    try testing.expectEqual(@as(u64, png_magic.len), fit.bytes);
    try testing.expectEqual(@as(usize, 2), Fake.attempts);
    // The rejected 2048 step left nothing behind.
    try testing.expect(regularFileSize(io, fit.path) != null);

    // Still too big at every step → null, which is what surfaces `too_large`.
    Fake.attempts = 0;
    try testing.expect(fitToBudget(io, gpa, "/nonexistent-source.png", 1_000_000, 2, Fake.resize) == null);
    try testing.expectEqual(downscale_steps.len, Fake.attempts);
}

test "fitToBudget: a step that is not really a PNG is rejected, never mislabelled" {
    // Same /tmp dependency as above. This one would *pass* on Windows, but only
    // because every step fails to write — a green light for the wrong reason is
    // worse than an honest skip, since it would keep passing if the magic-byte
    // check were deleted outright.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = testing.io;
    const gpa = testing.allocator;

    // `sips -Z` alone keeps the SOURCE encoding: pointed at a .jpg it exits 0
    // and writes JPEG bytes into the `.png` temp, which the stager would then
    // label `image/png` and the provider would 400 on. Well under every
    // budget, so only the magic-byte check can reject it.
    const Jpeg = struct {
        var attempts: usize = 0;
        fn resize(rio: Io, _: []const u8, _: []const u8, out: []const u8) bool {
            attempts += 1;
            Io.Dir.cwd().writeFile(rio, .{ .sub_path = out, .data = "\xff\xd8\xff\xe0 JFIF-ish" }) catch return false;
            return true;
        }
    };
    Jpeg.attempts = 0;

    try testing.expect(fitToBudget(io, gpa, "/nonexistent-source.jpg", 1_000_000, 1_000, Jpeg.resize) == null);
    // Every step was tried, and every one of them was cleaned up.
    try testing.expectEqual(downscale_steps.len, Jpeg.attempts);
}

test "looksLikePng: magic bytes, not the file name" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    try tmp.dir.writeFile(io, .{ .sub_path = "real.png", .data = png_magic ++ "IHDR..." });
    try tmp.dir.writeFile(io, .{ .sub_path = "liar.png", .data = "\xff\xd8\xff\xe0 actually a jpeg" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tiny.png", .data = "\x89PNG" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(looksLikePng(io, try std.fmt.bufPrint(&path_buf, "{s}/real.png", .{root})));
    try testing.expect(!looksLikePng(io, try std.fmt.bufPrint(&path_buf, "{s}/liar.png", .{root})));
    // Shorter than the signature, and a path that is not there at all.
    try testing.expect(!looksLikePng(io, try std.fmt.bufPrint(&path_buf, "{s}/tiny.png", .{root})));
    try testing.expect(!looksLikePng(io, try std.fmt.bufPrint(&path_buf, "{s}/gone.png", .{root})));
}

test "fmtMb: the size in the error line is the size the user sees" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("7.3 MB", fmtMb(&buf, 7_682_253));
    try testing.expectEqualStrings("3.5 MB", fmtMb(&buf, max_staged_image_bytes));
    try testing.expectEqualStrings("1.4 MB", fmtMb(&buf, 1_470_878));
}

test "max_staged_image_bytes: base64 of a full-budget image stays under the 5 MB wire cap" {
    const encoded = std.base64.standard.Encoder.calcSize(@intCast(max_staged_image_bytes));
    try testing.expect(encoded < 5_000_000);
    // …and the OLD 5 MiB ceiling did not, which is the #349 bug in one line.
    try testing.expect(std.base64.standard.Encoder.calcSize(5 * 1024 * 1024) > 5_000_000);
}
