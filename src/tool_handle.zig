//! #440: handles by default. A tool result over `threshold_bytes` never enters
//! the conversation whole. Its bytes are written to `.graff/tool-results/` and
//! what the model gets back is ONE handle: a bounded preview, the path holding
//! the complete result, the byte count, and a one-line shape hint (line count,
//! or the top-level keys of a JSON payload). The model then slices what it
//! needs with read_file/grep/bash over that path — the filesystem as the
//! namespace, bash as the REPL — instead of carrying the payload turn after
//! turn.
//!
//! This SUBSUMES the two-step that used to live in agent_tools.zig
//! (`persistToolResult` + a 2000-char `toolPreviewText`): the bytes were
//! already durable, but the model was told nothing about them beyond a path,
//! so it could not decide what to ask for without re-running the tool.
//!
//! It also OUTRANKS the send-time per-output cap (#193/#196/#409) by
//! construction rather than by coincidence: `effectiveThreshold` pins the
//! tool-time threshold at or below `Provider.perOutputCap()`, so a freshly
//! produced result is always handled HERE, and the send-time cap is left as the
//! only thing it still is — a backstop for history this process did not produce
//! (a session resumed from an older graff, whose stored tool outputs never met
//! this contract).
//!
//! Meta tools never reach this. agent_tools.zig applies it only to the external
//! (execTool) half of a batch, which is where the bytes are.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");

/// Where a handle's bytes live. Run-scoped rather than session-scoped: a
/// subagent has no durable session (that is why the #409 spill skips it) but
/// produces oversized results just the same, and its orchestrator may want to
/// read one.
pub const handles_dir = ".graff/tool-results";

/// THE knob (#440), in bytes, overridable with `GRAFF_TOOL_HANDLE_BYTES`.
/// A tool result at or below this reaches the model exactly as the tool
/// produced it; anything larger comes back as a handle whose preview is bounded
/// by this same number, so one result costs at most one threshold of context
/// whatever its size.
///
/// 16 KiB is ~4k tokens — still a constant, bounded price, but big enough that
/// a typical search result or file read comes back INLINE. That matters more
/// than the context it spends: every handle forces the model into a follow-up
/// read, and a round-trip costs ~5-8s of model latency while the tokens cost
/// cache-read prices on big-window models. Measured on K3 (1M window, 2026-08
/// graff×kimi-cli benchmark): raising 4 KiB → 32 KiB cut runEval/providers
/// wall time ~16% by removing 2-3 handle-chase round-trips per task; 16 KiB
/// keeps half that win while staying safe on 32k-class windows. The caps this
/// contract replaced were not constant: 128 KiB of bash stdout, 64 KiB of
/// codedb output, and up to 136 KiB of a single result at send time.
pub const default_threshold_bytes: usize = 16384;
pub var threshold_bytes: usize = default_threshold_bytes;

/// Ceiling on what one process may leave in `handles_dir`. Every handle is a
/// result that ALREADY exceeded the threshold, so a runaway tool loop is
/// exactly the case that would otherwise fill a disk one oversized result at a
/// time. Over budget the result is truncated with an honest marker instead:
/// a handle is written whole or not at all, since a partial one would make the
/// byte count a lie. `pub var` so a test can shrink it.
pub var run_cap_bytes: usize = 64 * 1024 * 1024;

var g_seq: std.atomic.Value(u64) = .init(0);
var g_used: std.atomic.Value(usize) = .init(0);

pub fn resetForTest() void {
    threshold_bytes = default_threshold_bytes;
    g_seq.store(0, .monotonic);
    g_used.store(0, .monotonic);
}

/// `GRAFF_TOOL_HANDLE_BYTES=<bytes>`. Ignored when unparseable or 0 — a knob
/// that silently disabled the contract would be worse than no knob.
pub fn applyEnv(raw: []const u8) void {
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t"), 10) catch return;
    if (n > 0) threshold_bytes = n;
}

