//! Bounded literal targets; unknown shell forms retain conservative checks.
const std = @import("std");
const claims = @import("artifact_claim.zig");

pub const Target = struct { kind: claims.Kind, key: []const u8 };

pub fn explicit(cmd: []const u8, kind: claims.Kind) ?Target {
    // Do not infer one target for a compound command.
    if (std.mem.indexOfAny(u8, cmd, ";|&`$\n\"'\\*?{}") != null) return null;
    if (!std.mem.startsWith(u8, cmd, "gh pr ") and !std.mem.startsWith(u8, cmd, "gh issue ")) return null;
    var words = std.mem.tokenizeAny(u8, cmd, " \t\r\"'");
    var previous: []const u8 = "";
    var object = false;
    var action = false;
    while (words.next()) |word| {
        if (std.mem.eql(u8, previous, "--head") or std.mem.eql(u8, previous, "-H")) return .{ .kind = .branch, .key = word };
        if (std.mem.startsWith(u8, word, "--head=")) return .{ .kind = .branch, .key = word[7..] };
        if (action) return if (!std.mem.startsWith(u8, word, "-")) .{ .kind = kind, .key = word } else null;
        if (object and (std.mem.eql(u8, word, "edit") or std.mem.eql(u8, word, "ready") or std.mem.eql(u8, word, "close") or std.mem.eql(u8, word, "reopen") or std.mem.eql(u8, word, "comment"))) action = true;
        if ((kind == .issue and std.mem.eql(u8, word, "issue")) or (kind == .pull_request and std.mem.eql(u8, word, "pr"))) object = true;
        previous = word;
    }
    return null;
}
