//! #1686: a resumed session keeps the provider's count of its compaction state.
//!
//! The count a full request teaches (opaque_state_usage.zig) lives in
//! process-global slots, so a new process restoring the same history fell back
//! to bytes/16. An 8 MB state counted at ~80k then read as ~508k: the restored
//! meter showed 188% and the next prompt paid for a forced compaction the warm
//! process never needed. The count is saved with the session, scoped to the
//! provider, the model, and the exact state (size plus a digest of every blob),
//! and reapplied on load only when all of them still match. A changed state,
//! a different model, or a missing or malformed record leaves bytes/16 in place.

const std = @import("std");
const Value = std.json.Value;
const context_tokens = @import("context_tokens.zig");
const Provider = @import("provider.zig").Provider;

pub const field = "opaque_state_count";

/// Write the record when this process has counted the history's state.
pub fn write(s: *std.json.Stringify, provider: Provider, history: Value) !void {
    const id = context_tokens.compactionStateIdentity(history);
    const tokens = context_tokens.calibratedState(id.bytes) orelse return;
    var digest_buf: [16]u8 = undefined;
    try s.objectField(field);
    try s.beginObject();
    try s.objectField("provider");
    try s.write(provider.id);
    try s.objectField("model");
    try s.write(provider.model);
    try s.objectField("state_bytes");
    try s.write(id.bytes);
    // Hex: a u64 digest does not round-trip through JSON's signed integers.
    try s.objectField("state_digest");
    try s.write(std.fmt.bufPrint(&digest_buf, "{x:0>16}", .{id.digest}) catch unreachable);
    try s.objectField("tokens");
    try s.write(tokens);
    try s.endObject();
}

/// Reapply a saved count to the restored history. Call after the history is
/// in its final restored form and the session's provider is active.
pub fn restore(provider: Provider, history: Value, session: std.json.ObjectMap) void {
    const saved = recordFrom(session.get(field) orelse return) orelse return;
    if (!std.mem.eql(u8, saved.provider, provider.id) or !std.mem.eql(u8, saved.model, provider.model)) return;
    const id = context_tokens.compactionStateIdentity(history);
    if (id.bytes != saved.state_bytes or id.digest != saved.state_digest) return;
    context_tokens.calibrateState(saved.state_bytes, saved.tokens);
}

const Record = struct {
    provider: []const u8,
    model: []const u8,
    state_bytes: usize,
    state_digest: u64,
    tokens: u64,
};

fn recordFrom(value: Value) ?Record {
    if (value != .object) return null;
    const obj = value.object;
    return .{
        .provider = str(obj.get("provider")) orelse return null,
        .model = str(obj.get("model")) orelse return null,
        .state_bytes = @intCast(positive(obj.get("state_bytes")) orelse return null),
        .state_digest = std.fmt.parseInt(u64, str(obj.get("state_digest")) orelse return null, 16) catch return null,
        .tokens = positive(obj.get("tokens")) orelse return null,
    };
}

fn str(value: ?Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn positive(value: ?Value) ?u64 {
    const v = value orelse return null;
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else null;
}