/// The threshold this turn actually uses. `per_output_cap` is
/// `Provider.perOutputCap()` (0 = unknown window, cap disabled).
///
/// This one clamp is what makes #440 a single contract instead of a fourth cap
/// on a stack of three: the tool-time threshold can never sit ABOVE the
/// send-time cap, so a result big enough to trip the send-time cap has always
/// already become a handle, and the send-time path cannot fire on anything this
/// process produced. Without it, a large `GRAFF_TOOL_HANDLE_BYTES` would put
/// the two caps back in series and re-create exactly the layering #440 removes.
pub fn effectiveThreshold(per_output_cap: usize) usize {
    if (per_output_cap == 0) return threshold_bytes;
    return @min(threshold_bytes, per_output_cap);
}

/// Where handle bytes are written. Injected rather than assumed so the tests
/// write into a tmp dir instead of the developer's working tree.
pub const Target = struct {
    io: Io,
    /// The directory `.graff` lives under: the cwd in production.
    dir: Io.Dir,
    /// This run's trace id; it names the handle files.
    run_id: []const u8 = "untraced",
};

/// What the tool result became.
pub const Result = struct {
    /// The model-facing text: the result verbatim below the threshold, or
    /// preview + handle marker above it.
    text: []const u8,
    /// The handle, absolute, or null when the result passed through untouched
    /// (or when the write failed / the run budget is spent).
    path: ?[]const u8,
    /// The FULL size of the tool result, whether or not it became a handle.
    bytes: usize,
};

/// At most this many top-level keys are named in a JSON shape hint; a wide
/// object would otherwise spend the whole preview on its own schema.
const max_named_keys: usize = 12;

/// Longest single key name reproduced in a shape hint.
const max_key_len: usize = 48;

/// Apply the contract to one tool result. Never truncates below the threshold,
/// never claims a handle it did not write.
pub fn forResult(gpa: Allocator, arena: Allocator, target: Target, text: []const u8, threshold: usize) !Result {
    if (text.len <= threshold) return .{ .text = try arena.dupe(u8, text), .path = null, .bytes = text.len };

    // The shape hint is measured from the bytes in hand, never inferred from
    // the tool name: `shapeHint` counts real lines, and only calls a payload
    // JSON after scanning it end to end.
    const shape = shapeHint(gpa, arena, text);
    const path = persist(arena, target, text);
    const marker = markerText(arena, path, text.len, threshold, shape) catch
        return .{ .text = try arena.dupe(u8, util.utf8Prefix(text, threshold)), .path = path, .bytes = text.len };
    // A marker that cannot fit under the threshold replaces the preview rather
    // than growing past it: the pointer matters more than the head.
    if (marker.len + 2 >= threshold) return .{ .text = marker, .path = path, .bytes = text.len };
    const head = util.utf8Prefix(text, threshold - (marker.len + 2));
    return .{
        .text = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ head, marker }),
        .path = path,
        .bytes = text.len,
    };
}

/// #541: the once-per-agent protocol lesson. The marker on every handle
/// already teaches slicing; these are the two clauses that used to ride the
/// STANDING prompt (~225 tokens on every call of every session, mostly
/// buying nothing). agent_tools appends this to the FIRST handle an agent
/// produces — the #445 pattern: guidance delivered when it earns its tokens.
pub const first_note = " [handle protocol, applies to every such handle: never pull a whole handle file back into the conversation — slice ranges — and the file stays readable for the rest of the session.]";

/// The #541 append, pure so the once-per-agent contract is testable without
/// an Io or a live Agent: `shown` is the agent's own flag, flipped exactly
/// when a real handle (not a pass-through, not a budget truncation) first
/// carries the note.
pub fn withFirstNote(arena: Allocator, r: Result, shown: *bool) ![]const u8 {
    if (r.path == null or shown.*) return r.text;
    shown.* = true;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ r.text, first_note });
}

