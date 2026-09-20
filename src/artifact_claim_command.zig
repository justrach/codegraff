//! Classify claim-protected shell commands without treating inert argument or
//! heredoc text as commands. This is deliberately a command-shape parser, not
//! a general shell evaluator: unknown executables make their remaining words
//! arguments until the next real shell separator.

const std = @import("std");

pub const Kind = enum { commit, pull_request, publication, issue };
pub const Action = enum { commit, push, pr_create, pr_edit, pr_ready, pr_mutation, issue_mutation };

const Token = union(enum) {
    word: []const u8,
    separator,
};

const Lexer = struct {
    input: []const u8,
    index: usize = 0,
    heredoc: ?struct { delimiter: []const u8, strip_tabs: bool } = null,

    fn next(self: *Lexer) ?Token {
        while (self.index < self.input.len) {
            const c = self.input[self.index];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.index += 1;
                continue;
            }
            if (c == '\n') {
                self.index += 1;
                if (self.heredoc != null) self.skipHeredocBody();
                return .separator;
            }
            if (c == ';' or c == '&' or c == '|' or c == '(' or c == ')') {
                self.index += 1;
                if (self.index < self.input.len and self.input[self.index] == c and (c == '&' or c == '|')) self.index += 1;
                return .separator;
            }
            if (c == '<' and self.index + 1 < self.input.len and self.input[self.index + 1] == '<') {
                self.consumeHeredocRedirect();
                continue;
            }
            return .{ .word = self.consumeWord() };
        }
        return null;
    }

    fn consumeWord(self: *Lexer) []const u8 {
        const start = self.index;
        var quote: u8 = 0;
        while (self.index < self.input.len) : (self.index += 1) {
            const c = self.input[self.index];
            if (quote == 0 and (std.ascii.isWhitespace(c) or c == ';' or c == '&' or c == '|' or c == '(' or c == ')')) break;
            if (c == '\\' and quote != '\'') {
                if (self.index + 1 < self.input.len) self.index += 1;
                continue;
            }
            if (quote == 0 and (c == '\'' or c == '"')) {
                quote = c;
            } else if (c == quote) {
                quote = 0;
            }
        }
        return self.input[start..self.index];
    }

    fn consumeHeredocRedirect(self: *Lexer) void {
        self.index += 2;
        var strip_tabs = false;
        if (self.index < self.input.len and self.input[self.index] == '-') {
            strip_tabs = true;
            self.index += 1;
        }
        while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\t')) self.index += 1;
        if (self.index >= self.input.len) return;
        const delimiter = self.consumeWord();
        if (delimiter.len > 0) self.heredoc = .{ .delimiter = delimiter, .strip_tabs = strip_tabs };
    }

    fn skipHeredocBody(self: *Lexer) void {
        const spec = self.heredoc orelse return;
        self.heredoc = null;
        const delimiter = tokenText(spec.delimiter);
        while (self.index <= self.input.len) {
            const line_start = self.index;
            const line_end = std.mem.indexOfScalarPos(u8, self.input, line_start, '\n') orelse self.input.len;
            var line = std.mem.trimEnd(u8, self.input[line_start..line_end], "\r");
            if (spec.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
            self.index = if (line_end < self.input.len) line_end + 1 else self.input.len;
            if (std.mem.eql(u8, line, delimiter) or line_end == self.input.len) return;
        }
    }
};

const State = enum { command, ignore, git, git_value, gh, gh_value, gh_pr, gh_issue, shell, shell_script };

pub fn action(input: []const u8) ?Action {
    return scan(input, null);
}

pub fn has(input: []const u8, wanted: Action) bool {
    return scan(input, wanted) != null;
}

