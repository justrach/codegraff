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

/// graff's effort tag → Interactions `thinking_level`. Only low, medium and
/// high are accepted by every current model: Gemini 3.1 Pro and 3.7/3.8 Flash
/// reject `minimal` with a 400, so the lightest effort maps to `low`.
pub fn thinkingLevel(effort: []const u8) []const u8 {
    if (std.mem.eql(u8, effort, "max") or std.mem.eql(u8, effort, "high")) return "high";
    if (std.mem.eql(u8, effort, "medium")) return "medium";
    return "low";
}

/// The model id sent on the wire. Gemini 3.1 Pro has a variant tuned for
/// harnesses that bring their own tools (it prefers them over shell), at the
/// same price; requests that carry tools use it.
pub fn wireModel(model: []const u8, has_tools: bool) []const u8 {
    if (has_tools and std.mem.eql(u8, model, "gemini-3.1-pro-preview")) return "gemini-3.1-pro-preview-customtools";
    return model;
}

pub fn write(self: *Agent, s: *std.json.Stringify, tools: ?[]const u8, force_tool: bool, stream: bool) !void {
    try s.objectField("system_instruction");
    try s.write(try @import("agent_request_body_responses.zig").schemaAwarePrompt(self));
    const chain = @import("interactions_chain.zig");
    const plan = try chain.plan(self, wireModel(self.provider.model, tools != null));
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
    // Documented as the default, but summaries only stream when asked for;
    // they feed the reasoning panel (title.reasoningDelta).
    try s.objectField("thinking_summaries");
    try s.write("auto");
    // tool_choice lives HERE, not at the top level, and is lowercase:
    // auto | any | none | validated. "required"/"ANY" are rejected outright.
    // `validated` is auto with constrained decoding of the call, so arguments
    // always match the declared schema.
    if (tools != null) {
        try s.objectField("tool_choice");
        try s.write(if (force_tool) "any" else "validated");
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
    // Only levels every current model accepts are ever sent.
    try std.testing.expectEqualStrings("high", thinkingLevel("max"));
    try std.testing.expectEqualStrings("high", thinkingLevel("high"));
    try std.testing.expectEqualStrings("medium", thinkingLevel("medium"));
    try std.testing.expectEqualStrings("low", thinkingLevel("low"));
    // `minimal` 400s on Gemini 3.1 Pro and 3.7/3.8 Flash.
    try std.testing.expectEqualStrings("low", thinkingLevel("minimal"));
    // An unknown tag degrades to a level the endpoint accepts, never to a 400.
    try std.testing.expectEqualStrings("low", thinkingLevel("nonsense"));
}

test "Gemini 3.1 Pro uses its custom-tools variant only when tools ride the request" {
    try std.testing.expectEqualStrings("gemini-3.1-pro-preview-customtools", wireModel("gemini-3.1-pro-preview", true));
    try std.testing.expectEqualStrings("gemini-3.1-pro-preview", wireModel("gemini-3.1-pro-preview", false));
    try std.testing.expectEqualStrings("gemini-3.8-flash", wireModel("gemini-3.8-flash", true));
}
