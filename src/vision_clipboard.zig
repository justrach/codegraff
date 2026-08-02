//! macOS clipboard → a file we can stage: the pasteboard flavor cascade behind
//! Ctrl-V and `/paste`, the per-invocation temp path, the `sips`-based
//! is-it-really-an-image gate / PNG normalizer / downscaler, and the raw-byte
//! budget a staged image has to fit inside. Split out of vision.zig (600-line
//! goal); vision.zig re-exports the parts its callers need.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const trace = @import("trace.zig");

/// Raw (pre-base64) ceiling for one staged image.
///
/// An image travels base64-encoded, which inflates it by 4/3 — `ceil(n/3)*4`
/// bytes on the wire. Providers cap a SINGLE image at ~5 MB of *encoded*
/// payload, so the raw file has to stay under `5_000_000 * 3/4 = 3_750_000`
/// bytes. 3,700,000 encodes to 4,933,336 bytes and leaves the JSON envelope
/// (media_type, quoting, the rest of the message) a little room.
///
/// The old ceiling was 5 MiB of raw bytes, which base64-expands to 6.99 MB:
/// simultaneously too tight for reading (a 7.3 MB screenshot was refused) and
/// too loose for the wire (a 4 MB one was accepted and then 400'd), #349.
/// Raising it makes the wire failure worse, so the fix is `fitToBudget` —
/// downscale, then refuse only if it still will not fit.
pub const max_staged_image_bytes: u64 = 3_700_000;

/// Successively smaller max-dimensions handed to `sips -Z`. Ordered
/// largest-first so a paste keeps as much detail as the budget allows.
pub const downscale_steps = [_][]const u8{ "2048", "1568", "1024" };

/// Which pasteboard flavor produced the file. Recorded on the trace so a
/// dropped paste can be told apart from a PDF-only or file-url-only clipboard
/// after the fact (#350).
pub const Flavor = enum {
    /// `«class PNGf»` — macOS lazily synthesizes this from any raster flavor
    /// (TIFF, JPEG, HEIC, live data-provider promises), so it covers almost
    /// every real screenshot/copy-image clipboard.
    png,
    /// `«class furl»` — a file the user copied in Finder, Telegram, Slack…
    /// The pasteboard carries only the URL, never pixels.
    furl,
    /// `«class PDF »` — Preview, Illustrator, Keynote and friends put up a
    /// vector-only clipboard with no raster flavor at all.
    pdf,

    pub fn name(self: Flavor) []const u8 {
        return @tagName(self);
    }
};

/// A clipboard image that made it to disk.
pub const Grab = struct {
    path: []const u8,
    flavor: Flavor,
    /// The file at `path` is OURS and must be deleted on release. False when
    /// the cascade landed on a file the *user* owns (a `furl` clipboard whose
    /// target is already a stageable image) — deleting that would destroy the
    /// thing they just copied.
    owned: bool,

    /// Drop the temp file (if any) and free the path. Safe to call exactly
    /// once, success or failure, from a `defer` at the paste call site.
    pub fn release(self: Grab, io: Io, gpa: Allocator) void {
        if (self.owned) deleteQuietly(io, self.path);
        gpa.free(self.path);
    }
};

// ── temp paths ────────────────────────────────────────────────────────────

/// A fresh scratch path for this paste.
///
/// The old code hardcoded `/tmp/.harness-clip.png` in TWO places — a Zig
/// constant and, separately, a string inside the AppleScript source — which
/// had to be kept in sync by hand. Being fixed and world-writable it was also
/// a symlink-planting target and a live race: a second graff (or anything
/// else) could delete the file between osascript writing it and the stager
/// reading it, which reads out as a spurious "couldn't read the clipboard
/// image" (#349). The path is built ONCE here and interpolated into the
/// script's argv, so the two can no longer drift, and the 64 random bits make
/// it unguessable.
///
/// Only `[A-Za-z0-9./-]` ever appears, so the result needs no shell or
/// AppleScript quoting.
pub fn tempPath(io: Io, gpa: Allocator, ext: []const u8) ?[]const u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(gpa, "/tmp/graff-clip-{d}-{s}.{s}", .{ trace.currentPid(), hex[0..], ext }) catch null;
}