/// First `git -C <path>` directory in `input`, if the path is a literal word.
pub fn gitWorkDir(input: []const u8) ?[]const u8 {
    var lexer = Lexer{ .input = input };
    var state: State = .command;
    var pending_c = false;
    while (lexer.next()) |token| switch (token) {
        .separator => {
            state = .command;
            pending_c = false;
        },
        .word => |raw| {
            const word = tokenText(raw);
            if (word.len == 0) continue;
            if (pending_c) return word;
            switch (state) {
                .command => {
                    if (isAssignment(word)) continue;
                    const exe = std.fs.path.basename(word);
                    if (std.mem.eql(u8, exe, "git")) state = .git else if (isWrapper(exe)) {} else state = .ignore;
                },
                .git_value => state = .git,
                .git => {
                    if (std.mem.eql(u8, word, "-C")) {
                        pending_c = true;
                    } else if (std.mem.eql(u8, word, "-c")) {
                        state = .git_value;
                    } else if (word[0] == '-') {
                        continue;
                    } else {
                        state = .ignore;
                    }
                },
                else => {},
            }
        },
    };
    return null;
}

fn scan(input: []const u8, wanted: ?Action) ?Action {
    var lexer = Lexer{ .input = input };
    var state: State = .command;
    while (lexer.next()) |token| switch (token) {
        .separator => state = .command,
        .word => |raw| {
            const word = tokenText(raw);
            if (word.len == 0) continue;
            switch (state) {
                .command => {
                    if (isAssignment(word)) continue;
                    const exe = std.fs.path.basename(word);
                    if (std.mem.eql(u8, exe, "git")) state = .git else if (std.mem.eql(u8, exe, "gh")) state = .gh else if (isShell(exe)) state = .shell else if (isWrapper(exe)) {} else state = .ignore;
                },
                .ignore => {},
                .git_value => state = .git,
                .git => {
                    if (std.mem.eql(u8, word, "-C") or std.mem.eql(u8, word, "-c")) {
                        state = .git_value;
                    } else if (word[0] == '-') {
                        continue;
                    } else if (std.mem.eql(u8, word, "push")) {
                        if (wanted == null or wanted == .push) return .push;
                        state = .ignore;
                    } else if (isSharedTreeGit(word)) {
                        if (wanted == null or wanted == .commit) return .commit;
                        state = .ignore;
                    } else {
                        state = .ignore;
                    }
                },
                .gh_value => state = .gh,
                .gh => {
                    if (std.mem.eql(u8, word, "-R") or std.mem.eql(u8, word, "--repo")) {
                        state = .gh_value;
                    } else if (word[0] == '-') {
                        continue;
                    } else if (std.mem.eql(u8, word, "pr")) {
                        state = .gh_pr;
                    } else if (std.mem.eql(u8, word, "issue")) {
                        state = .gh_issue;
                    } else {
                        state = .ignore;
                    }
                },
                .gh_pr => {
                    if (word[0] == '-') continue;
                    if (std.mem.eql(u8, word, "create") and (wanted == null or wanted == .pr_create)) return .pr_create;
                    if (std.mem.eql(u8, word, "edit") and (wanted == null or wanted == .pr_edit)) return .pr_edit;
                    if (std.mem.eql(u8, word, "ready") and (wanted == null or wanted == .pr_ready)) return .pr_ready;
                    if (isDiscussionMutation(word) and (wanted == null or wanted == .pr_mutation)) return .pr_mutation;
                    state = .ignore;
                },
                .gh_issue => {
                    if (word[0] == '-') continue;
                    if ((isDiscussionMutation(word) or std.mem.eql(u8, word, "create") or std.mem.eql(u8, word, "edit")) and (wanted == null or wanted == .issue_mutation)) return .issue_mutation;
                    state = .ignore;
                },
                .shell => {
                    if (hasCommandFlag(word)) state = .shell_script;
                },
                .shell_script => {
                    if (scan(tokenText(raw), wanted)) |nested| return nested;
                    state = .ignore;
                },
            }
        },
    };
    return null;
}

pub fn classify(input: []const u8) ?Kind {
    return switch (action(input) orelse return null) {
        .commit => .commit,
        .push => .publication,
        .pr_create, .pr_edit, .pr_ready, .pr_mutation => .pull_request,
        .issue_mutation => .issue,
    };
}

