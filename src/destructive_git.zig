//! Which shell commands run a work-destroying git subcommand (#1269).
//! `harness_policy.isDestructiveGit` re-exports `isDestructiveGit` below; the
//! approval gate uses it so these never auto-run (not under a blanket `git`
//! allow, not for subagents, and only for the root agent under --yolo).
//!
//! It used to be a substring scan for "reset --hard", "clean -f", ... which
//! missed `git clean -df`, `git -C dir reset --hard`, `reset  --hard` and
//! friends. This is a small shell lexer instead: commands split at `;`, `&`,
//! `|`, newlines and parentheses; quotes and backslashes are removed from
//! words; each segment is read as `[anything] git [global options]
//! <subcommand> <args>`. A quoted span, `$(...)` or backticks that mention
//! git are scanned again as a command of their own, so `sh -c "git reset
//! --hard"` is still caught (and so is the same text inside a commit
//! message: a known false positive, one extra y/n).
//!
//! Flagged per subcommand (a long option also in any unambiguous
//! abbreviation of 3+ letters, as git accepts them: `--har`, `--for`):
//!   reset     --hard (any target)
//!   clean     -f in any short bundle (-f, -df, -xdf, -d -f) or --force
//!   checkout  -f/--force, a `--` pathspec, an argument no branch name can
//!             spell (`.`, `./src`, `.env`, `:/`, a glob), two positionals
//!             (`<tree-ish> <path>`), or any long option not on the
//!             branch-only list below
//!   restore   any pathspec that reaches the working tree (not --staged alone)
//!   switch    --discard-changes, -f/--force
//!   push      --force*, -f, a `+refspec`, --mirror, --delete/-d, `:ref`, --prune
//!   branch    -D, or delete (-d/--delete) with -f/--force
//!   stash     drop, clear
//!   config    setting `alias.<name>` to any of the above (so does a global
//!             `-c alias.<name>=<value>`); `!cmd` values are read as shell
//!
//! Deliberately not flagged: read-only verbs, `checkout -b`/`switch -c`,
//! `restore --staged` (unstaging keeps the working tree), `clean -n`, and
//! `checkout <name>` without a pathspec marker, which cannot be told apart
//! from a branch switch lexically (git itself refuses to overwrite local
//! changes on a switch).

const std = @import("std");

pub fn isDestructiveGit(cmd: []const u8) bool {
    return scan(cmd, 0, .seek);
}

/// Nesting bound for quoted / substituted spans scanned as commands.
const max_depth = 4;
/// Longer words are compared on their prefix; flags and subcommands are short.
const word_cap = 512;

/// `start` is `.globals` when `src` is the argument list of a git
/// invocation (an alias value) rather than a shell command.
fn scan(src: []const u8, depth: u8, start: Segment.State) bool {
    // Fast path for plain text only: quotes and backslashes can spell git
    // without the literal letters (`g''it`, `g\it`).
    if (start == .seek and std.mem.indexOfAny(u8, src, "'\"\\") == null and !mentionsGit(src)) return false;
    var lx: Lexer = .{ .src = src, .depth = depth };
    var seg: Segment = .{ .depth = depth, .state = start };
    while (true) {
        const tok = lx.next();
        if (lx.nested_hit) return true;
        switch (tok) {
            .word => |w| seg.feed(w),
            .sep => {
                if (seg.verdict()) return true;
                seg = .{ .depth = depth };
            },
            .end => return seg.verdict(),
        }
    }
}

fn mentionsGit(src: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= src.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(src[i..][0..3], "git")) return true;
    }
    return false;
}

const Tok = union(enum) { word: []const u8, sep, end };

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn isRedirect(c: u8) bool {
    return c == '<' or c == '>';
}

