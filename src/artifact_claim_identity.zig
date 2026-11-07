//! The PR a command names before any run-time text (#1340).
//!
//! A body built with `$(...)` makes the whole command unparseable for the
//! GitHub lookup, but a PR number, `--head`, or `--repo` written ahead of it
//! is still literal. Words after the first dynamic word or shell separator
//! are never read: only the shell knows where they begin and end.

const std = @import("std");
const pr_command = @import("pr_command.zig");
const target_mod = @import("artifact_claim_target.zig");
const Target = target_mod.Target;

/// The literal PR number, the `--head` branch of a create, and `--repo`.
/// Anything not written literally stays unknown (an empty key, a null branch).
pub fn target(a: std.mem.Allocator, cmd: []const u8) Target {
    var t: Target = .{ .kind = .pull_request, .key = "" };
    const w = literalPrefix(a, cmd);
    if (w.len < 3 or !std.mem.eql(u8, std.fs.path.basename(w[0]), "gh")) return t;
    var i: usize = 1;
    while (i < w.len and !std.mem.eql(u8, w[i], "pr")) : (i += 1) {
        if (std.mem.startsWith(u8, w[i], "--repo=")) {
            t.repo = w[i][7..];
        } else if (std.mem.eql(u8, w[i], "-R") or std.mem.eql(u8, w[i], "--repo")) {
            i += 1;
            if (i < w.len) t.repo = w[i];
        } else return t;
    }
    if (i + 1 >= w.len) return t;
    const create = std.mem.eql(u8, w[i + 1], "create");
    var head: ?[]const u8 = null;
    var selector: ?[]const u8 = null;
    // An unknown option may take the next word as its value.
    var positional = true;
    i += 2;
    while (i < w.len) : (i += 1) {
        const arg = w[i];
        if (pr_command.takesValue(arg)) {
            i += 1;
            if (i >= w.len) break;
            if (std.mem.eql(u8, arg, "--head") or std.mem.eql(u8, arg, "-H")) head = w[i];
            if (std.mem.eql(u8, arg, "--repo") or std.mem.eql(u8, arg, "-R")) t.repo = w[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--head=")) {
            head = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--repo=")) {
            t.repo = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            if (!pr_command.isSwitch(arg) and std.mem.indexOfScalar(u8, arg, '=') == null) positional = false;
        } else if (selector != null or !positional) {
            selector = null;
            positional = false;
        } else selector = arg;
    }
    if (create) {
        const branch = target_mod.unqualifiedHead(head orelse return t);
        if (branch.len > 0) t.branch = branch;
        return t;
    }
    const number = selector orelse return t;
    for (number) |c| if (!std.ascii.isDigit(c)) return t;
    t.key = number;
    return t;
}

/// Unquoted words up to the first dynamic word or shell separator. A leading
/// literal `cd DIR &&` is skipped, as `pr_command.literal` does.
fn literalPrefix(a: std.mem.Allocator, cmd: []const u8) []const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < cmd.len) {
            if (cmd[i] == ' ' or cmd[i] == '\t') {
                i += 1;
            } else if (cmd[i] == '\\' and i + 1 < cmd.len and cmd[i + 1] == '\n') {
                i += 2; // line continuation
            } else break;
        }
        if (i == cmd.len) return words.items;
        if (std.mem.startsWith(u8, cmd[i..], "&&") and words.items.len == 2 and std.mem.eql(u8, words.items[0], "cd")) {
            words.clearRetainingCapacity();
            i += 2;
            continue;
        }
        var word: std.ArrayList(u8) = .empty;
        var quote: u8 = 0;
        while (i < cmd.len) : (i += 1) {
            const c = cmd[i];
            if (quote == 0 and (c == ' ' or c == '\t')) break;
            if (quote == 0 and c == '\\' and i + 1 < cmd.len and cmd[i + 1] == '\n') break;
            if (quote != '\'' and (c == '$' or c == '`')) return words.items;
            if (quote == 0 and std.mem.indexOfScalar(u8, "|;&<>()#\n\r", c) != null) return words.items;
            if (c == '\\' and quote != '\'') {
                i += 1;
                if (i == cmd.len) return words.items;
                word.append(a, cmd[i]) catch return words.items;
            } else if (c == quote) {
                quote = 0;
            } else if (quote == 0 and (c == '\'' or c == '"')) {
                quote = c;
            } else word.append(a, c) catch return words.items;
        }
        if (quote != 0) return words.items;
        words.append(a, word.items) catch return words.items;
    }
}

test "#1340 the PR number, head, and repo before a dynamic body are literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edit = target(a, "cd '../my tree' && gh pr edit 42 --repo owner/repo --body \"$(cat notes.md)\"");
    try std.testing.expectEqualStrings("42", edit.key);
    try std.testing.expectEqualStrings("owner/repo", edit.repo.?);
    const create = target(a, "gh pr create --repo owner/repo --base main --head me:feat/x --title 'Fix (it)' --body \"$(cat <<'EOF'\nbody\nEOF\n)\"");
    try std.testing.expectEqualStrings("", create.key);
    try std.testing.expectEqualStrings("feat/x", create.branch.?);
    try std.testing.expectEqualStrings("7", target(a, "gh -R owner/repo pr ready \\\n 7").key);
    try std.testing.expectEqualStrings("7", target(a, "gh pr comment 7 --edit-last --body x").key);
}

test "#1340 run-time or ambiguous words never become the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "gh pr edit --body \"$(cat notes.md)\" 42",
        "gh pr edit $PR --body x",
        "gh pr edit --unknown 42",
        "gh pr edit 42 43",
        "gh pr edit feature --body x",
        "git log && gh pr edit 42",
        "bash -lc 'gh pr ready 42'",
    }) |cmd| try std.testing.expectEqualStrings("", target(a, cmd).key);
    try std.testing.expect(target(a, "gh pr create --body \"$(cat b)\" --head feat/x").branch == null);
    try std.testing.expect(target(a, "gh pr edit 42 --head feat/x").branch == null);
}
