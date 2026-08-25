//! Tool-batch policy for the eval-driven predict -> verify -> repair loop.

const std = @import("std");
const ToolCall = @import("tools.zig").ToolCall;
const isMetaName = @import("schema.zig").isMetaName;
const companionReadOnly = @import("skills.zig").companionReadOnly;

pub const verifier_boundary =
    "eval is a verifier boundary and must run alone; this tool was not executed";
pub const verifier_hard_stop =
    "VERIFIER RED: the committed plan was dropped. Start a repair turn, make one focused repair, then rerun eval before completion.";

/// How many RED continuations one session may consume before the turn gives
/// up and surfaces verifier_hard_stop as its final text. Each grant is one
/// repair attempt plus its eval rerun; any green eval resets the budget
/// (runEval), so progress loops stay alive while a permanently-red eval
/// still terminates.
pub const max_repair_grants: u8 = 5;

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

/// edit/write/rlm/subagent in the same batch as attempt_completion still
/// refuse immediately: those calls change the tree the claim is about and
/// may fail. bash/read/codedb are verify/read — they run first, then
/// completion is accepted only if none failed (ADR 0024 turn tax vs grok).
pub fn batchBlocksCompletion(calls: []const ToolCall) bool {
    for (calls) |call| {
        if (std.mem.eql(u8, call.name, "edit_file") or
            std.mem.eql(u8, call.name, "write_file") or
            std.mem.eql(u8, call.name, "rlm") or
            std.mem.eql(u8, call.name, "subagent")) return true;
        if (std.mem.startsWith(u8, call.name, "mcp__")) return !companionReadOnly(call.name, call.input);
    }
    return false;
}

pub fn completionIndex(calls: []const ToolCall) ?usize {
    for (calls, 0..) |call, index| {
        if (std.mem.eql(u8, call.name, "attempt_completion")) return index;
    }
    return null;
}

/// True when attempt_completion shares the batch with a verify/read tool
/// and no workspace mutation. runTools executes those tools first, then
/// accepts completion only if none failed.
pub fn shouldDeferCompletion(calls: []const ToolCall) bool {
    if (completionIndex(calls) == null) return false;
    if (batchBlocksCompletion(calls)) return false;
    for (calls) |call| {
        if (!isMetaName(call.name)) return true;
    }
    return false;
}

pub const completion_with_mutation =
    "attempt_completion must be a separate post-verification action; this batch also contains a workspace-changing tool";

pub const completion_verify_failed =
    "attempt_completion was not accepted: a verify tool in this batch failed. Fix that result, then complete.";