fn allDigits(w: []const u8) bool {
    for (w) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isSep(c: u8) bool {
    return switch (c) {
        ';', '&', '|', '\n', '(', ')' => true,
        else => false,
    };
}

const Lexer = struct {
    src: []const u8,
    depth: u8,
    i: usize = 0,
    nested_hit: bool = false,
    buf: [word_cap]u8 = undefined,
    len: usize = 0,

    /// The next word or separator. Redirections (`>/dev/null`, `2>&1`,
    /// `&>log`, `<<EOF`) are dropped with their target, so they neither glue
    /// onto a flag nor read as an argument.
    fn next(lx: *Lexer) Tok {
        const s = lx.src;
        while (true) {
            lx.skipBlanks();
            if (lx.i >= s.len) return .end;
            const amp_redirect = s[lx.i] == '&' and lx.i + 1 < s.len and s[lx.i + 1] == '>';
            if (isSep(s[lx.i]) and !amp_redirect) {
                while (lx.i < s.len and isSep(s[lx.i])) lx.i += 1;
                return .sep;
            }
            if (isRedirect(s[lx.i]) or amp_redirect) {
                while (lx.i < s.len and (isRedirect(s[lx.i]) or s[lx.i] == '&' or s[lx.i] == '|')) lx.i += 1;
                lx.skipBlanks();
                if (lx.i < s.len and !isSep(s[lx.i])) _ = lx.word(); // the target
                continue;
            }
            const w = lx.word();
            // An fd number glued to a redirection (`2>`): not an argument.
            if (lx.i < s.len and isRedirect(s[lx.i]) and w.len > 0 and allDigits(w)) continue;
            return .{ .word = w };
        }
    }

    fn skipBlanks(lx: *Lexer) void {
        const s = lx.src;
        while (lx.i < s.len) {
            if (isBlank(s[lx.i])) {
                lx.i += 1;
            } else if (s[lx.i] == '\\' and lx.i + 1 < s.len and s[lx.i + 1] == '\n') {
                lx.i += 2; // line continuation
            } else break;
        }
    }

    fn word(lx: *Lexer) []const u8 {
        const s = lx.src;
        lx.len = 0;
        while (lx.i < s.len) {
            const c = s[lx.i];
            if (isBlank(c) or isSep(c) or isRedirect(c)) break;
            switch (c) {
                '\\' => {
                    if (lx.i + 1 < s.len and s[lx.i + 1] != '\n') lx.push(s[lx.i + 1]);
                    lx.i += 2;
                },
                '\'' => {
                    const end = std.mem.indexOfScalarPos(u8, s, lx.i + 1, '\'') orelse s.len;
                    lx.quoted(s[lx.i + 1 .. end]);
                    lx.i = end + 1;
                },
                '"', '`' => {
                    const end = spanEnd(s, lx.i + 1, c);
                    lx.quoted(s[lx.i + 1 .. end]);
                    lx.i = end + 1;
                },
                '$' => if (lx.i + 1 < s.len and s[lx.i + 1] == '(') {
                    const end = spanEnd(s, lx.i + 2, ')');
                    lx.quoted(s[lx.i + 2 .. end]);
                    lx.i = end + 1;
                } else {
                    lx.push(c);
                    lx.i += 1;
                },
                else => {
                    lx.push(c);
                    lx.i += 1;
                },
            }
        }
        lx.i = @min(lx.i, s.len);
        return lx.buf[0..lx.len];
    }

    /// A quoted or substituted span: its text joins the word, and if it
    /// mentions git it is scanned as a command in its own right.
    fn quoted(lx: *Lexer, inner: []const u8) void {
        for (inner) |c| lx.push(c);
        if (lx.depth < max_depth and scan(inner, lx.depth + 1, .seek)) lx.nested_hit = true;
    }

    fn push(lx: *Lexer, c: u8) void {
        if (lx.len < lx.buf.len) {
            lx.buf[lx.len] = c;
            lx.len += 1;
        }
    }
};

/// Index of the `closer` (`"`, backtick or the `)` of `$(`) ending a span
/// whose body starts at `from`, or s.len. Spans nested inside are skipped
/// whole, so `"$(git -C "$d" reset --hard)"` is one string and a `)` inside
/// quotes does not close a `$(`. Iterative with a fixed nesting stack; past
/// it the rest of the input is the span.
fn spanEnd(s: []const u8, from: usize, closer: u8) usize {
    var stack: [32]u8 = undefined;
    stack[0] = closer;
    var top: usize = 1;
    var i = from;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const in = stack[top - 1];
        if (c == in) {
            top -= 1;
            if (top == 0) return i;
            continue;
        }
        if (c == '\\') {
            i += 1;
            continue;
        }
        const opens: u8 = switch (in) {
            '"' => if (c == '`') '`' else if (c == '$' and i + 1 < s.len and s[i + 1] == '(') ')' else 0,
            ')' => switch (c) {
                '\'' => {
                    i = std.mem.indexOfScalarPos(u8, s, i + 1, '\'') orelse return s.len;
                    continue;
                },
                '"', '`' => c,
                '(' => ')',
                else => 0,
            },
            else => 0, // backticks: only `\` escapes
        };
        if (opens == 0) continue;
        if (top == stack.len) return s.len;
        if (c == '$') i += 1; // past the `(`
        stack[top] = opens;
        top += 1;
    }
    return s.len;
}

const Sub = enum { none, reset, clean, checkout, restore, @"switch", push, branch, stash, config, other };

