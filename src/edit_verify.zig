//! edit_file's write path, and the post-edit verification that makes a write
//! which did not land LOUD (#337).
//!
//! edit_file was reporting `replaced 1 occurrence(s) in <file>` — sometimes
//! with a `(zigpatch)` suffix — over files it had left byte-identical. A loud
//! failure costs one retry; a confident false success corrupts everything
//! built on top of it. So the check lives ON the success path: every route
//! that would emit that message re-reads the file from disk first, and no
//! caller can skip it.
//!
//! Split out of exec.zig, which sits at the 600-line ceiling. `fsErrorText`
//! and `preserveMode` came along because the edit path owns them; read_file
//! and write_file only borrow them.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const strField = tools.strField;
const missingArg = tools.missingArg;
const outsideCwd = tools.outsideCwd;
const approvals_mod = @import("approvals.zig");
const confinedPath = approvals_mod.confinedPath;
const noSymlinkEscape = approvals_mod.noSymlinkEscape;
const runCapped = @import("jobs.zig").runCapped;
const codedbpro_report = @import("codedbpro_report.zig"); // persistent-daemon splice fast path

/// Whole-file read ceiling for the splice source (unchanged from exec.zig).
const edit_read_cap: usize = 1024 * 1024;
/// The verification re-read is deliberately looser than the source cap: a
/// `replace_all` can grow a file past it, and a re-read that failed on size
/// alone would report a false "did not persist".
const verify_read_cap: usize = 16 * 1024 * 1024;

/// The companion binary the premium splice shells out to. `pub var` purely so
/// a test can point it at a stub that CLAIMS success without writing — the
/// exact shape of #337. Production leaves it at `zigpatch` on PATH.
pub var companion_bin: []const u8 = "zigpatch";

// --- same-file write serialization ---------------------------------------

/// Striped write locks for the file-mutating tools. edit_file/write_file calls
/// issued in ONE assistant message run CONCURRENTLY — agent_tools.zig fans
/// them out with `io.async` and joins the futures afterwards — so two edits to
/// the same file could interleave read → splice → write and silently drop one
/// of them (#337 repro C: "both report success, only one persists"). Hashing
/// the resolved path onto a stripe serializes exactly those: same file, one
/// writer at a time. Different files usually land on different stripes and
/// still run in parallel, and a hash collision costs a little serialization,
/// never correctness. `Io.Mutex` rather than `std.Thread.Mutex` because the
/// waiter parks through `io`, so it is correct on a fiber-backed Io too.
var write_locks: [16]Io.Mutex = @splat(.init);

/// Take the write lock covering `resolved`. The caller must `unlock(io)` it.
pub fn lockPath(io: Io, resolved: []const u8) *Io.Mutex {
    const idx: usize = @intCast(std.hash.Wyhash.hash(0, resolved) % write_locks.len);
    const lock = &write_locks[idx];
    lock.lockUncancelable(io);
    return lock;
}

// --- the verifier ---------------------------------------------------------

/// What a re-read of the file says about an edit that just reported success.
pub const Verdict = enum {
    /// The edit is on disk.
    ok,
    /// The file could not be re-read at all after the write.
    unreadable,
    /// Byte-identical to before the edit: nothing was written. The #337 shape.
    unchanged,
    /// Changed, but not into the bytes graff spliced.
    mismatch,
    /// new_string is nowhere in the file the companion left behind.
    missing_new,
    /// new_string is there, but fewer times than there were occurrences to
    /// replace: the splice covered only some of them.
    partial,
    /// old_string survives more often than the replacement allows: the splice
    /// was partial, or never happened.
    stale_old,
};

/// Verify a splice graff computed AND wrote itself. We know the exact bytes
/// that were supposed to land, so anything else on disk is a failure.
pub fn verifyNative(before: []const u8, after: []const u8, expected: []const u8) Verdict {
    if (std.mem.eql(u8, after, expected)) return .ok;
    if (std.mem.eql(u8, after, before)) return .unchanged;
    return .mismatch;
}

