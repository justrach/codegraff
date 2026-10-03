//! Recovery metadata for a terminal model-auth rejection, not a diagnosis of
//! why renewal failed. Only fixed route/command names cross the client boundary.
const std = @import("std");
const provider = @import("provider.zig");
const util = @import("util.zig");

pub const Recovery = struct {
    kind: []const u8 = "reauth_required",
    provider: []const u8,
    login: struct { command: []const u8, args: []const []const u8 },
};

pub fn forFailure(p: provider.Provider, code: ?[]const u8, message: []const u8) ?Recovery {
    if (p.source != .login) return null;
    // A structured non-auth code wins over incidental auth words in a message.
    // Do not turn quota, server errors or expired request ids into login actions.
    if (code) |c| {
        var auth = false;
        for ([_][]const u8{ "invalid_token", "invalid_api_key", "authentication_error", "token_expired", "subscription_sharing_invalid_user", "subscription_sharing_v2_invalid_user" }) |known| {
            if (std.mem.eql(u8, c, known)) auth = true;
        }
        if (!auth) return null;
    } else {
        var auth = false;
        for ([_][]const u8{ "unauthorized", "authentication token", "authentication failed", "authentication_error", "invalid_api_key", "invalid_token" }) |needle| {
            if (util.indexOfIgnoreCase(message, needle) != null) auth = true;
        }
        if (!auth) return null;
    }
    if (std.mem.eql(u8, p.id, "chatgpt-new")) return .{
        .provider = "chatgpt-new",
        .login = .{ .command = "graff", .args = &.{ "login", "chatgpt-new" } },
    };
    // ADR 0229: `graff login codex` now logs into chatgpt-new, NOT auth.json.
    if (std.mem.eql(u8, p.id, "codex")) return .{
        .provider = "codex",
        .login = .{ .command = "codex", .args = &.{"login"} },
    };
    return null;
}