fn subOf(w: []const u8) Sub {
    inline for (.{ "reset", "clean", "checkout", "restore", "switch", "push", "branch", "stash", "config" }) |name| {
        if (std.mem.eql(u8, w, name)) return @field(Sub, name);
    }
    return .other;
}

fn eqlAny(w: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, w, s)) return true;
    return false;
}

/// Whether long option `name` spells `full`: whole, or cut to 3+ letters
/// after the `--` (git takes any unambiguous prefix; an ambiguous one is an
/// error, so reading it as `full` costs at most a y/n).
fn abbrev(name: []const u8, full: []const u8, min: usize) bool {
    return name.len >= @max(min, 5) and std.mem.startsWith(u8, full, name);
}

fn abbrevAny(name: []const u8, set: []const []const u8) bool {
    for (set) |full| if (abbrev(name, full, 0)) return true;
    return false;
}

/// `git.exe` too, any path to it (`/usr/bin/git`), in any case (`GIT.EXE`).
fn isGitWord(w: []const u8) bool {
    const start = if (std.mem.lastIndexOfAny(u8, w, "/\\")) |i| i + 1 else 0;
    const base = w[start..];
    return std.ascii.eqlIgnoreCase(base, "git") or std.ascii.eqlIgnoreCase(base, "git.exe");
}

/// A config key in the `alias` section (section names are case-blind).
fn isAliasKey(k: []const u8) bool {
    return k.len > "alias.".len and std.ascii.startsWithIgnoreCase(k, "alias.");
}

/// Whether an alias with value `v` runs something destructive: `!cmd` is a
/// shell command, anything else the arguments of a git invocation.
fn aliasRuns(v: []const u8, depth: u8) bool {
    if (depth >= max_depth) return false;
    if (v.len > 0 and v[0] == '!') return scan(v[1..], depth + 1, .seek);
    return scan(v, depth + 1, .globals);
}

/// git's global options that take the next word as their value.
const global_valued = [_][]const u8{ "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--attr-source", "--super-prefix" };

/// checkout long options that only choose or create a branch; every other
/// long option is treated as able to overwrite files (--ours, --theirs,
/// --merge, --no-overlay, --pathspec-from-file, ...).
const checkout_branch_only = [_][]const u8{ "--track", "--no-track", "--detach", "--orphan", "--quiet", "--progress", "--no-progress", "--guess", "--no-guess", "--ignore-other-worktrees" };