fn handleId(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".txt")) base[0 .. base.len - 4] else base;
}

fn markerText(arena: Allocator, path: ?[]const u8, total: usize, threshold: usize, shape: []const u8) ![]const u8 {
    if (path) |p| return std.fmt.allocPrint(
        arena,
        "[tool result handle: {d} bytes, {s} — handle {s} at {s}. Page it with read_tool_result (offset/limit or query); do not re-run the tool (#440).]",
        .{ total, shape, handleId(p), p },
    );
    return std.fmt.allocPrint(
        arena,
        "[tool result truncated to {d} bytes: {d} bytes total, {s}. No handle could be written, so the rest is gone — narrow the command and run it again (#440).]",
        .{ threshold, total, shape },
    );
}

/// Write `text` under `handles_dir`; the ABSOLUTE path on success. Null — i.e.
/// plain truncation — when the run budget is spent or any part of the write
/// fails. Absolute because a worktree-isolated subagent (#276) runs with a
/// different cwd than the one this file was created under, and a relative path
/// would not open there.
fn persist(arena: Allocator, target: Target, text: []const u8) ?[]const u8 {
    if (!reserve(text.len)) return null;
    // createDirPath is idempotent; `.graff` normally already exists (trace setup).
    target.dir.createDirPath(target.io, handles_dir) catch return refund(text.len);
    // `g_seq` is per-process. A prior graff in this cwd may have left tr_N;
    // exclusive create must skip those instead of dropping the handle.
    var spins: u32 = 0;
    while (spins < 1024) : (spins += 1) {
        const seq = g_seq.fetchAdd(1, .monotonic);
        const rel = std.fmt.allocPrint(arena, "{s}/tr_{d}.txt", .{ handles_dir, seq }) catch return refund(text.len);
        target.dir.writeFile(target.io, .{ .sub_path = rel, .data = text, .flags = .{ .exclusive = true } }) catch |err| {
            if (err == error.PathAlreadyExists) continue;
            return refund(text.len);
        };
        return absolute(target, arena, rel);
    }
    return refund(text.len);
}

/// Resolved through the same dir handle the file was written with, so the path
/// names what actually exists; the relative path is the fallback.
fn absolute(target: Target, arena: Allocator, rel: []const u8) []const u8 {
    var buf: [4096]u8 = undefined;
    if (target.dir.realPathFile(target.io, rel, &buf)) |n| {
        return arena.dupe(u8, buf[0..n]) catch rel;
    } else |_| {}
    return rel;
}

fn reserve(len: usize) bool {
    const prev = g_used.fetchAdd(len, .monotonic);
    if (len > 0 and prev +| len <= run_cap_bytes) return true;
    _ = g_used.fetchSub(len, .monotonic);
    return false;
}

fn refund(len: usize) ?[]const u8 {
    _ = g_used.fetchSub(len, .monotonic);
    return null;
}

/// One line describing the payload's SHAPE, from bytes actually inspected:
/// the top-level keys of a JSON object, the item count of a JSON array, or the
/// line count of anything else. A payload that merely starts with `{` is not
/// called JSON — `jsonShape` scans it to `end_of_document` first — so the hint
/// never sends the model looking for a key that is not there.
pub fn shapeHint(gpa: Allocator, arena: Allocator, text: []const u8) []const u8 {
    if (jsonShape(gpa, arena, text)) |hint| return hint;
    return std.fmt.allocPrint(arena, "{d} lines", .{lineCount(text)}) catch "shape unknown";
}

/// Lines as a reader counts them: a trailing newline terminates the last line
/// rather than starting an empty one.
pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    const nl = std.mem.count(u8, text, "\n");
    return if (text[text.len - 1] == '\n') nl else nl + 1;
}

