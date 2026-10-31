//! Recovery metadata and wording for a terminal model-auth rejection, not a
//! diagnosis of why renewal failed. Only fixed route/command names cross the
//! client boundary.
//!
//! A provider can hold a sign-in and a metered API key at once (#471), so the
//! text and the metadata name which one was rejected (ADR 0310): a rejected
//! key must not read as "signed out" to a client while the sign-in is fine.
const std = @import("std");
const provider = @import("provider.zig");
const util = @import("util.zig");

pub const Login = struct { command: []const u8, args: []const []const u8 };

pub const Recovery = struct {
    /// "reauth_required" (sign-in seat; carries `login`) or
    /// "api_key_rejected" (metered key seat; no login action).
    kind: []const u8 = "reauth_required",
    provider: []const u8,
    login: ?Login = null,

    /// `login` is omitted, not null, when there is no sign-in to repair.
    pub fn jsonStringify(self: Recovery, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("kind");
        try jws.write(self.kind);
        try jws.objectField("provider");
        try jws.write(self.provider);
        if (self.login) |login| {
            try jws.objectField("login");
            try jws.write(login);
        }
        try jws.endObject();
    }

    /// Only a sign-in action is ACP's "authentication required"; a rejected
    /// key is an ordinary failure that happens to carry data.
    pub fn rpcCode(self: Recovery) i32 {
        const proto = @import("acp_protocol.zig");
        return if (self.login != null) proto.err_auth_required else proto.err_internal;
    }
};

/// A structured non-auth code wins over incidental auth words in a message.
/// Do not turn quota, server errors or expired request ids into login actions.
/// 401 is preserved by the HTTP adapter/envelope parser, not guessed from text.
fn authSignal(code: ?[]const u8, message: []const u8) bool {
    if (code) |c| {
        for ([_][]const u8{ "401", "invalid_token", "invalid_api_key", "authentication_error", "token_expired", "subscription_sharing_invalid_user", "subscription_sharing_v2_invalid_user" }) |known| {
            if (std.mem.eql(u8, c, known)) return true;
        }
        return false;
    }
    for ([_][]const u8{ "unauthorized", "authentication token", "authentication failed", "authentication_error", "invalid_api_key", "invalid_token" }) |needle| {
        if (util.indexOfIgnoreCase(message, needle) != null) return true;
    }
    return false;
}

pub fn forFailure(p: provider.Provider, code: ?[]const u8, message: []const u8) ?Recovery {
    if (p.source != .login or !authSignal(code, message)) return null;
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

/// The terminal ProviderAuthenticationFailed boundary: a sign-in seat keeps
/// forFailure's route-specific reauth action; any other seat ran on a metered
/// key, so the metadata says the key was rejected and offers no login.
pub fn forAuthFault(p: provider.Provider, code: ?[]const u8) ?Recovery {
    if (p.source == .login) return forFailure(p, code, "");
    if (!authSignal(code, "")) return null;
    return .{ .kind = "api_key_rejected", .provider = p.id };
}

/// Words the rejected-key texts must never contain: a client reads each of
/// them as "signed out" and offers a sign-in that cannot help.
pub const signed_out_phrases = [_][]const u8{ "sign in again", "log in again", "not signed in", "unauthorized", "authentication failed", "invalid api key" };

/// The stable phrase in both rejected-key texts.
pub const api_key_rejected_phrase = "API key was rejected";

/// The terminal text for an authentication rejection, naming the credential
/// that failed. `promoted`: the seat is the metered key a spent plan handed
/// over to (credential_failover.promoted).
pub fn failureText(a: std.mem.Allocator, p: provider.Provider, promoted: bool) []const u8 {
    const name = if (provider.specFor(p.id)) |spec| spec.display_name else p.id;
    if (p.source == .login) {
        const login: Login = if (forFailure(p, "401", "")) |r| r.login.? else .{ .command = "graff", .args = &.{ "login", p.id } };
        const args = std.mem.join(a, " ", login.args) catch return "provider sign-in was rejected: sign in again";
        return std.fmt.allocPrint(a, "{s} sign-in was rejected: sign in again ({s} {s})", .{ name, login.command, args }) catch
            "provider sign-in was rejected: sign in again";
    }
    // A Console token past expiry that `ant` cannot renew: name that, not "key".
    if (std.mem.eql(u8, p.id, "anthropic") and p.source == .profile and @import("anthropic_profile.zig").expired()) return if (promoted)
        "Anthropic plan is out of usage, and the fallback Console sign-in has expired: run `graff login console` again, or wait for the plan to reset. Your sign-in is not affected."
    else
        "Anthropic Console sign-in has expired: run `graff login console` again. Your sign-in is not affected.";
    if (promoted) return std.fmt.allocPrint(
        a,
        "{s} plan is out of usage, and the fallback " ++ api_key_rejected_phrase ++ " ({s}): replace or remove the key, or wait for the plan to reset.",
        .{ name, p.source.label() },
    ) catch "provider plan is out of usage, and the fallback " ++ api_key_rejected_phrase ++ ": replace or remove the key, or wait for the plan to reset.";
    return std.fmt.allocPrint(
        a,
        "{s} " ++ api_key_rejected_phrase ++ " ({s}): replace or remove the key. Your sign-in is not affected.",
        .{ name, p.source.label() },
    ) catch "provider " ++ api_key_rejected_phrase ++ ": replace or remove the key. Your sign-in is not affected.";
}

fn seat(id: []const u8, source: provider.Keys.CredentialSource) provider.Provider {
    return .{ .id = id, .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "m", .context = 1000, .source = source };
}

fn expectNoSignedOutPhrase(text: []const u8) !void {
    for (signed_out_phrases) |phrase| try std.testing.expect(util.indexOfIgnoreCase(text, phrase) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, api_key_rejected_phrase) != null);
}