/// One `;`/`&&`/`|`-separated command: what the git invocation in it asks for.
const Segment = struct {
    const State = enum { seek, globals, args };

    depth: u8 = 0,
    state: State = .seek,
    skip_next: bool = false,
    cfg_next: bool = false, // the word after a global `-c`
    cfg_key: bool = false, // `config` saw an alias key; its value is next
    sub: Sub = .none,
    after_dashdash: bool = false,
    positionals: usize = 0,
    hit: bool = false, // a flag that is destructive on its own
    force: bool = false,
    delete: bool = false,
    staged: bool = false,
    worktree: bool = false,
    pathspec: bool = false,

    fn feed(seg: *Segment, w: []const u8) void {
        if (seg.skip_next) {
            seg.skip_next = false;
            return;
        }
        if (seg.cfg_next) {
            seg.cfg_next = false;
            const eq = std.mem.indexOfScalar(u8, w, '=') orelse return;
            if (isAliasKey(w[0..eq])) seg.hit = seg.hit or aliasRuns(w[eq + 1 ..], seg.depth);
            return;
        }
        if (w.len == 0) return; // `""`: nothing to classify
        switch (seg.state) {
            .seek => if (isGitWord(w)) {
                seg.state = .globals;
            },
            .globals => if (w.len > 1 and w[0] == '-') {
                if (std.mem.eql(u8, w, "-c")) {
                    seg.cfg_next = true;
                } else seg.skip_next = eqlAny(w, &global_valued);
            } else {
                seg.sub = subOf(w);
                seg.state = .args;
            },
            .args => if (seg.cfg_key) {
                seg.positional(w); // an alias value may start with `-`
            } else if (seg.after_dashdash) {
                seg.path(w);
            } else if (std.mem.eql(u8, w, "--")) {
                seg.after_dashdash = true;
                if (seg.sub == .checkout) seg.hit = true;
            } else if (std.mem.startsWith(u8, w, "--")) {
                seg.long(w);
            } else if (w.len > 1 and w[0] == '-') {
                seg.short(w[1..]);
            } else {
                seg.positional(w);
            },
        }
    }

    fn long(seg: *Segment, w: []const u8) void {
        const name = w[0 .. std.mem.indexOfScalar(u8, w, '=') orelse w.len];
        const valued: []const []const u8 = switch (seg.sub) {
            .restore => &.{"--source"},
            .clean => &.{"--exclude"},
            .push => &.{ "--push-option", "--repo", "--receive-pack", "--exec" },
            .checkout => &.{"--orphan"},
            .@"switch" => &.{ "--orphan", "--create", "--force-create" },
            .config => &.{ "--file", "--blob", "--type", "--default", "--comment", "--value" },
            else => &.{},
        };
        if (name.len == w.len and abbrevAny(name, valued)) seg.skip_next = true;
        const is_force = abbrev(name, "--force", 0);
        switch (seg.sub) {
            .reset => seg.hit = seg.hit or abbrev(name, "--hard", 0),
            .clean => seg.hit = seg.hit or is_force,
            .checkout => seg.hit = seg.hit or !abbrevAny(name, &checkout_branch_only),
            .restore => {
                if (abbrev(name, "--staged", 0)) seg.staged = true;
                if (abbrev(name, "--worktree", 0)) seg.worktree = true;
                // `--pathspec-f` could still be --pathspec-file-nul.
                if (abbrev(name, "--pathspec-from-file", "--pathspec-fr".len)) seg.pathspec = true;
            },
            .@"switch" => seg.hit = seg.hit or is_force or abbrev(name, "--discard-changes", 0),
            .push => seg.hit = seg.hit or is_force or std.mem.startsWith(u8, name, "--force") or
                abbrevAny(name, &.{ "--mirror", "--delete", "--prune" }),
            .branch => {
                if (is_force) seg.force = true;
                if (abbrev(name, "--delete", 0)) seg.delete = true;
            },
            else => {},
        }
    }

    /// A short-option bundle without its dash. A letter that takes a value
    /// ends the bundle: the rest (or the next word) is that value.
    fn short(seg: *Segment, letters: []const u8) void {
        const valued: []const u8 = switch (seg.sub) {
            .clean => "e",
            .restore => "s",
            .push => "o",
            .checkout => "bB",
            .@"switch" => "cC",
            .branch => "u",
            .config => "f",
            else => "",
        };
        for (letters, 0..) |c, i| {
            if (std.mem.indexOfScalar(u8, valued, c) != null) {
                if (i + 1 == letters.len) seg.skip_next = true;
                return;
            }
            switch (seg.sub) {
                .clean, .checkout, .@"switch" => if (c == 'f') {
                    seg.hit = true;
                },
                .restore => {
                    if (c == 'S') seg.staged = true;
                    if (c == 'W') seg.worktree = true;
                },
                .push => if (c == 'f' or c == 'd') {
                    seg.hit = true;
                },
                .branch => {
                    if (c == 'D') seg.hit = true;
                    if (c == 'd') seg.delete = true;
                    if (c == 'f') seg.force = true;
                },
                else => {},
            }
        }
    }

    fn positional(seg: *Segment, w: []const u8) void {
        defer seg.positionals += 1;
        switch (seg.sub) {
            // A ref name never starts with `.` or `:` and never holds a glob
            // character, so these are pathspecs: `.`, `./src`, `.env`, `:/`.
            .checkout => if (w[0] == '.' or w[0] == ':' or std.mem.indexOfAny(u8, w, "*?[") != null) {
                seg.hit = true;
            },
            .restore => seg.pathspec = true,
            .push => if (w[0] == '+' or (w[0] == ':' and w.len > 1)) {
                seg.hit = true; // forced or deleting refspec
            },
            .stash => if (seg.positionals == 0 and (std.mem.eql(u8, w, "drop") or std.mem.eql(u8, w, "clear"))) {
                seg.hit = true;
            },
            .config => if (seg.cfg_key) {
                seg.cfg_key = false;
                seg.hit = seg.hit or aliasRuns(w, seg.depth);
            } else if (isAliasKey(w)) {
                seg.cfg_key = true;
            },
            else => {},
        }
    }

    /// Anything after `--` is a pathspec.
    fn path(seg: *Segment, w: []const u8) void {
        _ = w;
        if (seg.sub == .restore) seg.pathspec = true;
    }

    fn verdict(seg: *const Segment) bool {
        return seg.hit or switch (seg.sub) {
            .restore => seg.pathspec and (!seg.staged or seg.worktree),
            .branch => seg.delete and seg.force,
            // `checkout <tree-ish> <path>` overwrites the path.
            .checkout => seg.positionals >= 2,
            else => false,
        };
    }
};

test {
    _ = @import("destructive_git_tests.zig");
}