/// Delete a temp file and free its path — the cleanup half of `tempPath`.
pub fn discard(io: Io, gpa: Allocator, path: []const u8) void {
    deleteQuietly(io, path);
    gpa.free(path);
}

fn deleteQuietly(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ── filesystem probes ─────────────────────────────────────────────────────

/// Size of `path` if it is a regular file, else null. Null therefore means
/// "not there, or not a file" — never "too big", which is the distinction the
/// old single `.read_fail` threw away.
pub fn regularFileSize(io: Io, path: []const u8) ?u64 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    return st.size;
}

/// Extensions a provider accepts as-is (`imageMediaType` knows all of them).
pub fn stageableExtension(path: []const u8) bool {
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp" }) |ext|
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    return false;
}

/// `sips` as an is-this-an-image oracle: it exits 0 on an image it can read
/// and 13 on anything else, without writing a file.
pub fn sipsIsImage(io: Io, path: []const u8) bool {
    if (builtin.os.tag != .macos) return false;
    return runQuiet(io, &.{ "sips", "-g", "pixelWidth", path });
}

/// Can this `«class furl»` path actually be staged?
///
/// The coercion itself proves NOTHING. On a *plain-text* clipboard
/// `the clipboard as «class furl»` still succeeds: copying the word "hello"
/// yields the POSIX path `/hello` with exit status 0. So every furl path is
/// validated here — it must exist, be a regular non-empty file, and either
/// carry an image extension or survive the `sips` probe. `probe` is injected
/// so the trap can be tested without a pasteboard or a subprocess.
pub fn furlLooksStageable(io: Io, path: []const u8, probe: anytype) bool {
    if (path.len == 0 or path[0] != '/') return false;
    const size = regularFileSize(io, path) orelse return false;
    if (size == 0) return false;
    if (stageableExtension(path)) return true;
    return probe(io, path);
}

// ── downscaling ───────────────────────────────────────────────────────────

/// `sips -Z <max_dim> <in> --out <out>`: fit the image inside a square of
/// `max_dim` points, preserving aspect ratio.
pub fn sipsResize(io: Io, in: []const u8, max_dim: []const u8, out: []const u8) bool {
    if (builtin.os.tag != .macos) return false;
    return runQuiet(io, &.{ "sips", "-Z", max_dim, in, "--out", out });
}

/// Injected so `fitToBudget` is testable without macOS or a subprocess.
pub const Resizer = *const fn (io: Io, in: []const u8, max_dim: []const u8, out: []const u8) bool;

/// The file that will actually be read and encoded.
pub const Fit = struct {
    path: []const u8,
    bytes: u64,
    /// `path` is a downscale temp file: delete + free it after reading.
    temp: bool,
};

/// Bring `path` under `budget`, re-encoding at successively smaller max
/// dimensions rather than dropping the paste outright. Returns null only when
/// even the smallest step is still too big (or the resizer is unavailable),
/// which is what lets the caller report a real `too_large`.
pub fn fitToBudget(io: Io, gpa: Allocator, path: []const u8, size: u64, budget: u64, resize: Resizer) ?Fit {
    if (size <= budget) return .{ .path = path, .bytes = size, .temp = false };
    for (downscale_steps) |dim| {
        const out = tempPath(io, gpa, "png") orelse return null;
        if (resize(io, path, dim, out)) {
            if (regularFileSize(io, out)) |n| {
                if (n > 0 and n <= budget) return .{ .path = out, .bytes = n, .temp = true };
            }
        }
        discard(io, gpa, out);
    }
    return null;
}

/// What staging `path` will do, decided before a single byte is read. Split
/// out of the Agent-facing stager so the size math is testable on its own.
pub const Plan = union(enum) {
    /// Missing, or not a regular file.
    not_found,
    /// Over budget and undownscalable; the payload is the file's REAL size,
    /// statted rather than inferred from `error.StreamTooLong`.
    too_large: u64,
    fits: Fit,
};

