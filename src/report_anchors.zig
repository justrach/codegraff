//! The report contract: a finding must anchor to code that exists.
//!
//! The edit contract asks the filesystem whether an implement phase actually
//! edited; this module asks it whether a REPORT actually read. A review or
//! research report's claims cite file paths, and whether those paths resolve
//! against the working tree is checkable with a stat — no model call, no
//! network. That check is what makes `.anchors` a real verifier
//! (failure_evidence.verifierFor): report classes used to fail closed out of
//! the R0d revision rung because nothing automatic could catch a second
//! miss; cited-anchor resolution is that catch, so review/research now earn
//! the cheap revision instead of a judge fleet.
//!
//! The failure predicate is deliberately the HIGH-CONFIDENCE one: a report
//! that cites paths of which NONE resolve is fabricated (or reviewed the
//! wrong tree) and converts to a retryable error. Partially-unresolved
//! citations only append a visible warning (#380's vision-warning pattern):
//! a report may legitimately propose new files next to real ones, and a
//! false error would burn the phase retry the fleet may still need.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Extensions that read as source/config files. A whitelist, not the
/// any-extension rule escalation's scope counter uses, because reports cite
/// dotted code identifiers (`std.debug.print`) and web hosts, and counting
/// those as unresolvable paths would fail honest reviews.
const file_exts = [_][]const u8{
    "zig", "py",   "ts",   "tsx",  "js",  "jsx", "rs",  "go",   "c",   "h",
    "cpp", "hpp",  "cc",   "java", "kt",  "rb",  "php", "cs",   "sh",  "zsh",
    "md",  "json", "toml", "yaml", "yml", "txt", "css", "html", "sql", "swift",
};

fn isPathByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/' or c == '\\';
}

/// Does this token cite a source file? Needs a dot with a whitelisted
/// extension and an alphanumeric before it — `stats.py` and `src/main.zig`
/// yes; `std.mem.eql`, `example.com` and `3.11` no.
pub fn looksLikeSourceFile(tok: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, tok, '.') orelse return false;
    if (dot == 0 or dot + 1 >= tok.len) return false;
    if (!std.ascii.isAlphanumeric(tok[dot - 1])) return false;
    const ext = tok[dot + 1 ..];
    for (file_exts) |known| if (std.ascii.eqlIgnoreCase(ext, known)) return true;
    return false;
}

pub const max_anchors = 32;
pub const max_token = 128;

pub const Check = struct {
    cited: usize = 0,
    resolved: usize = 0,
    /// Up to three unresolved tokens, for the error/warning text.
    samples: [3][]const u8 = .{ "", "", "" },
    n_samples: usize = 0,

    pub fn allFabricated(self: Check) bool {
        return self.cited > 0 and self.resolved == 0;
    }
};

const TokenSet = struct {
    hashes: [max_anchors]u64 = @splat(0),
    n: usize = 0,

    fn seen(self: *TokenSet, tok: []const u8) bool {
        var buf: [max_token]u8 = undefined;
        const m = @min(tok.len, buf.len);
        for (buf[0..m], tok[0..m]) |*d, s| d.* = std.ascii.toLower(s);
        const h = std.hash.Wyhash.hash(0, buf[0..m]);
        for (self.hashes[0..self.n]) |x| if (x == h) return true;
        if (self.n < self.hashes.len) {
            self.hashes[self.n] = h;
            self.n += 1;
        }
        return false;
    }
};