fn jsonShape(gpa: Allocator, arena: Allocator, text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 2) return null;
    if (trimmed[0] != '{' and trimmed[0] != '[') return null;
    // The scan allocates only key strings and its own depth stack, on scratch
    // that dies here; the hint itself is copied onto `arena` as it is written.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(sa, trimmed);
    defer scanner.deinit();

    var aw: Io.Writer.Allocating = .init(arena);
    switch (scanner.next() catch return null) {
        .object_begin => objectKeys(&scanner, sa, &aw.writer) catch return null,
        .array_begin => arrayItems(&scanner, &aw.writer) catch return null,
        else => return null,
    }
    // Only a document that ends where it should is called JSON.
    if ((scanner.next() catch return null) != .end_of_document) return null;
    return aw.writer.buffered();
}

fn objectKeys(scanner: *std.json.Scanner, sa: Allocator, w: *Io.Writer) !void {
    var total: usize = 0;
    var named: usize = 0;
    var names: Io.Writer.Allocating = .init(sa);
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .object_end => {
                _ = try scanner.next();
                break;
            },
            .string => {},
            else => return error.NotAnObject,
        }
        const key = switch (try scanner.nextAlloc(sa, .alloc_if_needed)) {
            .string, .allocated_string => |s| s,
            else => return error.NotAnObject,
        };
        total += 1;
        if (named < max_named_keys) {
            if (named > 0) try names.writer.writeAll(", ");
            try names.writer.writeAll(util.utf8Prefix(key, max_key_len));
            named += 1;
        }
        try scanner.skipValue();
    }
    if (total == 0) return w.writeAll("JSON object, no top-level keys");
    try w.print("JSON object, top-level keys: {s}", .{names.writer.buffered()});
    if (total > named) try w.print(" (+{d} more)", .{total - named});
}

fn arrayItems(scanner: *std.json.Scanner, w: *Io.Writer) !void {
    var items: usize = 0;
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .array_end => {
                _ = try scanner.next();
                break;
            },
            else => {
                try scanner.skipValue();
                items += 1;
            },
        }
    }
    try w.print("JSON array, {d} items", .{items});
}

// ── tests ──────────────────────────────────────────────────────────────────

fn testTarget(tmp: *std.testing.TmpDir) Target {
    return .{ .io = std.testing.io, .dir = tmp.dir, .run_id = "run" };
}

test "#440: a result at or below the threshold passes through untouched" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    defer resetForTest();

    const small = "wrote 42 bytes to src/main.zig";
    const r = try forResult(std.testing.allocator, a, testTarget(&tmp), small, 4096);
    try std.testing.expectEqualStrings(small, r.text);
    try std.testing.expect(r.path == null);
    try std.testing.expectEqual(@as(usize, small.len), r.bytes);
    // Exactly AT the threshold is still untouched, and nothing was written.
    const exact = try a.alloc(u8, 128);
    @memset(exact, 'x');
    const at = try forResult(std.testing.allocator, a, testTarget(&tmp), exact, 128);
    try std.testing.expectEqualStrings(exact, at.text);
    try std.testing.expect(at.path == null);
    try std.testing.expect(tmp.dir.statFile(std.testing.io, handles_dir, .{}) == error.FileNotFound);
}

