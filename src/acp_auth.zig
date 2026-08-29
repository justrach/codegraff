//! ACP v1 Terminal Auth descriptor (#613). `graff login` is already that
//! flow; this module is the wire shape `initialize` advertises so registry
//! CI (and Zed) can see it.
//!
//! Do not invent Agent Auth. Do not accept a terminal method on
//! `authenticate` — the client re-spawns the binary (ACP RFD).

const std = @import("std");
const Value = std.json.Value;

pub const AuthMethod = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    type: []const u8,
    args: []const []const u8,
};

pub const terminal_login = AuthMethod{
    .id = "graff-login",
    .name = "graff login",
    .description = "Interactive terminal login (codegraff / Codex / Kimi)",
    .type = "terminal",
    .args = &.{"login"},
};

pub const advertised = [_]AuthMethod{terminal_login};

/// v1 clients that can open an interactive terminal set
/// `clientCapabilities.auth.terminal = true`. Missing keys default false;
/// we still advertise (registry CI must see a method) because `graff login`
/// exists whether the client sent the capability or not.
pub fn clientAllowsTerminal(params: ?Value) bool {
    const p = params orelse return false;
    if (p != .object) return false;
    const caps = p.object.get("clientCapabilities") orelse return false;
    if (caps != .object) return false;
    const auth = caps.object.get("auth") orelse return false;
    if (auth != .object) return false;
    const terminal = auth.object.get("terminal") orelse return false;
    return switch (terminal) {
        .bool => |b| b,
        else => false,
    };
}

test "terminal_login is the registry Terminal Auth shape" {
    try std.testing.expectEqualStrings("graff-login", terminal_login.id);
    try std.testing.expectEqualStrings("terminal", terminal_login.type);
    try std.testing.expectEqualStrings("login", terminal_login.args[0]);
}

test "clientAllowsTerminal reads the v1 capability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const yes = try std.json.parseFromSliceLeaky(Value, a,
        \\{"clientCapabilities":{"auth":{"terminal":true}}}
    , .{});
    const no = try std.json.parseFromSliceLeaky(Value, a,
        \\{"clientCapabilities":{"fs":{}}}
    , .{});
    try std.testing.expect(clientAllowsTerminal(yes));
    try std.testing.expect(!clientAllowsTerminal(no));
    try std.testing.expect(!clientAllowsTerminal(null));
}