/// Scan `text` for cited source paths and resolve each against the tree.
/// `exists` is the probe (real stat in production, a table in tests), taken
/// as anytype so this stays allocation-free and Io-free at the core.
pub fn scan(text: []const u8, arena: Allocator, exists: anytype) Check {
    var out: Check = .{};
    var set: TokenSet = .{};
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !isPathByte(text[i])) : (i += 1) {}
        const start = i;
        while (i < text.len and isPathByte(text[i])) : (i += 1) {}
        if (i == start) continue;
        const raw = text[start..i];
        // The harness's own inspect links (`.graff/subagents/<id>.md`) ride
        // every subagent result; they are metadata, never the report's citation.
        if (std.mem.startsWith(u8, raw, ".graff/")) continue;
        const tok = std.mem.trim(u8, raw, ".");
        if (tok.len == 0 or tok.len > max_token or !looksLikeSourceFile(tok)) continue;
        if (set.seen(tok)) continue;
        out.cited += 1;
        if (exists.check(tok)) {
            out.resolved += 1;
        } else if (out.n_samples < out.samples.len) {
            out.samples[out.n_samples] = arena.dupe(u8, tok) catch tok;
            out.n_samples += 1;
        }
    }
    return out;
}

/// The production existence probe: stat relative to the worker's cwd.
pub const FsProbe = struct {
    io: Io,
    cwd: ?[]const u8,

    pub fn check(self: FsProbe, path: []const u8) bool {
        var buf: [1024]u8 = undefined;
        const full = if (self.cwd) |c|
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ c, path }) catch return false
        else
            path;
        _ = Io.Dir.cwd().statFile(self.io, full, .{}) catch return false;
        return true;
    }
};

/// Appended to a report-slot phase's briefs, the way contract_brief_note is
/// to an implement phase's: the contract is fair because the worker was told.
pub const anchor_brief_note =
    "Anchor every finding to real code: cite the file paths (and lines) you actually read, exactly " ++
    "as they appear in the tree. The harness resolves cited paths after this phase; a report whose " ++
    "citations do not resolve is rejected. Name a file you are proposing (not one that exists) as " ++
    "`proposed: <path>`.";

/// The retryable failure text for an all-fabricated report. No
/// retry-unsafe marker, so the phase's single retry picks it up.
pub fn fabricatedText(gpa: Allocator, c: Check) []u8 {
    return std.fmt.allocPrint(
        gpa,
        "report anchors unresolved: none of the {d} file path(s) this report cites exist in the " ++
            "working tree (e.g. {s}). A finding must anchor to code that is really there — re-read " ++
            "the tree, cite paths that resolve, and mark genuinely new files as `proposed: <path>`.",
        .{ c.cited, if (c.n_samples > 0) c.samples[0] else "?" },
    ) catch gpa.dupe(u8, "report anchors unresolved: cited paths do not exist in the working tree") catch @constCast("");
}

/// Post-await gate for report-slot phases, shaped like escalation.contractCheck
/// so the call site stays one composed expression. All-fabricated → is_error
/// (the retry re-runs the worker with the failure named); partially
/// unresolved → the report passes with a visible warning appended, which the
/// root cannot mistake for silence.
pub fn anchorCheck(gpa: Allocator, io: Io, cwd: ?[]const u8, report_slot: bool, out: anytype) @TypeOf(out) {
    if (!report_slot or out.is_error) return out;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const c = scan(out.text, arena_state.allocator(), FsProbe{ .io = io, .cwd = cwd });
    if (c.allFabricated()) {
        gpa.free(out.text);
        return .{ .text = fabricatedText(gpa, c), .is_error = true };
    }
    if (c.n_samples > 0) {
        const flagged = std.fmt.allocPrint(gpa, "{s}\n\n[anchor warning: {d} of {d} cited path(s) do not resolve, e.g. {s} — treat findings there as unverified]", .{ out.text, c.cited - c.resolved, c.cited, c.samples[0] }) catch return out;
        gpa.free(out.text);
        return .{ .text = flagged, .is_error = out.is_error };
    }
    return out;
}

/// Which canonical slots carry the report contract. Implement-class slots
/// carry the edit contract instead; synthesize summarizes other workers'
/// findings, so its citations are secondhand and not its own claim to check.
pub fn isReportSlot(slot: []const u8) bool {
    const report_slots = [_][]const u8{ "find", "verify", "sweep", "review" };
    for (report_slots) |s| if (std.mem.eql(u8, slot, s)) return true;
    return false;
}