pub fn planStage(io: Io, gpa: Allocator, path: []const u8, budget: u64, resize: Resizer) Plan {
    const size = regularFileSize(io, path) orelse return .not_found;
    const fit = fitToBudget(io, gpa, path, size, budget, resize) orelse return .{ .too_large = size };
    return .{ .fits = fit };
}

// ── the flavor cascade ────────────────────────────────────────────────────

/// macOS: export the clipboard image to a file and return its path, trying one
/// pasteboard flavor per osascript invocation and stopping at the first that
/// yields a real file. Null means the clipboard genuinely holds no image.
///
/// The old implementation asked for `«class PNGf»` and nothing else. That
/// covers every raster clipboard (macOS synthesizes PNGf from TIFF/JPEG/HEIC
/// and from live data-provider promises), but it silently loses the two cases
/// users actually hit: a copied *file* (`furl`, what Telegram/Finder put up)
/// and a vector-only `PDF ` clipboard (Preview, Illustrator, Keynote). #350.
pub fn grabClipboardImage(io: Io, gpa: Allocator) ?Grab {
    if (builtin.os.tag != .macos) return null;
    if (grabPng(io, gpa)) |g| return g;
    if (grabFurl(io, gpa)) |g| return g;
    if (grabPdf(io, gpa)) |g| return g;
    return null;
}

/// `open for access` line with our per-invocation path baked in.
fn openLine(gpa: Allocator, path: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(gpa, "set fp to open for access POSIX file \"{s}\" with write permission", .{path}) catch null;
}

fn grabPng(io: Io, gpa: Allocator) ?Grab {
    const path = tempPath(io, gpa, "png") orelse return null;
    var keep = false;
    defer if (!keep) discard(io, gpa, path);

    const open = openLine(gpa, path) orelse return null;
    defer gpa.free(open);
    const argv = [_][]const u8{
        "osascript",
        "-e", "try",
        "-e", "set theData to (the clipboard as «class PNGf»)",
        "-e", open,
        "-e", "set eof fp to 0",
        "-e", "write theData to fp",
        "-e", "close access fp",
        "-e", "on error",
        "-e", "error number 1",
        "-e", "end try",
    };
    if (!runQuiet(io, &argv)) return null;
    // Stat the export: osascript exiting 0 is not proof the bytes landed.
    if ((regularFileSize(io, path) orelse 0) == 0) return null;
    keep = true;
    return .{ .path = path, .flavor = .png, .owned = true };
}

fn grabFurl(io: Io, gpa: Allocator) ?Grab {
    const raw = runCapture(io, gpa, &.{ "osascript", "-e", "POSIX path of (the clipboard as «class furl»)" }) orelse return null;
    defer gpa.free(raw);
    const src = std.mem.trim(u8, raw, " \t\r\n");
    if (!furlLooksStageable(io, src, sipsIsImage)) return null;
    if (stageableExtension(src)) {
        // The user's own file, in place. `owned = false`: never delete it.
        const dup = gpa.dupe(u8, src) catch return null;
        return .{ .path = dup, .flavor = .furl, .owned = false };
    }
    // A .heic/.tiff/.bmp/… that sips vouched for: normalize to PNG.
    const out = tempPath(io, gpa, "png") orelse return null;
    if (sipsToPng(io, src, out) and (regularFileSize(io, out) orelse 0) > 0)
        return .{ .path = out, .flavor = .furl, .owned = true };
    discard(io, gpa, out);
    return null;
}

