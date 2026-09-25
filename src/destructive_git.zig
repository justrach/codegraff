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
//! Flagged per subcommand:
//!   reset     --hard (any target)
//!   clean     -f in any short bundle (-f, -df, -xdf, -d -f) or --force
//!   checkout  -f/--force, a `--` pathspec, an argument no branch name can
//!             spell (`.`, `./src`, `.env`, `:/`, a glob), or any long option
//!             not on the branch-only list below
//!   restore   any pathspec that reaches the working tree (not --staged alone)
//!   switch    --discard-changes, -f/--force
//!   push      --force*, -f, a `+refspec`, --mirror, --delete/-d, `:ref`, --prune
//!   branch    -D, or delete (-d/--delete) with -f/--force
//!   stash     drop, clear
//!
//! Deliberately not flagged: read-only verbs, `checkout -b`/`switch -c`,
//! `restore --staged` (unstaging keeps the working tree), `clean -n`, and
//! `checkout <name>` without a pathspec marker, which cannot be told apart
//! from a branch switch lexically (git itself refuses to overwrite local
//! changes on a switch).

const std = @import("std");

pub fn isDestructiveGit(cmd: []const u8) bool {
    return scan(cmd, 0);
}

/// Nesting bound for quoted / substituted spans scanned as commands.
const max_depth = 4;
/// Longer words are compared on their prefix; flags and subcommands are short.
const word_cap = 512;

fn scan(src: []const u8, depth: u8) bool {
    if (std.mem.indexOf(u8, src, "git") == null) return false;
    var lx: Lexer = .{ .src = src, .depth = depth };
    var seg: Segment = .{};
    while (true) {
        const tok = lx.next();
        if (lx.nested_hit) return true;
        switch (tok) {
            .word => |w| seg.feed(w),
            .sep => {
                if (seg.verdict()) return true;
                seg = .{};
            },
            .end => return seg.verdict(),
        }
    }
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
    /// `<<EOF`) are dropped with their target, so they neither glue onto a
    /// flag nor read as an argument.
    fn next(lx: *Lexer) Tok {
        const s = lx.src;
        while (true) {
            lx.skipBlanks();
            if (lx.i >= s.len) return .end;
            if (isSep(s[lx.i])) {
                while (lx.i < s.len and isSep(s[lx.i])) lx.i += 1;
                return .sep;
            }
            if (isRedirect(s[lx.i])) {
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
                '"' => {
                    var end = lx.i + 1;
                    while (end < s.len and s[end] != '"') : (end += 1) {
                        if (s[end] == '\\') end += 1;
                    }
                    end = @min(end, s.len);
                    lx.quoted(s[lx.i + 1 .. end]);
                    lx.i = end + 1;
                },
                '`' => {
                    const end = std.mem.indexOfScalarPos(u8, s, lx.i + 1, '`') orelse s.len;
                    lx.quoted(s[lx.i + 1 .. end]);
                    lx.i = end + 1;
                },
                '$' => if (lx.i + 1 < s.len and s[lx.i + 1] == '(') {
                    const end = closingParen(s, lx.i + 2);
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
        if (lx.depth < max_depth and scan(inner, lx.depth + 1)) lx.nested_hit = true;
    }

    fn push(lx: *Lexer, c: u8) void {
        if (lx.len < lx.buf.len) {
            lx.buf[lx.len] = c;
            lx.len += 1;
        }
    }
};

/// Index of the `)` closing a `$(` whose body starts at `from` (or s.len).
fn closingParen(s: []const u8, from: usize) usize {
    var nest: usize = 1;
    var i = from;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(' => nest += 1,
            ')' => {
                nest -= 1;
                if (nest == 0) return i;
            },
            else => {},
        }
    }
    return s.len;
}

const Sub = enum { none, reset, clean, checkout, restore, @"switch", push, branch, stash, other };

fn subOf(w: []const u8) Sub {
    inline for (.{ "reset", "clean", "checkout", "restore", "switch", "push", "branch", "stash" }) |name| {
        if (std.mem.eql(u8, w, name)) return @field(Sub, name);
    }
    return .other;
}

fn eqlAny(w: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, w, s)) return true;
    return false;
}

/// `git.exe` too, and any path to it (`/usr/bin/git`).
fn isGitWord(w: []const u8) bool {
    const start = if (std.mem.lastIndexOfAny(u8, w, "/\\")) |i| i + 1 else 0;
    const base = w[start..];
    return std.mem.eql(u8, base, "git") or std.mem.eql(u8, base, "git.exe");
}

/// git's global options that take the next word as their value.
const global_valued = [_][]const u8{ "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--attr-source", "--super-prefix" };

/// checkout long options that only choose or create a branch; every other
/// long option is treated as able to overwrite files (--ours, --theirs,
/// --merge, --no-overlay, --pathspec-from-file, ...).
const checkout_branch_only = [_][]const u8{ "--track", "--no-track", "--detach", "--orphan", "--quiet", "--progress", "--no-progress", "--guess", "--no-guess", "--ignore-other-worktrees" };