const TableProbe = struct {
    known: []const []const u8,
    pub fn check(self: TableProbe, path: []const u8) bool {
        for (self.known) |k| if (std.mem.eql(u8, k, path)) return true;
        return false;
    }
};

test "looksLikeSourceFile: files yes; identifiers, hosts and versions no" {
    try std.testing.expect(looksLikeSourceFile("stats.py"));
    try std.testing.expect(looksLikeSourceFile("src/main.zig"));
    try std.testing.expect(looksLikeSourceFile("Welcome.TXT"));
    // The false positives the whitelist exists for.
    try std.testing.expect(!looksLikeSourceFile("std.debug.print"));
    try std.testing.expect(!looksLikeSourceFile("std.mem.eql"));
    try std.testing.expect(!looksLikeSourceFile("example.com"));
    try std.testing.expect(!looksLikeSourceFile("3.11"));
    try std.testing.expect(!looksLikeSourceFile("v0.0.237"));
}

test "scan: dedupes, resolves against the probe, samples the unresolved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const probe = TableProbe{ .known = &.{ "stats.py", "src/main.zig" } };
    // stats.py:24 strips its line suffix; the duplicate counts once.
    const c = scan(
        "The bug is in stats.py:24 (also see stats.py) and src/main.zig; ghost.py has a second one.",
        arena_state.allocator(),
        probe,
    );
    try std.testing.expectEqual(@as(usize, 3), c.cited);
    try std.testing.expectEqual(@as(usize, 2), c.resolved);
    try std.testing.expectEqual(@as(usize, 1), c.n_samples);
    try std.testing.expectEqualStrings("ghost.py", c.samples[0]);
    try std.testing.expect(!c.allFabricated());
    // A report citing ONLY phantoms is fabricated; one citing nothing is not.
    const bad = scan("ghost.py and phantom.zig hold the defect", arena_state.allocator(), probe);
    try std.testing.expect(bad.allFabricated());
    const silent = scan("everything looks fine to me", arena_state.allocator(), probe);
    try std.testing.expect(!silent.allFabricated());
    try std.testing.expectEqual(@as(usize, 0), silent.cited);
}

test "scan: the harness's own inspect link is not a citation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const probe = TableProbe{ .known = &.{"stats.py"} };
    // A citation-free report carrying only the appended inspect link passes
    // instead of burning the phase retry on a fabricated-anchors rejection.
    const clean = scan(
        "no defects found\n[subagent sa-007-abcd · inspect: .graff/subagents/sa-007-abcd.md]",
        arena_state.allocator(),
        probe,
    );
    try std.testing.expectEqual(@as(usize, 0), clean.cited);
    try std.testing.expect(!clean.allFabricated());
    // Nor does the link launder a fabricated report into a partial one.
    const bad = scan(
        "ghost.py holds the defect\n[subagent sa-007-abcd · inspect: .graff/subagents/sa-007-abcd.md]",
        arena_state.allocator(),
        probe,
    );
    try std.testing.expect(bad.allFabricated());
}

test "the contract texts instruct, and the failure stays retry-safe" {
    const gpa = std.testing.allocator;
    var c: Check = .{ .cited = 2, .n_samples = 1 };
    c.samples[0] = "ghost.py";
    const text = fabricatedText(gpa, c);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "ghost.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "re-read") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "retry is NOT safe") == null);
    try std.testing.expect(std.mem.indexOf(u8, anchor_brief_note, "proposed:") != null);
}

test "isReportSlot: report slots carry it, implement/synthesize do not" {
    try std.testing.expect(isReportSlot("find"));
    try std.testing.expect(isReportSlot("verify"));
    try std.testing.expect(isReportSlot("sweep"));
    try std.testing.expect(isReportSlot("review"));
    try std.testing.expect(!isReportSlot("implement"));
    try std.testing.expect(!isReportSlot("build"));
    try std.testing.expect(!isReportSlot("synthesize"));
    try std.testing.expect(!isReportSlot("transform"));
    try std.testing.expect(!isReportSlot(""));
}
