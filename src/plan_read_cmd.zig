//! Quote-aware plan-mode read-only shell command validation.
//!
//! Extends `harness_policy` without altering the Lean-modeled `BashPolicy`
//! predicates: admits stdout-only `pdftotext <pdf> -`, read-only `gh` queries,
//! quoted search patterns (e.g. `rg 'a|b'`), and pure read-only pipelines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const policy = @import("harness_policy.zig");

const max_segments = 8;
const max_tokens = 64;
const max_unquoted_bytes = 4096;

const Segment = struct {
    start: usize,
    len: usize,
};

const Parsed = struct {
    buf: [max_unquoted_bytes]u8 = undefined,
    tokens: [max_tokens][]const u8 = undefined,
    token_len: usize = 0,
    segments: [max_segments]Segment = undefined,
    seg_len: usize = 0,

    fn slice(self: *const Parsed, seg_idx: usize) []const []const u8 {
        const seg = self.segments[seg_idx];
        return self.tokens[seg.start .. seg.start + seg.len];
    }
};

fn parse(raw: []const u8, out: *Parsed) bool {
    const cmd = std.mem.trim(u8, raw, " \t");
    if (cmd.len == 0) return false;
    for (cmd) |ch| switch (ch) {
        0, '\n', '\r', '\t' => return false,
        else => {},
    };

    var buf_len: usize = 0;
    var tok_start: usize = 0;
    var tok_active = false;
    var seg_start: usize = 0;
    var in_single = false;
    var in_double = false;
    out.token_len = 0;
    out.seg_len = 0;

    for (cmd) |ch| {
        if (in_single) {
            if (ch == '\'') {
                in_single = false;
            } else {
                if (buf_len >= out.buf.len) return false;
                out.buf[buf_len] = ch;
                buf_len += 1;
            }
            continue;
        }
        if (in_double) {
            switch (ch) {
                '`', '$', '\\' => return false,
                '"' => in_double = false,
                else => {
                    if (buf_len >= out.buf.len) return false;
                    out.buf[buf_len] = ch;
                    buf_len += 1;
                },
            }
            continue;
        }

        switch (ch) {
            ';', '&', '>', '<', '`', '$', '\\', '(', ')' => return false,
            '|' => {
                if (tok_active) {
                    if (out.token_len >= max_tokens) return false;
                    out.tokens[out.token_len] = out.buf[tok_start..buf_len];
                    out.token_len += 1;
                    tok_active = false;
                }
                if (out.token_len == seg_start) return false;
                if (out.seg_len >= max_segments) return false;
                out.segments[out.seg_len] = .{ .start = seg_start, .len = out.token_len - seg_start };
                out.seg_len += 1;
                seg_start = out.token_len;
            },
            ' ' => {
                if (tok_active) {
                    if (out.token_len >= max_tokens) return false;
                    out.tokens[out.token_len] = out.buf[tok_start..buf_len];
                    out.token_len += 1;
                    tok_active = false;
                }
            },
            '\'' => {
                if (!tok_active) {
                    tok_start = buf_len;
                    tok_active = true;
                }
                in_single = true;
            },
            '"' => {
                if (!tok_active) {
                    tok_start = buf_len;
                    tok_active = true;
                }
                in_double = true;
            },
            else => {
                if (!tok_active) {
                    tok_start = buf_len;
                    tok_active = true;
                }
                if (buf_len >= out.buf.len) return false;
                out.buf[buf_len] = ch;
                buf_len += 1;
            },
        }
    }

    if (in_single or in_double) return false;
    if (tok_active) {
        if (out.token_len >= max_tokens) return false;
        out.tokens[out.token_len] = out.buf[tok_start..buf_len];
        out.token_len += 1;
    }
    if (out.token_len == seg_start) return false;
    if (out.seg_len >= max_segments) return false;
    out.segments[out.seg_len] = .{ .start = seg_start, .len = out.token_len - seg_start };
    out.seg_len += 1;
    return out.seg_len > 0;
}

fn inList(needle: []const u8, choices: []const []const u8) bool {
    for (choices) |c| if (std.mem.eql(u8, needle, c)) return true;
    return false;
}