/// One `;`/`&&`/`|`-separated command: what the git invocation in it asks for.
const Segment = struct {
    state: enum { seek, globals, args } = .seek,
    skip_next: bool = false,
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
        if (w.len == 0) return; // `""`: nothing to classify
        switch (seg.state) {
            .seek => if (isGitWord(w)) {
                seg.state = .globals;
            },
            .globals => if (w.len > 1 and w[0] == '-') {
                seg.skip_next = eqlAny(w, &global_valued);
            } else {
                seg.sub = subOf(w);
                seg.state = .args;
            },
            .args => if (seg.after_dashdash) {
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
            else => &.{},
        };
        if (name.len == w.len and eqlAny(name, valued)) seg.skip_next = true;
        const is_force = std.mem.eql(u8, name, "--force");
        switch (seg.sub) {
            .reset => seg.hit = seg.hit or std.mem.eql(u8, name, "--hard"),
            .clean => seg.hit = seg.hit or is_force,
            .checkout => seg.hit = seg.hit or !eqlAny(name, &checkout_branch_only),
            .restore => {
                if (std.mem.eql(u8, name, "--staged")) seg.staged = true;
                if (std.mem.eql(u8, name, "--worktree")) seg.worktree = true;
                if (std.mem.eql(u8, name, "--pathspec-from-file")) seg.pathspec = true;
            },
            .@"switch" => seg.hit = seg.hit or is_force or std.mem.eql(u8, name, "--discard-changes"),
            .push => seg.hit = seg.hit or std.mem.startsWith(u8, name, "--force") or eqlAny(name, &.{ "--mirror", "--delete", "--prune" }),
            .branch => {
                if (is_force) seg.force = true;
                if (std.mem.eql(u8, name, "--delete")) seg.delete = true;
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
            else => {},
        }
    }

    /// Anything after `--` is a pathspec.
    fn path(seg: *Segment, w: []const u8) void {
        _ = w;
        if (seg.sub == .restore) seg.pathspec = true;
    }

    fn verdict(seg: *const Segment) bool {
        return switch (seg.sub) {
            .restore => seg.pathspec and (!seg.staged or seg.worktree),
            .branch => seg.hit or (seg.delete and seg.force),
            else => seg.hit,
        };
    }
};

test "#1269: destructive git in every common spelling is flagged" {
    const cases = [_][]const u8{
        // Spellings the substring scan already caught.
        "git reset --hard HEAD~3",
        "git clean -fd",
        "git push --force origin main",
        "git push -f",
        "git branch -D worktree-docs",
        "git checkout -- src/main.zig",
        "git checkout .",
        "git stash clear",
        "git stash drop",
        "git restore .",
        "cd sub && git reset --hard",
        "git -C /repo reset --hard",
        // The spellings it missed.
        "git clean -df",
        "git clean -xdf",
        "git clean -d -f",
        "git clean --force",
        "git restore -- .",
        "git restore :/",
        "git restore src/main.zig",
        "git restore --staged --worktree .",
        "git restore -SW src/a.zig",
        "git restore --source=HEAD~1 src/a.zig",
        "git checkout -f",
        "git checkout --force main",
        "git checkout :/",
        "git checkout .gitignore",
        "git checkout ./src/a.zig",
        "git checkout '*.zig'",
        "git checkout HEAD -- .",
        "git checkout --ours conflicted.txt",
        "git switch --discard-changes main",
        "git switch -f main",
        "git -C dir reset --hard",
        "git reset  --hard",
        "git reset\t--hard origin/main",
        "git -c core.editor=true reset --hard",
        "git --git-dir=.git --work-tree=. reset --hard",
        "git --work-tree /tmp/x clean -f",
        "git -C \"$dir\" reset --hard",
        "git -C $(pwd) reset --hard",
        "git \"reset\" --hard",
        "cd x; git clean -fdx",
        "make || git reset --hard",
        "(cd x && git stash drop stash@{1})",
        "sh -c \"git reset --hard\"",
        "bash -c 'cd x && git clean -fd'",
        "echo $(git reset --hard)",
        "echo `git clean -f`",
        "sudo git push --force",
        "GIT_DIR=x git reset --hard",
        "/usr/bin/git reset --hard",
        "git reset --hard 2>&1 | tail -3",
        "git reset --hard>/dev/null",
        "git 2>/dev/null clean -fd",
        "cat <<EOF | sh\ngit reset --hard\nEOF",
        "git push --force-with-lease",
        "git push -uf origin main",
        "git push origin +main",
        "git push origin --delete old",
        "git push origin :old",
        "git push --mirror backup",
        "git branch --delete --force x",
        "git branch -d -f x",
        "git branch -df x",
        "git reset \\\n  --hard",
    };
    for (cases) |c| std.testing.expect(isDestructiveGit(c)) catch |err| {
        std.debug.print("not flagged: {s}\n", .{c});
        return err;
    };
}

test "#1269: read-only and branch-only git is not flagged" {
    const cases = [_][]const u8{
        "git status",
        "git log --oneline -5",
        "git log -S\"reset --hard\"",
        "git diff HEAD",
        "git show HEAD:src/main.zig",
        "git commit -m wip",
        "git reset --soft HEAD~1",
        "git reset HEAD src/a.zig",
        "git checkout main",
        "git checkout -b feature",
        "git checkout -b feature origin/main",
        "git checkout --track origin/feature",
        "git checkout --detach",
        "git switch main",
        "git switch -c new-branch",
        "git restore --staged f.txt",
        "git restore --staged .",
        "git restore",
        "git clean -n",
        "git clean -nd",
        "git push",
        "git push -u origin feature",
        "git push origin main",
        "git push origin HEAD:refs/heads/x",
        "git branch -d merged-feature",
        "git branch -u origin/main",
        "git stash",
        "git stash pop",
        "git stash list",
        "git stash push -m drop",
        "git restore --staged f.txt 2>/dev/null",
        "git stash list >stashes.txt",
        "git fetch --prune",
        "git -C /repo status",
        "git -c color.ui=always diff",
        "gitk --all",
        "ls -la",
        "echo reset --hard",
        "",
    };
    for (cases) |c| std.testing.expect(!isDestructiveGit(c)) catch |err| {
        std.debug.print("flagged: {s}\n", .{c});
        return err;
    };
}
