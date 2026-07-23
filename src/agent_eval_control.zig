//! Tool-batch policy for the eval-driven predict -> verify -> repair loop.

const std = @import("std");
const ToolCall = @import("tools.zig").ToolCall;
const isMetaName = @import("schema.zig").isMetaName;
const companionReadOnly = @import("skills.zig").companionReadOnly;

pub const verifier_boundary =
    "eval is a verifier boundary and must run alone; this tool was not executed";
pub const verifier_hard_stop =
    "VERIFIER RED: the committed plan was dropped. Start a repair turn, make one focused repair, then rerun eval before completion.";

pub fn evalCallIndex(calls: []const ToolCall) ?usize {
    for (calls, 0..) |call, index| {
        if (std.mem.eql(u8, call.name, "eval")) return index;
    }
    return null;
}

pub fn shouldStopAfterBatch(calls: []const ToolCall, repair_pending: bool) bool {
    return repair_pending and evalCallIndex(calls) != null;
}

pub fn toolInvalidatesEval(call: ToolCall) bool {
    if (isMetaName(call.name)) return false;
    if (std.mem.eql(u8, call.name, "read_file") or
        std.mem.eql(u8, call.name, "codedb") or
        std.mem.eql(u8, call.name, "bash_output") or
        std.mem.eql(u8, call.name, "bash_kill"))
    {
        return false;
    }
    if (std.mem.startsWith(u8, call.name, "mcp__")) return !companionReadOnly(call.name, call.input);
    return true;
}