/// Verify a splice an EXTERNAL companion applied. An exact match against what
/// graff would have written is the happy path, but not the only legal one — a
/// companion is free to normalize (zigpatch reports a `strategy`, and only one
/// of those is byte-exact), so the fallback is semantic:
///
///   * the file must not be byte-identical to what it was before,
///   * new_string must appear at least once per occurrence that was supposed
///     to be replaced (unless the edit was a deletion), and
///   * old_string must be gone, except for the copies that legitimately live
///     INSIDE new_string — the insert-around-existing-text case, where
///     old ⊂ new leaves exactly one copy per occurrence replaced.
///
/// The occurrence *counts* matter, not just presence: when old ⊂ new, a splice
/// that covered one of two sites leaves old_string exactly as often as a
/// correct one would, and only the new_string tally tells them apart.
pub fn verifyCompanion(before: []const u8, after: []const u8, expected: []const u8, old: []const u8, new: []const u8) Verdict {
    if (std.mem.eql(u8, after, expected)) return .ok;
    if (std.mem.eql(u8, after, before)) return .unchanged;
    if (old.len == 0) return .mismatch; // caller rejects this earlier; never trust it here
    const sites = std.mem.count(u8, before, old);
    if (new.len > 0) {
        const produced = std.mem.count(u8, after, new);
        if (produced == 0) return .missing_new;
        if (produced < sites) return .partial;
    }
    const inner = std.mem.count(u8, new, old); // 0 unless old is a substring of new
    if (std.mem.count(u8, after, old) > sites * inner) return .stale_old;
    return .ok;
}

/// The loud tool error a failed verdict becomes. Names the file, says plainly
/// that the edit is NOT on disk, and points at the only safe recovery: read it
/// again and re-issue against what is actually there. Never returns the
/// success message. `via` names whatever claimed success.
pub fn verdictText(gpa: Allocator, path: []const u8, verdict: Verdict, via: []const u8) Allocator.Error![]u8 {
    const detail = switch (verdict) {
        .ok => "the edit verified", // unreachable in practice; never phrased as a failure
        .unreadable => "the file could not be read back at all",
        .unchanged => "the file on disk is byte-for-byte what it was before",
        .mismatch => "the file on disk is not the content that was spliced",
        .missing_new => "new_string is not in the file",
        .partial => "new_string reached only some of the places it should have",
        .stale_old => "old_string is still in the file",
    };
    return std.fmt.allocPrint(
        gpa,
        "edit_file: the edit to {s} did NOT persist — {s} reported success but {s}. Treat the file as unchanged: nothing that depends on this edit has happened. read_file {s} again and re-issue the edit against the text that is actually there.",
        .{ path, via, detail, path },
    );
}

/// Re-read `resolved` and judge what landed. Runs on the success path of every
/// route, right before the `replaced N occurrence(s)` message is built.
fn verifyOnDisk(
    gpa: Allocator,
    io: Io,
    resolved: []const u8,
    before: []const u8,
    expected: []const u8,
    old: []const u8,
    new: []const u8,
    via_companion: bool,
) Verdict {
    const after = Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(verify_read_cap)) catch return .unreadable;
    defer gpa.free(after);
    return if (via_companion)
        verifyCompanion(before, after, expected, old, new)
    else
        verifyNative(before, after, expected);
}

/// Has anything touched the file since `prev` was taken? Size or mtime is
/// enough: an in-place truncate changes the size, an atomic tmp+rename changes
/// the mtime. A missing baseline (the stat failed) can never claim drift.
fn drifted(io: Io, resolved: []const u8, prev: ?Io.Dir.Stat) bool {
    const base = prev orelse return false;
    const now = Io.Dir.cwd().statFile(io, resolved, .{}) catch return false;
    return now.size != base.size or now.mtime.nanoseconds != base.mtime.nanoseconds;
}

// --- the edit_file tool ---------------------------------------------------

/// `edit_file`: argument validation, worktree resolution (#276 P0-1), then the
/// verified splice.
pub fn execEdit(ctx: ToolCtx, input: Value) !ToolOutput {
    const gpa = ctx.gpa;
    const path = strField(input, "path") orelse return missingArg(gpa, "path");
    const old = strField(input, "old_string") orelse return missingArg(gpa, "old_string");
    const new = strField(input, "new_string") orelse return missingArg(gpa, "new_string");
    if (!confinedPath(path) or !noSymlinkEscape(ctx.io, path, ctx.agent_cwd)) return outsideCwd(gpa, path);
    const all = tools.json_args.flag(input, "replace_all");
    if (old.len == 0) return .{ .text = try gpa.dupe(u8, "old_string must not be empty"), .is_error = true };

    // #276 P0-1: resolve under the agent's isolated worktree when set.
    const resolved: []const u8 = if (ctx.agent_cwd) |base| try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, path }) else path;
    defer if (ctx.agent_cwd != null) gpa.free(resolved);
    return applyEdit(ctx, path, resolved, old, new, all);
}

