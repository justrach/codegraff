//! Literal GitHub CLI arguments. Dynamic shell expressions cannot be vouched
//! for before execution; publish those separately with explicit arguments.
const std = @import("std");
const A = std.mem.Allocator;
pub const Command = struct {
    argv: []const []const u8,
    verb: []const u8,
    cwd: ?[]const u8 = null,

    pub fn flag(self: Command, long: []const u8, short: []const u8) ?[]const u8 {
        for (self.argv, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, long) or (short.len > 0 and std.mem.eql(u8, arg, short)))
                return if (i + 1 < self.argv.len) self.argv[i + 1] else null;
            if (std.mem.startsWith(u8, arg, long) and arg.len > long.len and arg[long.len] == '=') return arg[long.len + 1 ..];
        }
        return null;
    }
    pub fn draft(self: Command) bool {
        var i: usize = 0;
        while (i < self.argv.len) : (i += 1) {
            const arg = self.argv[i];
            if (takesValue(arg)) {
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--draft") or std.mem.eql(u8, arg, "--draft=true")) return true;
        }
        return false;
    }
    pub fn has(self: Command, flag_name: []const u8) bool {
        var i: usize = 0;
        while (i < self.argv.len) : (i += 1) {
            if (takesValue(self.argv[i])) {
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, self.argv[i], flag_name)) return true;
        }
        return false;
    }
    pub fn selector(self: Command) ?[]const u8 {
        for (self.argv, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, self.verb) and i + 1 < self.argv.len and !std.mem.startsWith(u8, self.argv[i + 1], "-")) return self.argv[i + 1];
        }
        return null;
    }
};

fn takesValue(arg: []const u8) bool {
    for ([_][]const u8{ "--body", "-b", "--body-file", "-F", "--title", "-t", "--head", "-H", "--base", "-B", "--repo", "-R", "--reviewer", "-r", "--assignee", "-a", "--label", "-l", "--milestone", "-m", "--project", "-p", "--template", "-T" }) |flag| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

pub fn parse(a: A, input: []const u8) !Command {
    var args: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {
            if (input[i] == '\n' or input[i] == '\r') return error.CompoundCommand;
        }
        if (i == input.len) break;
        const start = i;
        var word: std.ArrayList(u8) = .empty;
        var quote: u8 = 0;
        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (quote == 0 and std.ascii.isWhitespace(c)) break;
            if (quote == 0 and c == '&') {
                if (i != start or i + 1 >= input.len or input[i + 1] != '&' or (i + 2 < input.len and !std.ascii.isWhitespace(input[i + 2]))) return error.CompoundCommand;
                try word.appendSlice(a, "&&");
                i += 2;
                break;
            }
            if (quote != '\'' and (c == '$' or c == '`')) return error.DynamicCommand;
            if (quote == 0 and std.mem.indexOfScalar(u8, "|;<>\n\r()#", c) != null) return error.CompoundCommand;
            if (c == '\\' and quote != '\'') {
                i += 1;
                if (i == input.len) return error.IncompleteEscape;
                try word.append(a, input[i]);
            } else if (c == quote) {
                quote = 0;
            } else if (quote == 0 and (c == '\'' or c == '"')) {
                quote = c;
            } else try word.append(a, c);
        }
        if (quote != 0) return error.UnclosedQuote;
        try args.append(a, try word.toOwnedSlice(a));
    }
    var t = args.items;
    var cwd: ?[]const u8 = null;
    if (t.len >= 3 and std.mem.eql(u8, t[0], "cd") and std.mem.eql(u8, t[2], "&&")) {
        cwd = t[1];
        t = t[3..];
    }
    if (t.len == 0 or !std.mem.eql(u8, std.fs.path.basename(t[0]), "gh")) return error.UnsupportedCommand;
    for (t) |arg| if (std.mem.eql(u8, arg, "&&") or std.mem.eql(u8, arg, "&")) return error.CompoundCommand;
    var j: usize = 1;
    while (j < t.len) : (j += 1) {
        if (std.mem.eql(u8, t[j], "-R") or std.mem.eql(u8, t[j], "--repo")) {
            j += 1;
            continue;
        }
        if (std.mem.eql(u8, t[j], "pr") and j + 1 < t.len) return .{ .argv = t, .verb = t[j + 1], .cwd = cwd };
        return error.UnsupportedCommand;
    }
    return error.UnsupportedCommand;
}

test "PR arguments keep body flags opaque and resolve repository and target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), "cd 'project space' && gh -R owner/repo pr create --head feature --body 'text --draft' --body-file notes.md");
    try std.testing.expect(!c.draft());
    try std.testing.expectEqualStrings("feature", c.flag("--head", "-H").?);
    try std.testing.expectEqualStrings("text --draft", c.flag("--body", "-b").?);
    try std.testing.expectEqualStrings("notes.md", c.flag("--body-file", "-F").?);
    try std.testing.expectError(error.DynamicCommand, parse(arena.allocator(), "gh pr create --body \"$BODY\""));
    try std.testing.expectError(error.CompoundCommand, parse(arena.allocator(), "git commit -m x; gh pr create"));
    try std.testing.expectError(error.CompoundCommand, parse(arena.allocator(), "gh pr create --body x\necho other"));
    try std.testing.expectError(error.CompoundCommand, parse(arena.allocator(), "gh pr create --body x&echo other"));
}