fn grabPdf(io: Io, gpa: Allocator) ?Grab {
    const pdf = tempPath(io, gpa, "pdf") orelse return null;
    defer discard(io, gpa, pdf); // the intermediate never outlives this call

    const open = openLine(gpa, pdf) orelse return null;
    defer gpa.free(open);
    const argv = [_][]const u8{
        "osascript",
        "-e", "try",
        "-e", "set theData to (the clipboard as «class PDF »)",
        "-e", open,
        "-e", "set eof fp to 0",
        "-e", "write theData to fp",
        "-e", "close access fp",
        "-e", "on error",
        "-e", "error number 1",
        "-e", "end try",
    };
    if (!runQuiet(io, &argv)) return null;
    if ((regularFileSize(io, pdf) orelse 0) == 0) return null;

    const out = tempPath(io, gpa, "png") orelse return null;
    if (sipsToPng(io, pdf, out) and (regularFileSize(io, out) orelse 0) > 0)
        return .{ .path = out, .flavor = .pdf, .owned = true };
    discard(io, gpa, out);
    return null;
}

fn sipsToPng(io: Io, in: []const u8, out: []const u8) bool {
    if (builtin.os.tag != .macos) return false;
    return runQuiet(io, &.{ "sips", "-s", "format", "png", in, "--out", out });
}

// ── subprocess plumbing ───────────────────────────────────────────────────

fn runQuiet(io: Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

/// stdout of a successful run, gpa-owned; null on spawn/read failure or a
/// non-zero exit.
fn runCapture(io: Io, gpa: Allocator, argv: []const []const u8) ?[]u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    const f = child.stdout orelse {
        _ = child.wait(io) catch {};
        return null;
    };
    var rbuf: [4096]u8 = undefined;
    var fr = f.readerStreaming(io, &rbuf);
    const captured = fr.interface.allocRemaining(gpa, .limited(8 * 1024)) catch {
        _ = child.wait(io) catch {};
        return null;
    };
    const term = child.wait(io) catch {
        gpa.free(captured);
        return null;
    };
    if (term != .exited or term.exited != 0) {
        gpa.free(captured);
        return null;
    }
    return captured;
}

// ── formatting ────────────────────────────────────────────────────────────

/// "7.3 MB" — MiB with one decimal, matching what a file manager shows, so the
/// number in the error line is the number the user can see on their own disk.
pub fn fmtMb(buf: *[16]u8, bytes: u64) []const u8 {
    const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "?? MB";
}

// ── tests ─────────────────────────────────────────────────────────────────
// Anything that needs a live pasteboard (grabClipboardImage and the osascript
// cascade) is deliberately NOT tested here: `zig build test` must not depend
// on whatever the developer last copied.

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

    const body = "0123456789" ** 4; // 40 bytes
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
    const io = testing.io;
    const gpa = testing.allocator;

    // A stand-in for sips: the first (largest) step still overshoots, the
    // second lands under budget — so a real paste keeps the most detail that
    // fits rather than being refused outright.
    const Fake = struct {
        var attempts: usize = 0;
        fn resize(rio: Io, _: []const u8, max_dim: []const u8, out: []const u8) bool {
            attempts += 1;
            const data = if (std.mem.eql(u8, max_dim, "2048")) "xxxxxxxxxxxxxxxx" else "xxxx";
            Io.Dir.cwd().writeFile(rio, .{ .sub_path = out, .data = data }) catch return false;
            return true;
        }
    };
    Fake.attempts = 0;

    const fit = fitToBudget(io, gpa, "/nonexistent-source.png", 1_000_000, 8, Fake.resize) orelse
        return error.ExpectedDownscale;
    defer discard(io, gpa, fit.path);
    try testing.expect(fit.temp);
    try testing.expectEqual(@as(u64, 4), fit.bytes);
    try testing.expectEqual(@as(usize, 2), Fake.attempts);
    // The rejected 2048 step left nothing behind.
    try testing.expect(regularFileSize(io, fit.path) != null);

    // Still too big at every step → null, which is what surfaces `too_large`.
    Fake.attempts = 0;
    try testing.expect(fitToBudget(io, gpa, "/nonexistent-source.png", 1_000_000, 2, Fake.resize) == null);
    try testing.expectEqual(downscale_steps.len, Fake.attempts);
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