test "auth failure text names the rejected credential: sign-in, key, promoted key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "Anthropic sign-in was rejected: sign in again (graff login anthropic)",
        failureText(a, seat("anthropic", .login), false),
    );
    try std.testing.expectEqualStrings(
        "ChatGPT plan (new sign-in) sign-in was rejected: sign in again (graff login chatgpt-new)",
        failureText(a, seat("chatgpt-new", .login), false),
    );
    try std.testing.expectEqualStrings(
        "Codex (ChatGPT) sign-in was rejected: sign in again (codex login)",
        failureText(a, seat("codex", .login), false),
    );
    const key = failureText(a, seat("anthropic", .profile), false);
    try std.testing.expectEqualStrings("Anthropic API key was rejected (Console profile): replace or remove the key. Your sign-in is not affected.", key);
    try expectNoSignedOutPhrase(key);
    try expectNoSignedOutPhrase(failureText(a, seat("openai", .environment), false));
    try expectNoSignedOutPhrase(failureText(a, seat("xai", .stored), false));
    const handed = failureText(a, seat("anthropic", .profile), true);
    try std.testing.expectEqualStrings("Anthropic plan is out of usage, and the fallback API key was rejected (Console profile): replace or remove the key, or wait for the plan to reset.", handed);
    try expectNoSignedOutPhrase(handed);
    // Only the sign-in text keeps the words existing clients read as signed out.
    try std.testing.expect(std.mem.indexOf(u8, failureText(a, seat("kimi", .login), false), "sign in again") != null);
}

test "api_key_rejected recovery: metered seats only, no login, internal error code" {
    const r = forAuthFault(seat("anthropic", .profile), "401").?;
    try std.testing.expectEqualStrings("api_key_rejected", r.kind);
    try std.testing.expectEqualStrings("anthropic", r.provider);
    try std.testing.expect(r.login == null);
    try std.testing.expectEqual(@import("acp_protocol.zig").err_internal, r.rpcCode());
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.write(r);
    try std.testing.expectEqualStrings("{\"kind\":\"api_key_rejected\",\"provider\":\"anthropic\"}", out.writer.buffered());
    // A structured non-auth code still vetoes the metadata.
    try std.testing.expect(forAuthFault(seat("openai", .environment), "403") == null);
    try std.testing.expect(forAuthFault(seat("openai", .environment), "authentication_error") != null);
    // A sign-in seat is unchanged: route-specific reauth, or nothing.
    const reauth = forAuthFault(seat("chatgpt-new", .login), "401").?;
    try std.testing.expectEqualStrings("reauth_required", reauth.kind);
    try std.testing.expectEqual(@import("acp_protocol.zig").err_auth_required, reauth.rpcCode());
    try std.testing.expect(forAuthFault(seat("anthropic", .login), "401") == null);
}
