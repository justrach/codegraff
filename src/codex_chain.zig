//! Cross-turn `previous_response_id` chaining for the Codex Responses API.
//!
//! The backend holds the conversation behind a response id, so a follow-up
//! request can send `previous_response_id` plus ONLY the new items instead of
//! the whole history. graff already did that inside one turn's tool loop, but
//! runTurn tore the session down at both ends, so every user turn paid a fresh
//! handshake plus a full re-upload of the conversation. With `store:false` the
//! retained encrypted reasoning items are part of that resend, which is why the
//! cost grows per turn rather than staying flat.
//!
//! openai/codex keeps the socket across turns and GUARDS the chain instead of
//! tearing it down: `responses_request_properties_match` compares the request
//! properties, and `get_incremental_items` returns None - meaning full resend -
//! when the new input is not a clean extension of the last one. That guard is
//! what makes chaining safe without enumerating every place history can change.
//! `usable` below is the same idea written with state graff already tracks:
//!
//!   - the history only GREW since we last sent (a /clear, /new or a trim
//!     leaves it shorter, so the server's copy is not a prefix of ours),
//!   - no compaction or emergency trim rewrote it in place (history_rewrites),
//!   - the properties the server anchored the response on are unchanged.
//!
//! The per-request passes that also mutate history - capOversizedToolOutputs
//! and normalizeResponsesHistory - need no guard: both run before an item is
//! first sent and are idempotent afterwards, so neither rewrites a sent prefix.

const std = @import("std");
const Agent = @import("agent.zig").Agent;

/// The live agent's chain-invariant properties. Both the check and the record
/// go through here, so they can never disagree about what was compared.
pub fn propsFor(self: *const Agent) u64 {
    return propsFp(self.provider.model, @tagName(self.reasoning), self.fast, self.toolsJson(), self.systemPrompt());
}

/// GRAFF_CODEX_FULL_RESEND=1 (armed by session_settings.applyEnvKnobs):
/// never chain — every turn sends the full input, opencode's only shape
/// (they carry no previous_response_id at all). Experiment flag for the
/// cache-hit work: chained turns read back ~0 cached tokens, so the delta
/// optimization trades cheap cache reads for full-price re-uploads.
pub var g_force_full_resend = false;

/// May this request chain onto the held response instead of re-anchoring?
pub fn chainUsable(self: *const Agent) bool {
    if (g_force_full_resend) return false;
    return usable(
        self.codex_ws != null,
        self.codex_prev_id != null,
        self.codex_sent_upto,
        self.messages.items.len,
        self.history_rewrites,
        self.codex_chain_rewrites,
        propsFor(self),
        self.codex_props_fp,
    );
}

/// Anchor the chain on a response the server just produced: it now holds every
/// message we have, under these properties and this history generation.
pub fn record(self: *Agent) void {
    self.codex_sent_upto = self.messages.items.len;
    self.codex_chain_rewrites = self.history_rewrites;
    self.codex_props_fp = propsFor(self);
}

/// Fingerprint the request properties the server anchored its response on.
/// Codex compares these explicitly (`responses_request_properties_match`)
/// because chaining onto a response produced under a different model or
/// reasoning effort silently mixes two configurations into one conversation -
/// and `/model` and `/effort` can both change mid-session.
pub fn propsFp(model: []const u8, effort: []const u8, fast: bool, tools: []const u8, instructions: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    // Length-prefixed rather than delimiter-joined: a model or effort name
    // containing the delimiter would otherwise alias onto another pairing.
    for ([_][]const u8{ model, effort, tools, instructions }) |part| {
        h.update(std.mem.asBytes(&part.len));
        h.update(part);
    }
    h.update(&[_]u8{@intFromBool(fast)});
    return h.final();
}

/// Whether the next request may chain (`previous_response_id` + delta input)
/// rather than re-anchoring with the full history. Pure, so the whole decision
/// table is testable without a socket or a provider.
pub fn usable(
    has_ws: bool,
    has_prev_id: bool,
    sent_upto: usize,
    len: usize,
    rewrites: u32,
    chain_rewrites: u32,
    props_now: u64,
    props_then: u64,
) bool {
    if (!has_ws or !has_prev_id) return false;
    // The server holds messages[0..sent_upto]. If our history is now SHORTER
    // than that, it is not an extension of what the server has - /clear and
    // /new reinitialize the array, and a trim can cut below the watermark.
    if (sent_upto > len) return false;
    // compact() and emergencyTrim() rewrite history IN PLACE, so the length
    // check alone would miss them: the array can be the same size or larger
    // while its early items are a summary the server never saw.
    if (rewrites != chain_rewrites) return false;
    return props_now == props_then;
}

test "propsFp: model, effort, fast, tools and instructions each break the chain" {
    const base = propsFp("gpt-5.6", "medium", false, "[]", "sys");
    try std.testing.expectEqual(base, propsFp("gpt-5.6", "medium", false, "[]", "sys")); // stable
    // Each field independently re-anchors: chaining onto a response produced
    // under different settings mixes configurations mid-conversation.
    try std.testing.expect(base != propsFp("gpt-5.6-codex", "medium", false, "[]", "sys"));
    try std.testing.expect(base != propsFp("gpt-5.6", "high", false, "[]", "sys"));
    try std.testing.expect(base != propsFp("gpt-5.6", "medium", true, "[]", "sys")); // /fast
    try std.testing.expect(base != propsFp("gpt-5.6", "medium", false, "[{}]", "sys")); // MCP server connected
    try std.testing.expect(base != propsFp("gpt-5.6", "medium", false, "[]", "sys2")); // /ultracode
    // Length-prefixing: "ab"+"c" must not collide with "a"+"bc".
    try std.testing.expect(propsFp("ab", "c", false, "", "") != propsFp("a", "bc", false, "", ""));
}

test "usable: chains only on a clean extension of what the server holds" {
    // The happy path: socket live, id held, history grew, nothing rewrote it.
    try std.testing.expect(usable(true, true, 4, 6, 0, 0, 7, 7));
    try std.testing.expect(usable(true, true, 4, 4, 0, 0, 7, 7)); // no new items is still an extension

    // No transport or no anchor -> the request must carry the full history.
    try std.testing.expect(!usable(false, true, 4, 6, 0, 0, 7, 7));
    try std.testing.expect(!usable(true, false, 4, 6, 0, 0, 7, 7));

    // /clear and /new reinitialize messages: the server's copy is no longer a
    // prefix of ours, and chaining would silently resurrect the cleared turns.
    try std.testing.expect(!usable(true, true, 4, 0, 0, 0, 7, 7));
    try std.testing.expect(!usable(true, true, 4, 3, 0, 0, 7, 7));

    // compact()/emergencyTrim() rewrite in place, so the length can still look
    // fine while the early items are a summary the server never received.
    try std.testing.expect(!usable(true, true, 4, 9, 1, 0, 7, 7));

    // /model or /effort changed between turns.
    try std.testing.expect(!usable(true, true, 4, 6, 0, 0, 8, 7));
}