/// Read, splice, write, VERIFY. `path` is what the model asked for (and what
/// every message names); `resolved` is where the bytes actually live.
pub fn applyEdit(ctx: ToolCtx, path: []const u8, resolved: []const u8, old: []const u8, new: []const u8, all: bool) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;

    const lock = lockPath(io, resolved);
    defer lock.unlock(io);

    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const data = Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(edit_read_cap)) catch |err| {
            if (fsErrorText(gpa, .edit, path, err)) |t| return .{ .text = t, .is_error = true };
            return err;
        };
        defer gpa.free(data);
        // #179: capture the file's mode now so the atomic rewrite below can't
        // drop a 0755 executable bit down to the default 0644. Doubles as the
        // drift baseline.
        const prev_stat = Io.Dir.cwd().statFile(io, resolved, .{}) catch null;

        const count = std.mem.count(u8, data, old);
        if (count == 0) return .{
            .text = try std.fmt.allocPrint(gpa, "old_string not found in {s} — read_file it and match the existing text exactly", .{path}),
            .is_error = true,
        };
        if (count > 1 and !all) return .{
            .text = try std.fmt.allocPrint(gpa, "old_string matches {d} places in {s} — include more surrounding context to make it unique, or set replace_all", .{ count, path }),
            .is_error = true,
        };

        const replaced = try gpa.alloc(u8, std.mem.replacementSize(u8, data, old, new));
        defer gpa.free(replaced);
        _ = std.mem.replace(u8, data, old, new, replaced);

        // #337: the splice source is read live here — there is no cached copy
        // of the file anywhere in this path — but an out-of-band writer (a
        // `sed -i`, a formatter, an indexing daemon) landing between that read
        // and this write would be clobbered by bytes computed off the older
        // file. Re-stat and recompute once against what is there now; a second
        // drift falls through to the write, where verification is the backstop.
        if (attempt == 0 and drifted(io, resolved, prev_stat)) continue;

        if (ctx.snapshots) |snaps| if (!ctx.from_sub) snaps.record(path, .{ .content = data }); // pre-edit content for /rewind

        // Fastest splice first: the persistent codedb-pro daemon skips
        // zigpatch's ~2.4ms fork/exec floor (~0.3ms over the pipe, measured).
        // The /rewind snapshot above already ran and verifyOnDisk still backs
        // the result — only the byte-splice is delegated. null falls through
        // to the zigpatch spawn, then the native write.
        if (codedbpro_report.spliceViaDaemon(gpa, ctx, resolved, path, old, new, count, data.len)) |msg| {
            preserveMode(io, resolved, prev_stat); // daemon renames a fresh inode into place, same as zigpatch
            const verdict = verifyOnDisk(gpa, io, resolved, data, replaced, old, new, true);
            if (verdict != .ok) return .{ .text = try verdictText(gpa, path, verdict, "codedb-pro"), .is_error = true };
            return .{ .text = msg };
        }

        // Premium splice: when the zigrep suite is installed, zigpatch does the
        // write — an atomic tmp+rename byte-level --all splice (our count
        // checks above already enforce the uniqueness semantics). Any failure,
        // including the tool simply not being on PATH, falls back to the native
        // in-place write below. zigpatch is a separate process (`.inherit`
        // cwd, #276) so it's handed `resolved` — an absolute path when isolated
        // — directly, rather than relying on its own cwd.
        zp: {
            const run = runCapped(gpa, io, &.{ companion_bin, resolved, "-p", old, "--all", "--content", new }, 4096, 4096, 0) catch break :zp;
            defer {
                gpa.free(run.stdout);
                gpa.free(run.stderr);
            }
            const ok = switch (run.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok and std.mem.indexOf(u8, run.stdout, "\"ok\":true") != null) {
                preserveMode(io, resolved, prev_stat); // #179: zigpatch renamed a fresh inode into place
                // #337: zigpatch claiming success is not evidence that it
                // wrote anything. Ask the filesystem.
                const verdict = verifyOnDisk(gpa, io, resolved, data, replaced, old, new, true);
                if (verdict != .ok) return .{ .text = try verdictText(gpa, path, verdict, "zigpatch"), .is_error = true };
                return .{ .text = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s} (zigpatch, verified)", .{ count, path }) };
            }
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = replaced });
        preserveMode(io, resolved, prev_stat); // #179: keep the pre-edit mode
        const verdict = verifyOnDisk(gpa, io, resolved, data, replaced, old, new, false);
        if (verdict != .ok) return .{ .text = try verdictText(gpa, path, verdict, "the write"), .is_error = true };
        return .{ .text = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s} (verified)", .{ count, path }) };
    }
}