test "#440: over the threshold returns preview + handle path + byte count + shape hint, and the handle holds the FULL bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    defer resetForTest();

    // A needle past the preview: only the handle can still hold it. A STRING,
    // not a character — the marker embeds a random tmpdir path (see #409's own
    // test, where a single-character needle failed ~1 run in 5).
    const needle = "NEEDLE440";
    const big = try a.alloc(u8, 40_000);
    @memset(big, 'x');
    for (0..399) |i| big[(i + 1) * 100 - 1] = '\n'; // 400 lines
    @memcpy(big[39_000..][0..needle.len], needle);

    const threshold: usize = 4096;
    const r = try forResult(std.testing.allocator, a, testTarget(&tmp), big, threshold);
    try std.testing.expectEqual(@as(usize, 40_000), r.bytes);
    try std.testing.expect(r.path != null);
    try std.testing.expect(r.text.len <= threshold);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.text));

    // (a) the handle holds the complete original bytes
    const rel = handles_dir ++ "/tr_0.txt";
    const stored = try tmp.dir.readFileAlloc(io, rel, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings(big, stored);
    // (b) the path handed to the model is absolute and names that file
    try std.testing.expect(std.fs.path.isAbsolute(r.path.?));
    try std.testing.expect(std.mem.endsWith(u8, r.path.?, "tr_0.txt"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "handle tr_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, r.path.?) != null);
    // (c) the byte count and the shape hint are both in the marker
    try std.testing.expect(std.mem.indexOf(u8, r.text, "40000 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "400 lines") != null);
    // (d) the payload past the preview left the conversation and lives only on disk
    try std.testing.expect(std.mem.indexOf(u8, r.text, needle) == null);
    try std.testing.expect(std.mem.indexOf(u8, stored, needle) != null);
    // (e) the preview really is the head of the result
    try std.testing.expect(std.mem.startsWith(u8, r.text, big[0..64]));
}

test "#440: the threshold is a knob — the same payload is bounded by whatever it is set to" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    defer resetForTest();

    const payload = try a.alloc(u8, 20_000);
    @memset(payload, 'a');

    const tight = try forResult(std.testing.allocator, a, testTarget(&tmp), payload, 4096);
    const roomy = try forResult(std.testing.allocator, a, testTarget(&tmp), payload, 16_384);
    try std.testing.expect(tight.text.len <= 4096);
    try std.testing.expect(roomy.text.len <= 16_384);
    try std.testing.expect(roomy.text.len > tight.text.len);
    // Raise it past the payload and the handle contract does not apply at all.
    const off = try forResult(std.testing.allocator, a, testTarget(&tmp), payload, 32_768);
    try std.testing.expect(off.path == null);
    try std.testing.expectEqualStrings(payload, off.text);

    // The env knob feeds exactly this number, and refuses to disable the contract.
    applyEnv("8192");
    try std.testing.expectEqual(@as(usize, 8192), threshold_bytes);
    applyEnv("0");
    try std.testing.expectEqual(@as(usize, 8192), threshold_bytes);
    applyEnv("not-a-number");
    try std.testing.expectEqual(@as(usize, 8192), threshold_bytes);
}

test "#440: the tool-time threshold can never sit above the send-time per-output cap" {
    resetForTest();
    defer resetForTest();
    // Unknown window (cap disabled): the knob stands alone.
    try std.testing.expectEqual(default_threshold_bytes, effectiveThreshold(0));
    // Normal case: the knob is far below the cap and wins.
    try std.testing.expectEqual(default_threshold_bytes, effectiveThreshold(135_000));
    // A knob set past the cap is clamped, so the send-time cap can never be the
    // first thing to fire on a result this process produced.
    threshold_bytes = 1 << 30;
    try std.testing.expectEqual(@as(usize, 135_000), effectiveThreshold(135_000));
}

test "#440: shape hints are measured, not guessed — JSON keys, array items, line counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const gpa = std.testing.allocator;

    try std.testing.expectEqualStrings(
        "JSON object, top-level keys: name, version, deps",
        shapeHint(gpa, a, "{\"name\":\"g\",\"version\":2,\"deps\":{\"a\":[1,2,{\"b\":3}]}}"),
    );
    try std.testing.expectEqualStrings("JSON object, no top-level keys", shapeHint(gpa, a, " {}\n"));
    try std.testing.expectEqualStrings("JSON array, 3 items", shapeHint(gpa, a, "[{\"a\":1},[2],\"three\"]"));
    // A payload that only LOOKS like JSON is described as the text it is.
    try std.testing.expectEqualStrings("1 lines", shapeHint(gpa, a, "{\"truncated\": [1, 2"));
    // ...and so is a document with trailing garbage after a valid value.
    try std.testing.expectEqualStrings("1 lines", shapeHint(gpa, a, "{\"a\":1} and then some prose"));
    // Plain text: real line counts, terminator-insensitive.
    try std.testing.expectEqualStrings("3 lines", shapeHint(gpa, a, "one\ntwo\nthree"));
    try std.testing.expectEqualStrings("3 lines", shapeHint(gpa, a, "one\ntwo\nthree\n"));
    try std.testing.expectEqual(@as(usize, 0), lineCount(""));

    // A wide object names a bounded prefix and says how many it left out.
    var wide: Io.Writer.Allocating = .init(a);
    try wide.writer.writeByte('{');
    for (0..20) |i| {
        if (i > 0) try wide.writer.writeByte(',');
        try wide.writer.print("\"k{d}\":{d}", .{ i, i });
    }
    try wide.writer.writeByte('}');
    const hint = shapeHint(gpa, a, wide.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, hint, "k0, k1") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "(+8 more)") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "k12") == null);
}