fn isStdoutPdfToTextArgv(argv: []const []const u8) bool {
    if (argv.len < 2 or !std.mem.eql(u8, argv[0], "pdftotext")) return false;
    if (argv.len == 2 and inList(argv[1], &.{ "-v", "-h", "-help", "--help", "-listenc" })) return true;

    const zero_arg_flags = [_][]const u8{
        "-layout",  "-raw",  "-nodiag",      "-htmlmeta", "-tsv",
        "-nopgbrk", "-bbox", "-bbox-layout", "-cropbox",  "-q",
    };
    const one_arg_flags = [_][]const u8{
        "-f",     "-l",   "-r",   "-x",          "-y",   "-W",   "-H",
        "-fixed", "-enc", "-eol", "-colspacing", "-opw", "-upw",
    };

    var pos: [2][]const u8 = undefined;
    var pos_count: usize = 0;
    var past_dash_dash = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const tok = argv[i];
        if (!past_dash_dash and std.mem.eql(u8, tok, "--")) {
            past_dash_dash = true;
            continue;
        }
        if (!past_dash_dash and tok.len > 1 and tok[0] == '-') {
            if (inList(tok, &zero_arg_flags)) continue;
            if (inList(tok, &one_arg_flags)) {
                i += 1;
                if (i >= argv.len) return false;
                continue;
            }
            return false;
        }
        if (pos_count >= pos.len) return false;
        pos[pos_count] = tok;
        pos_count += 1;
    }
    return pos_count == 2 and pos[0].len > 0 and !std.mem.eql(u8, pos[0], "-") and std.mem.eql(u8, pos[1], "-");
}

fn isReadOnlyGhArgv(argv: []const []const u8) bool {
    if (argv.len < 3 or !std.mem.eql(u8, argv[0], "gh")) return false;
    const noun = argv[1];
    const verb = argv[2];
    const ok = (inList(noun, &.{ "issue", "pr", "release" }) and inList(verb, &.{ "list", "view" })) or
        (std.mem.eql(u8, noun, "search") and inList(verb, &.{ "issues", "prs", "code", "commits", "repos" }));
    if (!ok) return false;
    for (argv[3..]) |tok| {
        if (std.mem.eql(u8, tok, "-w") or std.mem.eql(u8, tok, "--web") or std.mem.startsWith(u8, tok, "--web="))
            return false;
    }
    return true;
}

fn segmentAllowed(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const verb = argv[0];
    if (std.mem.eql(u8, verb, "pdftotext")) return isStdoutPdfToTextArgv(argv);
    if (std.mem.eql(u8, verb, "gh")) return isReadOnlyGhArgv(argv);
    if (std.mem.eql(u8, verb, "git")) {
        if (argv.len < 2 or !inList(argv[1], &.{ "status", "diff", "log", "show" })) return false;
        for (argv[2..]) |tok| {
            if (std.mem.eql(u8, tok, "--output") or std.mem.startsWith(u8, tok, "--output=") or std.mem.eql(u8, tok, "--ext-diff"))
                return false;
        }
        return true;
    }
    if (!inList(verb, &.{ "ls", "cat", "head", "tail", "wc", "grep", "rg", "pwd", "which", "file" })) return false;
    if (std.mem.eql(u8, verb, "rg") or std.mem.eql(u8, verb, "grep")) {
        for (argv[1..]) |tok| {
            if (std.mem.eql(u8, tok, "--pre") or std.mem.startsWith(u8, tok, "--pre=")) return false;
        }
    }
    if (std.mem.eql(u8, verb, "file")) {
        for (argv[1..]) |tok| {
            if (std.mem.eql(u8, tok, "-C") or std.mem.eql(u8, tok, "--compile")) return false;
        }
    }
    return true;
}

fn parseAllowed(cmd: []const u8, parsed: *Parsed) bool {
    if (!parse(cmd, parsed)) return false;
    for (0..parsed.seg_len) |i| {
        if (!segmentAllowed(parsed.slice(i))) return false;
    }
    return true;
}

fn hasEscapingToken(parsed: *const Parsed) bool {
    for (0..parsed.seg_len) |i| {
        const argv = parsed.slice(i);
        for (argv[1..]) |tok| {
            if (std.mem.eql(u8, tok, "-")) continue;
            if (policy.flaggedPath(tok) != null) return true;
        }
    }
    return false;
}

pub fn inCwdAllowed(cmd: []const u8) bool {
    var parsed: Parsed = undefined;
    if (!parseAllowed(cmd, &parsed)) return false;
    return !hasEscapingToken(&parsed);
}

pub fn externalAllowed(cmd: []const u8) bool {
    var parsed: Parsed = undefined;
    if (!parseAllowed(cmd, &parsed)) return false;
    return hasEscapingToken(&parsed);
}

pub fn isStdoutPdfToTextInCwd(cmd: []const u8) bool {
    var parsed: Parsed = undefined;
    if (!parseAllowed(cmd, &parsed) or parsed.seg_len != 1) return false;
    if (!std.mem.eql(u8, parsed.slice(0)[0], "pdftotext")) return false;
    return !hasEscapingToken(&parsed);
}