// --- shared filesystem helpers (moved from exec.zig) ----------------------

/// The three native file tools, used to shape a filesystem-error message with
/// the tool's own name and the right recovery hint (#183).
pub const FileOp = enum {
    read,
    edit,
    write,
    fn tool(self: FileOp) []const u8 {
        return switch (self) {
            .read => "read_file",
            .edit => "edit_file",
            .write => "write_file",
        };
    }
};

/// Maps an EXPECTED filesystem error from a native file tool to a clear message
/// naming the tool, the supplied path, and the failure — so the model sees
/// "read_file: foo.zig does not exist" instead of a bare "error: FileNotFound"
/// (#183). Returns null for anything outside the usual path/permission set, so
/// the caller re-throws it onto the generic harness-failure path. Confinement,
/// symlink, and validation errors are already handled before the fs call and
/// never reach here. Caller owns the returned slice.
pub fn fsErrorText(gpa: Allocator, op: FileOp, path: []const u8, err: anyerror) ?[]u8 {
    return (switch (err) {
        // A missing target, or a non-directory used as a path component.
        error.FileNotFound, error.NotDir => switch (op) {
            .read => std.fmt.allocPrint(gpa, "read_file: {s} does not exist (paths are relative to the cwd) — check the name, or list the directory with bash `ls`", .{path}),
            .edit => std.fmt.allocPrint(gpa, "edit_file: {s} does not exist — edit_file only rewrites an existing file; use write_file to create it", .{path}),
            .write => std.fmt.allocPrint(gpa, "write_file: cannot create {s} — its parent directory does not exist; create it first with bash `mkdir -p`", .{path}),
        },
        error.IsDir => std.fmt.allocPrint(gpa, "{s}: {s} is a directory, not a file", .{ op.tool(), path }),
        error.AccessDenied, error.PermissionDenied => std.fmt.allocPrint(gpa, "{s}: permission denied for {s}", .{ op.tool(), path }),
        error.NoSpaceLeft => std.fmt.allocPrint(gpa, "write_file: no space left on device writing {s}", .{path}),
        else => return null,
    }) catch null;
}

/// Re-apply a file's saved permission bits after a rewrite. edit_file's atomic
/// zigpatch splice — and write_file overwriting an existing file — land the new
/// content on a fresh inode with the default 0644, silently dropping a 0755
/// executable bit; restore it (#179). `prev` is null for a brand-new file (keep
/// the default) or when the pre-write stat failed. Best-effort: a chmod failure
/// never fails the write itself.
pub fn preserveMode(io: Io, path: []const u8, prev: ?Io.Dir.Stat) void {
    const st = prev orelse return;
    Io.Dir.cwd().setFilePermissions(io, path, st.permissions, .{}) catch {};
}

// --- tests ----------------------------------------------------------------

test "verify: an edit that actually landed passes on both routes" {
    const before = "alpha\nbeta\ngamma\n";
    const after = "alpha\nBETA\ngamma\n";
    try std.testing.expectEqual(Verdict.ok, verifyNative(before, after, after));
    try std.testing.expectEqual(Verdict.ok, verifyCompanion(before, after, after, "beta", "BETA"));
}

test "#337: a companion that reports success without writing is caught, not believed" {
    const before = "alpha\nbeta\ngamma\n";
    const expected = "alpha\nBETA\ngamma\n";
    // The file came back byte-identical: the exact shape reported in #337.
    try std.testing.expectEqual(Verdict.unchanged, verifyCompanion(before, before, expected, "beta", "BETA"));
    try std.testing.expectEqual(Verdict.unchanged, verifyNative(before, before, expected));
}

test "verify: a partially applied replace_all is caught" {
    const before = "x\nx\nx\n";
    const expected = "y\ny\ny\n";
    const partial = "y\nx\nx\n"; // one of three occurrences replaced
    try std.testing.expectEqual(Verdict.partial, verifyCompanion(before, partial, expected, "x", "y"));
    // The native route knows the exact bytes, so the same file reads as a mismatch.
    try std.testing.expectEqual(Verdict.mismatch, verifyNative(before, partial, expected));

    // A splice that ADDED new_string without removing old_string produces the
    // right number of new occurrences and is still wrong.
    const appended = "x\ny\n";
    try std.testing.expectEqual(Verdict.stale_old, verifyCompanion("x\n", appended, "y\n", "x", "y"));
}