test "#541: the protocol lesson rides the FIRST handle only — never a pass-through, never twice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var shown = false;

    // A pass-through (below threshold, no handle) neither carries the note
    // nor consumes the session's one showing.
    const small: Result = .{ .text = "plain result", .path = null, .bytes = 12 };
    try std.testing.expectEqualStrings("plain result", try withFirstNote(a, small, &shown));
    try std.testing.expect(!shown);

    // The first real handle gets marker + lesson, and flips the flag.
    const handle: Result = .{ .text = "preview\n\n[tool result handle: ...]", .path = "/tmp/h-0.txt", .bytes = 40_000 };
    const first = try withFirstNote(a, handle, &shown);
    try std.testing.expect(std.mem.startsWith(u8, first, handle.text));
    try std.testing.expect(std.mem.indexOf(u8, first, "handle protocol") != null);
    try std.testing.expect(shown);

    // The second handle is marker-only: the lesson never repeats.
    const second = try withFirstNote(a, handle, &shown);
    try std.testing.expectEqualStrings(handle.text, second);
}

test "#440: the run byte budget bounds the handle dir, and over it the result is truncated honestly" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    const saved = run_cap_bytes;
    defer {
        run_cap_bytes = saved;
        resetForTest();
    }
    run_cap_bytes = 9000;

    const big = try a.alloc(u8, 8192);
    @memset(big, 'x');
    const first = try forResult(std.testing.allocator, a, testTarget(&tmp), big, 1024);
    try std.testing.expect(first.path != null);
    // The second would overrun the budget whole, so it is truncated rather than
    // half-written — and it still reports the real size and shape.
    const second = try forResult(std.testing.allocator, a, testTarget(&tmp), big, 1024);
    try std.testing.expect(second.path == null);
    try std.testing.expectEqual(@as(usize, 8192), second.bytes);
    try std.testing.expect(std.mem.indexOf(u8, second.text, "8192 bytes total") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.text, "No handle could be written") != null);
    try std.testing.expect(second.text.len <= 1024);
    try std.testing.expect(tmp.dir.statFile(io, handles_dir ++ "/tr_1.txt", .{}) == error.FileNotFound);
}

test "#440: a leftover tr_N from a prior process still gets a handle" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    defer resetForTest();

    const big = try a.alloc(u8, 8192);
    @memset(big, 'x');
    const first = try forResult(std.testing.allocator, a, testTarget(&tmp), big, 1024);
    try std.testing.expect(first.path != null);
    try std.testing.expect(std.mem.endsWith(u8, first.path.?, "tr_0.txt"));

    // New process: seq restarts at 0, leftover file stays.
    resetForTest();
    const second = try forResult(std.testing.allocator, a, testTarget(&tmp), big, 1024);
    try std.testing.expect(second.path != null);
    try std.testing.expect(std.mem.endsWith(u8, second.path.?, "tr_1.txt"));
    try std.testing.expect(std.mem.indexOf(u8, second.text, "handle tr_1") != null);
}
