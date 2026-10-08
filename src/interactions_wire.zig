//! Google's Interactions API request body — the wire Gemini launches on.
//!
//! One POST creates one Interaction. Unlike chat messages or Responses items,
//! its history is an ordered list of execution STEPS:
//!
//!   {"type":"user_input","content":"…"}
//!   {"type":"thought","signature":"…"}          (opaque; echo it back verbatim)
//!   {"type":"model_output","content":[{"type":"text","text":"…"}]}
//!   {"type":"function_call","id":"call_1","name":"bash","arguments":{…}}
//!   {"type":"function_result","call_id":"call_1","name":"bash",
//!    "result":[{"type":"text","text":"…"}]}
//!
//! Two shapes the endpoint enforces and every other wire does not:
//!   - `arguments` is a JSON OBJECT, not a string of JSON.
//!   - unknown fields fail the WHOLE request ("Unknown parameter 'strict' at
//!     'tools[0]'"), so nothing generic may be sprayed into this body.
//!
//! graff's own history stays authoritative. The server-side copy is used only
//! while it matches: a request continues the last stored Interaction with
//! `previous_interaction_id` and only the new steps when interactions_chain.zig
//! proves graff's history extends it, and replays every step otherwise.

const std = @import("std");

const Agent = @import("agent.zig").Agent;
const serde = @import("serde.zig");

/// graff's effort tag → Interactions `thinking_level`. The endpoint names its
/// own accepted set in the rejection: high, low, medium, minimal, none.
pub fn thinkingLevel(effort: []const u8) []const u8 {
    if (std.mem.eql(u8, effort, "max") or std.mem.eql(u8, effort, "high")) return "high";
    if (std.mem.eql(u8, effort, "medium")) return "medium";
    if (std.mem.eql(u8, effort, "minimal") or std.mem.eql(u8, effort, "none")) return "minimal";
    return "low";
}

pub fn write(self: *Agent, s: *std.json.Stringify, tools: ?[]const u8, force_tool: bool, stream: bool) !void {
    try s.objectField("system_instruction");
    try s.write(try @import("agent_request_body_responses.zig").schemaAwarePrompt(self));
    const chain = @import("interactions_chain.zig");
    const plan = try chain.plan(self);
    // Stored by default (the field's default is true) so the next request can
    // continue this one; GRAFF_INTERACTIONS_STORE=0 keeps nothing server-side.
    if (!chain.g_store) {
        try s.objectField("store");
        try s.write(false);
    }
    if (plan.prev_id) |id| {
        try s.objectField("previous_interaction_id");
        try s.write(id);
    }
    try s.objectField("generation_config");
    try s.beginObject();
    try s.objectField("thinking_level");
    try s.write(thinkingLevel(@tagName(self.reasoning)));
    // tool_choice lives HERE, not at the top level, and its enum is lowercase:
    // auto | any | none. "required"/"ANY" are both rejected outright.
    if (tools != null) {
        try s.objectField("tool_choice");
        try s.write(if (force_tool) "any" else "auto");
    }
    try s.endObject();
    if (tools) |t| {
        try s.objectField("tools");
        try serde.writeOpenAITools(s, self.scratchAlloc(), t);
    }
    try s.objectField("input");
    try s.beginArray();
    for (self.messages.items[plan.from..]) |m| try @import("session_wake.zig").writeWire(s, m);
    try s.endArray();
    if (stream) {
        try s.objectField("stream");
        try s.write(true);
    }
}

test "thinking_level maps graff's efforts onto the accepted set" {
    // The set is the endpoint's own: "Valid values are: high, low, medium,
    // minimal, none" — anything else 400s the request.
    try std.testing.expectEqualStrings("high", thinkingLevel("max"));
    try std.testing.expectEqualStrings("high", thinkingLevel("high"));
    try std.testing.expectEqualStrings("medium", thinkingLevel("medium"));
    try std.testing.expectEqualStrings("low", thinkingLevel("low"));
    try std.testing.expectEqualStrings("minimal", thinkingLevel("minimal"));
    // An unknown tag degrades to a level the endpoint accepts, never to a 400.
    try std.testing.expectEqualStrings("low", thinkingLevel("nonsense"));
}