pub fn isPrCreate(input: []const u8) bool {
    return scan(input, .pr_create) != null;
}

pub fn isPrReady(input: []const u8) bool {
    return scan(input, .pr_ready) != null;
}

pub fn isPrEdit(input: []const u8) bool {
    return scan(input, .pr_edit) != null;
}

fn tokenText(raw: []const u8) []const u8 {
    if (raw.len >= 2 and ((raw[0] == '\'' and raw[raw.len - 1] == '\'') or (raw[0] == '"' and raw[raw.len - 1] == '"'))) return raw[1 .. raw.len - 1];
    return raw;
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (eq == 0) return false;
    for (word[0..eq]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn isWrapper(exe: []const u8) bool {
    for ([_][]const u8{ "command", "env", "exec", "nohup", "sudo", "time" }) |name| if (std.mem.eql(u8, exe, name)) return true;
    return false;
}

fn isShell(exe: []const u8) bool {
    for ([_][]const u8{ "bash", "dash", "ksh", "sh", "zsh" }) |name| if (std.mem.eql(u8, exe, name)) return true;
    return false;
}

fn hasCommandFlag(word: []const u8) bool {
    if (word.len < 2 or word[0] != '-') return false;
    return std.mem.indexOfScalar(u8, word[1..], 'c') != null;
}

/// History rewrites and commits, not staging. `git add` is shared-tree
/// presence, not an artifact claim (#1088).
fn isSharedTreeGit(subcommand: []const u8) bool {
    for ([_][]const u8{
        "commit", "reset", "checkout", "switch", "rebase", "merge", "cherry-pick", "revert",
    }) |name| if (std.mem.eql(u8, subcommand, name)) return true;
    return false;
}

test "classify protects actual writes across command boundaries and shell wrappers" {
    try std.testing.expect(classify("git -C repo add -A") == null);
    try std.testing.expectEqual(Kind.commit, classify("git -C repo commit -m wip").?);
    try std.testing.expectEqualStrings("repo", gitWorkDir("git -C repo commit -m wip").?);
    try std.testing.expectEqual(Kind.publication, classify("cd repo && git push origin HEAD").?);
    try std.testing.expectEqual(Kind.pull_request, classify("env gh -R owner/repo pr create --title x").?);
    try std.testing.expectEqual(Kind.pull_request, classify("bash -lc 'gh pr ready 42'").?);
    try std.testing.expect(classify("git status && gh pr checks --watch") == null);
}

test "#879 quoted arguments and read-only heredocs are not executable publications" {
    try std.testing.expect(classify("python3 -c 'print(\"gh pr create --title x\")'") == null);
    try std.testing.expect(classify("grep -n 'git commit -m nope' notes.txt") == null);
    try std.testing.expect(classify("python3 - <<'PY'\nneedle = 'gh pr create --title x'\nprint(needle)\nPY") == null);
    try std.testing.expectEqual(Kind.pull_request, classify("python3 - <<'PY'\nprint('gh pr create')\nPY\ngh pr edit 42 --body fixed").?);
}

fn isDiscussionMutation(word: []const u8) bool {
    for ([_][]const u8{ "close", "reopen", "comment" }) |verb| if (std.mem.eql(u8, word, verb)) return true;
    return false;
}

test "publication predicates inspect later command positions" {
    try std.testing.expect(isPrCreate("git add file && gh pr create"));
    try std.testing.expect(isPrReady("git commit -m message && gh pr ready 12"));
    try std.testing.expect(isPrEdit("git push && gh pr edit 12"));
}

test "release issue and discussion claim coverage is preserved" {
    try std.testing.expectEqual(Kind.issue, classify("gh issue comment 12 --body note").?);
    try std.testing.expectEqual(Kind.pull_request, classify("gh pr close 12").?);
    try std.testing.expect(classify("echo 'gh issue close 12'") == null);
}