test "verify: old_string surviving INSIDE new_string is not a false alarm" {
    // Insert-around-existing-text: old ⊂ new, so one copy of old legitimately
    // remains per occurrence replaced. A naive "old must be gone" check would
    // fail every wrap-this-call edit.
    const before = "call(a);\n";
    const new = "guard(); call(a);";
    const after = "guard(); call(a);\n";
    try std.testing.expectEqual(Verdict.ok, verifyCompanion(before, after, after, "call(a);", new));

    // Two occurrences, both wrapped: two survivors are allowed, three are not.
    const before2 = "hit\nhit\n";
    const after2 = "[hit]\n[hit]\n";
    try std.testing.expectEqual(Verdict.ok, verifyCompanion(before2, after2, after2, "hit", "[hit]"));
    // …and a splice that covered only the first site still fails: old_string
    // survives exactly as often as a CORRECT wrap would leave it, so only the
    // new_string tally can tell the two apart.
    const partial2 = "[hit]\nhit\n";
    try std.testing.expectEqual(Verdict.partial, verifyCompanion(before2, partial2, after2, "hit", "[hit]"));
}

test "verify: insertion-only and deletion edits both verify" {
    // Insertion: new_string carries old_string plus ~25 lines of fresh text
    // (#337 repro D — success reported, none of the new identifiers present).
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "anchor();\n");
    for (0..25) |i| try body.print(std.testing.allocator, "    added_{d}();\n", .{i});
    const before = "anchor();\n";
    try std.testing.expectEqual(Verdict.ok, verifyCompanion(before, body.items, body.items, "anchor();\n", body.items));
    // The insertion silently not happening is the failure we care about.
    try std.testing.expectEqual(Verdict.unchanged, verifyCompanion(before, before, body.items, "anchor();\n", body.items));

    // Deletion: new_string is empty, so presence-of-new cannot be the check;
    // absence-of-old is.
    const del_before = "keep\ndrop\nkeep\n";
    const del_after = "keep\nkeep\n";
    try std.testing.expectEqual(Verdict.ok, verifyCompanion(del_before, del_after, del_after, "drop\n", ""));
    try std.testing.expectEqual(Verdict.stale_old, verifyCompanion(del_before, "keep\ndrop\nkeep\n\n", del_after, "drop\n", ""));
}

test "verify: a file that changed into something else entirely is not success" {
    const before = "one\n";
    const expected = "two\n";
    const clobbered = "something a concurrent writer put there\n";
    try std.testing.expectEqual(Verdict.mismatch, verifyNative(before, clobbered, expected));
    try std.testing.expectEqual(Verdict.missing_new, verifyCompanion(before, clobbered, expected, "one", "two"));
}

test "verdictText names the file, refuses the success wording, and demands a re-read" {
    const gpa = std.testing.allocator;
    const msg = try verdictText(gpa, "src/thing.zig", .unchanged, "zigpatch");
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "src/thing.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "did NOT persist") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "zigpatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "replaced") == null); // never the success message
}

/// Minimal ToolCtx for the file-tool tests: no client, no registry, no
/// approvals — applyEdit touches none of them.
pub fn testCtx(client: *std.http.Client) ToolCtx {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .client = client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
}

test "edit_file: a genuine edit lands on disk and the result says it was verified" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "alpha\nbeta\ngamma\n" });

    const rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f.txt", .{&tmp.sub_path});
    defer gpa.free(rel);
    var client: std.http.Client = undefined;

    const out = try applyEdit(testCtx(&client), rel, rel, "beta", "BETA", false);
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "replaced 1 occurrence(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "verified") != null);

    const on_disk = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(4096));
    defer gpa.free(on_disk);
    try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", on_disk);
}