pub fn planReadMatch(cmd: []const u8, roots: []const []const u8) bool {
    var parsed: Parsed = undefined;
    if (!parseAllowed(cmd, &parsed)) return false;
    for (0..parsed.seg_len) |i| {
        const argv = parsed.slice(i);
        for (argv[1..]) |tok| {
            if (std.mem.eql(u8, tok, "-")) continue;
            const p = policy.flaggedPath(tok) orelse continue;
            if (!policy.pathUnderRoots(p, roots)) return false;
        }
    }
    return true;
}

pub fn collectEscapingPaths(gpa: Allocator, cmd: []const u8, roots: *std.ArrayList([]const u8)) !void {
    var parsed: Parsed = undefined;
    if (!parseAllowed(cmd, &parsed)) return;
    for (0..parsed.seg_len) |i| {
        const argv = parsed.slice(i);
        outer: for (argv[1..]) |tok| {
            if (std.mem.eql(u8, tok, "-")) continue;
            const p = policy.flaggedPath(tok) orelse continue;
            var pit = std.mem.tokenizeAny(u8, p, "/\\");
            while (pit.next()) |comp| if (std.mem.eql(u8, comp, "..")) continue :outer;
            for (roots.items) |existing| if (std.mem.eql(u8, existing, p)) continue :outer;
            try roots.append(gpa, try gpa.dupe(u8, p));
        }
    }
}

test "pdftotext stdout-only forms pass in cwd/external while file-writing forms are denied (#1906)" {
    try std.testing.expect(inCwdAllowed("pdftotext sample.pdf -"));
    try std.testing.expect(inCwdAllowed("pdftotext -layout sample.pdf -"));
    try std.testing.expect(inCwdAllowed("pdftotext -f 1 -l 3 -layout -q doc.pdf -"));
    try std.testing.expect(inCwdAllowed("pdftotext -layout sample.pdf - | head -n 40"));
    try std.testing.expect(isStdoutPdfToTextInCwd("pdftotext -layout sample.pdf -"));
    try std.testing.expect(!isStdoutPdfToTextInCwd("pdftotext -layout /tmp/doc.pdf -"));
    try std.testing.expect(externalAllowed("pdftotext -layout \"/tmp/My Doc.pdf\" -"));
    try std.testing.expect(!inCwdAllowed("pdftotext -layout \"/tmp/My Doc.pdf\" -"));

    // Output-writing, missing-dash, redirection, and unsafe pipelines stay denied.
    for ([_][]const u8{
        "pdftotext sample.pdf",
        "pdftotext -layout sample.pdf",
        "pdftotext sample.pdf out.txt",
        "pdftotext -layout sample.pdf out.txt",
        "pdftotext sample.pdf - > out.txt",
        "pdftotext sample.pdf - | tee out.txt",
        "pdftotext sample.pdf - ; rm -rf .",
        "pdftotext -unknown sample.pdf -",
        "pdftotext -f",
    }) |bad| {
        try std.testing.expect(!inCwdAllowed(bad));
        try std.testing.expect(!externalAllowed(bad));
        try std.testing.expect(!isStdoutPdfToTextInCwd(bad));
    }
}

test "quoted alternation, read-only pipelines, and gh read queries pass safely (#1908)" {
    try std.testing.expect(inCwdAllowed("rg 'foo|bar' src/main.zig"));
    try std.testing.expect(inCwdAllowed("gh issue list --search \"foo|bar\" --json number,title"));
    try std.testing.expect(inCwdAllowed("gh pr view 1900 --json title"));
    try std.testing.expect(inCwdAllowed("gh search issues \"orchestrator\" | head -n 20"));

    for ([_][]const u8{
        "gh issue list --web",
        "gh issue list -w",
        "gh issue create --title x",
        "gh pr merge 1",
        "gh api repos/x/y -X POST",
        "rg --pre=sh foo src",
        "git diff --output=patch.txt",
        "rg \"$(whoami)\" src/main.zig",
        "cat src/main.zig || rm -rf .",
    }) |bad| {
        try std.testing.expect(!inCwdAllowed(bad));
        try std.testing.expect(!externalAllowed(bad));
    }
}

test "collectEscapingPaths and planReadMatch handle quoted external paths with spaces" {
    const gpa = std.testing.allocator;
    var roots: std.ArrayList([]const u8) = .empty;
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    const cmd = "pdftotext -layout \"/tmp/docs/My Notes.pdf\" -";
    try collectEscapingPaths(gpa, cmd, &roots);
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings("/tmp/docs/My Notes.pdf", roots.items[0]);
    try std.testing.expect(planReadMatch(cmd, roots.items));
    try std.testing.expect(!planReadMatch("pdftotext -layout \"/tmp/other/Other.pdf\" -", roots.items));

    // Traversal tokens cannot be approved or matched.
    try collectEscapingPaths(gpa, "pdftotext \"/tmp/docs/../../etc/passwd\" -", &roots);
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
}