test "#337: a companion that lies about success returns a LOUD error, never the success message" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "alpha\nbeta\ngamma\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = original });
    // A stub zigpatch that prints exactly what the real one prints on success
    // and touches nothing. This is #337 in a bottle.
    try tmp.dir.writeFile(io, .{
        .sub_path = "liar",
        .data =
        \\#!/bin/sh
        \\printf '{"ok":true,"op":"replace_all","occurrences":1,"strategy":"exact"}\n'
        \\exit 0
        \\
        ,
        .flags = .{ .permissions = @enumFromInt(0o755) },
    });

    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(dir);
    const rel = try std.fmt.allocPrint(gpa, "{s}/f.txt", .{dir});
    defer gpa.free(rel);
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPath(io, &real_buf);
    const stub = try std.fmt.allocPrint(gpa, "{s}/liar", .{real_buf[0..real_len]});
    defer gpa.free(stub);

    const saved = companion_bin;
    defer companion_bin = saved;
    companion_bin = stub;

    var client: std.http.Client = undefined;
    const out = try applyEdit(testCtx(&client), rel, rel, "beta", "BETA", false);
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "did NOT persist") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "f.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "replaced") == null);

    // And the harness did NOT quietly repair it behind the lie either: the
    // report has to match the file.
    const on_disk = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(4096));
    defer gpa.free(on_disk);
    try std.testing.expectEqualStrings(original, on_disk);
}

test "#337: two edits to one file in the same turn both survive" {
    if (builtin.os.tag == .windows or builtin.single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "first\nsecond\n" });
    // Widen the read→write window to something a race is reliably observable
    // in: a companion that stalls and then declines pushes the native write
    // 50ms past the read. That window is the real companion-spawn cost dilated,
    // not a fake seam. With the per-path lock deleted this loop fails within a
    // couple of iterations (verified while writing it) — the two calls splice
    // the SAME pre-edit bytes and the later write erases the earlier one, which
    // is #337 repro C, "both report success, only one persists".
    try tmp.dir.writeFile(io, .{
        .sub_path = "slow",
        .data =
        \\#!/bin/sh
        \\/bin/sleep 0.05
        \\exit 1
        \\
        ,
        .flags = .{ .permissions = @enumFromInt(0o755) },
    });
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPath(io, &real_buf);
    const stub = try std.fmt.allocPrint(gpa, "{s}/slow", .{real_buf[0..real_len]});
    defer gpa.free(stub);
    const saved = companion_bin;
    defer companion_bin = saved;
    companion_bin = stub;

    const rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f.txt", .{&tmp.sub_path});
    defer gpa.free(rel);
    var client: std.http.Client = undefined;
    const ctx = testCtx(&client);

    for (0..5) |_| {
        try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "first\nsecond\n" });
        // The same fan-out agent_tools.zig uses for a multi-call assistant turn.
        var a = io.async(applyEdit, .{ ctx, rel, rel, "first", "FIRST", false });
        var b = io.async(applyEdit, .{ ctx, rel, rel, "second", "SECOND", false });
        const out_a = try a.await(io);
        defer gpa.free(out_a.text);
        const out_b = try b.await(io);
        defer gpa.free(out_b.text);
        try std.testing.expect(!out_a.is_error);
        try std.testing.expect(!out_b.is_error);

        // A lost update would leave one of the two originals behind.
        const on_disk = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(4096));
        defer gpa.free(on_disk);
        try std.testing.expectEqualStrings("FIRST\nSECOND\n", on_disk);
    }
}

test "fsErrorText names the tool, path, and failure (#183)" {
    const gpa = std.testing.allocator;

    const nf = fsErrorText(gpa, .read, "src/foo.zig", error.FileNotFound).?;
    defer gpa.free(nf);
    try std.testing.expect(std.mem.indexOf(u8, nf, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, nf, "src/foo.zig") != null);

    const ed = fsErrorText(gpa, .edit, "src/bar.zig", error.FileNotFound).?;
    defer gpa.free(ed);
    try std.testing.expect(std.mem.indexOf(u8, ed, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, ed, "write_file") != null); // points at creation

    const wr = fsErrorText(gpa, .write, "nope/out.txt", error.FileNotFound).?;
    defer gpa.free(wr);
    try std.testing.expect(std.mem.indexOf(u8, wr, "write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, wr, "parent") != null); // distinguishes a missing parent dir

    const perm = fsErrorText(gpa, .edit, "p", error.AccessDenied).?;
    defer gpa.free(perm);
    try std.testing.expect(std.mem.indexOf(u8, perm, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, perm, "permission") != null);

    // Errors outside the usual path/permission set fall through to the generic handler.
    try std.testing.expect(fsErrorText(gpa, .read, "p", error.OutOfMemory) == null);
}
