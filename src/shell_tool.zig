//! One `shell` tool (fx-style) for run / output / kill.
//!
//! Catalog advertises `shell`. Dispatch still accepts `bash`, `bash_output`,
//! and `bash_kill` so in-flight models and rlm `bash()` keep working.
//! `action=interact` is refused: jobs spawn with stdin ignored (not a PTY).
//! Typing in the composer during a live command is steer, not process stdin.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const tools = @import("tools.zig");
const ToolCall = tools.ToolCall;
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const strField = tools.strField;
const intField = tools.intField;
const missingArg = tools.missingArg;

const jobs = @import("jobs.zig");
const exec_bash = @import("exec_bash.zig");

pub const tool_name = "shell";
pub const tool_desc = "Run a shell command via /bin/sh -c in the current working directory, read a background job, or stop one. action=run (default when command is set) returns stdout/stderr/exit. A user-cancelled command reports cancelled (its whole local process group is killed; a remote process started over ssh may survive on the remote host). Foreground commands still running after 120s (lean -p: 15s, or a shorter timeout ms) move to the background and return a job id. For long-running commands set run_in_background true to skip the wait. You are notified on completion — do not poll. action=output wait_ms>0 blocks until exit (up to 10h) for a finite job; a persistent server snapshots immediately (wait_ms is ignored) and stays on /jobs. action=kill stops it. A background job that writes nothing and is read by nobody for 2 hours is stopped for inactivity; the user pins a long-lived server with /jobs keep. bash/bash_output/bash_kill still dispatch. Not a PTY: you cannot type into the process. Type in the composer to steer the turn.";
pub const tool_schema =
    \\{"type": "object", "properties": {"action": {"type": "string", "enum": ["run", "output", "kill"], "description": "run a command, read a job, or stop a job. Default run when command is set."}, "command": {"type": "string", "description": "Shell command to execute (action=run)"}, "timeout": {"type": "integer", "description": "Optional foreground wait in milliseconds before auto-background. A shorter value promotes earlier; a larger value cannot extend past the 120s (lean -p: 15s) bound. 0 uses the default. Ignored when run_in_background is true. A persistent server's action=output is a snapshot, not wait-until-exit."}, "run_in_background": {"type": "boolean", "description": "Start as a background job and return its id immediately instead of waiting (default false). Do not poll it."}, "id": {"type": "integer", "description": "Job id for action=output or kill"}, "wait_ms": {"type": "integer", "description": "0 = snapshot now. Finite jobs: >0 waits until exit (10h cap). Persistent servers: snapshot now; wait_ms is ignored. Do not poll."}}}
;

pub const Action = enum { run, output, kill };

pub fn isFamily(name: []const u8) bool {
    return std.mem.eql(u8, name, tool_name) or
        std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "bash_output") or
        std.mem.eql(u8, name, "bash_kill");
}

/// A call that runs a shell command: the advertised name or its legacy
/// alias. Every gate that inspects `command` must use this (#1292).
pub fn runsCommand(name: []const u8) bool {
    return std.mem.eql(u8, name, tool_name) or std.mem.eql(u8, name, "bash");
}

pub fn isAlias(name: []const u8) bool {
    return std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "bash_output") or
        std.mem.eql(u8, name, "bash_kill");
}

fn aliasAction(name: []const u8) ?Action {
    if (std.mem.eql(u8, name, "bash")) return .run;
    if (std.mem.eql(u8, name, "bash_output")) return .output;
    if (std.mem.eql(u8, name, "bash_kill")) return .kill;
    return null;
}

fn parseAction(name: []const u8, input: Value) error{ Missing, Interact, Unknown }!Action {
    if (aliasAction(name)) |a| return a;
    const raw = strField(input, "action") orelse {
        if (strField(input, "command") != null) return .run;
        return error.Missing;
    };
    if (std.mem.eql(u8, raw, "run")) return .run;
    if (std.mem.eql(u8, raw, "output") or std.mem.eql(u8, raw, "wait")) return .output;
    if (std.mem.eql(u8, raw, "kill") or std.mem.eql(u8, raw, "stop")) return .kill;
    if (std.mem.eql(u8, raw, "interact") or std.mem.eql(u8, raw, "write")) return error.Interact;
    return error.Unknown;
}

pub fn actionOf(call: ToolCall) ?Action {
    return parseAction(call.name, call.input) catch null;
}

pub fn runCommand(call: ToolCall) ?[]const u8 {
    const action = actionOf(call) orelse return null;
    if (action != .run) return null;
    return strField(call.input, "command");
}

pub fn isBackgroundRun(call: ToolCall) bool {
    if (actionOf(call) != .run) return false;
    const v = call.input.object.get("run_in_background") orelse return false;
    return v == .bool and v.bool;
}

pub fn isJobControl(call: ToolCall) bool {
    const action = actionOf(call) orelse return false;
    return action == .output or action == .kill;
}

pub fn isKill(call: ToolCall) bool {
    return actionOf(call) == .kill;
}

pub fn exec(ctx: ToolCtx, call: ToolCall) !ToolOutput {
    const gpa = ctx.gpa;
    const action = parseAction(call.name, call.input) catch |err| switch (err) {
        error.Missing => return missingArg(gpa, "action or command"),
        error.Interact => return .{
            .text = try gpa.dupe(u8, "shell action=interact is not available: jobs ignore stdin (not a PTY). Use action=run with a non-interactive command, or action=output/kill on a job id. Type in the composer to steer the turn — that does not type into the process."),
            .is_error = true,
        },
        error.Unknown => return .{
            .text = try gpa.dupe(u8, "shell action must be run, output, or kill"),
            .is_error = true,
        },
    };
    switch (action) {
        .run => {
            if (strField(call.input, "command") == null) return missingArg(gpa, "command");
            return exec_bash.exec(ctx, call);
        },
        .output => {
            const id = intField(call.input, "id") orelse return missingArg(gpa, "id");
            const wait_ms = intField(call.input, "wait_ms") orelse 0;
            if (id < 0 or id > @import("shell_identity.zig").last) return .{ .text = try gpa.dupe(u8, "invalid job id"), .is_error = true };
            return jobs.jobOutput(gpa, ctx.io, @intCast(id), @intCast(@max(wait_ms, 0)));
        },
        .kill => {
            const id = intField(call.input, "id") orelse return missingArg(gpa, "id");
            if (id < 0 or id > @import("shell_identity.zig").last) return .{ .text = try gpa.dupe(u8, "invalid job id"), .is_error = true };
            return jobs.jobKill(gpa, ctx.io, @intCast(id));
        },
    }
}

fn parseCall(gpa: Allocator, name: []const u8, json: []const u8) !struct { parsed: std.json.Parsed(Value), call: ToolCall } {
    const parsed = try std.json.parseFromSlice(Value, gpa, json, .{});
    return .{ .parsed = parsed, .call = .{ .id = "t", .name = name, .input = parsed.value } };
}

test "shell actions: run default, aliases, interact refused" {
    const gpa = std.testing.allocator;
    {
        var c = try parseCall(gpa, "shell", "{\"command\":\"echo hi\"}");
        defer c.parsed.deinit();
        try std.testing.expectEqual(Action.run, actionOf(c.call).?);
        try std.testing.expectEqualStrings("echo hi", runCommand(c.call).?);
        try std.testing.expect(!isBackgroundRun(c.call));
        try std.testing.expect(!isJobControl(c.call));
    }
    {
        var c = try parseCall(gpa, "shell", "{\"action\":\"output\",\"id\":3}");
        defer c.parsed.deinit();
        try std.testing.expectEqual(Action.output, actionOf(c.call).?);
        try std.testing.expect(isJobControl(c.call));
        try std.testing.expect(!isKill(c.call));
    }
    {
        var c = try parseCall(gpa, "shell", "{\"action\":\"stop\",\"id\":3}");
        defer c.parsed.deinit();
        try std.testing.expectEqual(Action.kill, actionOf(c.call).?);
        try std.testing.expect(isKill(c.call));
    }
    {
        var c = try parseCall(gpa, "bash", "{\"command\":\"true\"}");
        defer c.parsed.deinit();
        try std.testing.expectEqual(Action.run, actionOf(c.call).?);
        try std.testing.expect(isFamily("bash") and isAlias("bash"));
    }
    {
        var c = try parseCall(gpa, "bash_output", "{\"id\":1}");
        defer c.parsed.deinit();
        try std.testing.expectEqual(Action.output, actionOf(c.call).?);
    }
    {
        var c = try parseCall(gpa, "shell", "{\"action\":\"interact\",\"session_id\":\"x\"}");
        defer c.parsed.deinit();
        try std.testing.expect(actionOf(c.call) == null);
        try std.testing.expectError(error.Interact, parseAction("shell", c.call.input));
    }
}

test "shell interact dispatch names the missing PTY" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Value, gpa, "{\"action\":\"interact\",\"chars\":\"ls\\n\"}", .{});
    defer parsed.deinit();
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{
        .gpa = gpa,
        .io = std.testing.io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
    const out = try exec(ctx, .{ .id = "t", .name = "shell", .input = parsed.value });
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "not a PTY") != null);
}

test "#1270: a NUL byte in a shell command is refused with its offset, never run" {
    const gpa = std.testing.allocator;
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{ .gpa = gpa, .io = std.testing.io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    for ([_][]const u8{ "shell", "bash" }) |name| {
        var c = try parseCall(gpa, name, "{\"command\":\"true\\u0000 && false\"}");
        defer c.parsed.deinit();
        try std.testing.expectEqual(@as(?usize, 4), std.mem.indexOfScalar(u8, runCommand(c.call).?, 0));
        const out = try exec(ctx, c.call);
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(!out.pending);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "NUL byte at offset 4") != null);
    }
}

test "catalog advertises shell, not the three bash names" {
    const schema = @import("schema.zig");
    var saw_shell = false;
    for (schema.base_specs) |t| {
        try std.testing.expect(!std.mem.eql(u8, t.name, "bash"));
        try std.testing.expect(!std.mem.eql(u8, t.name, "bash_output"));
        try std.testing.expect(!std.mem.eql(u8, t.name, "bash_kill"));
        if (std.mem.eql(u8, t.name, tool_name)) {
            saw_shell = true;
            try std.testing.expectEqualStrings(tool_desc, t.desc);
            try std.testing.expectEqualStrings(tool_schema, t.schema);
            try std.testing.expect(std.mem.indexOf(u8, t.schema, "wait_ms is ignored") != null);
            try std.testing.expect(std.mem.indexOf(u8, t.desc, "snapshots immediately") != null);
        }
    }
    try std.testing.expect(saw_shell);
}

test "shell controls preserve JS exact handles and reject out of range integers" {
    const gpa = std.testing.allocator;
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{ .gpa = gpa, .io = std.testing.io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    for ([_][]const u8{ "bash_output", "bash_kill" }) |name| {
        for ([_]i64{ 4294967296, 9007199254740991, -1, 9007199254740992 }) |id| {
            const input = try std.fmt.allocPrint(gpa, "{{\"id\":{d}}}", .{id});
            defer gpa.free(input);
            var c = try parseCall(gpa, name, input);
            defer c.parsed.deinit();
            const out = try exec(ctx, c.call);
            defer gpa.free(out.text);
            try std.testing.expect(out.is_error);
            if (id < 0 or id > @import("shell_identity.zig").last) {
                try std.testing.expectEqualStrings("invalid job id", out.text);
            } else {
                const expected = try std.fmt.allocPrint(gpa, "background job {d} has no live owner", .{id});
                defer gpa.free(expected);
                try std.testing.expect(std.mem.startsWith(u8, out.text, expected));
            }
        }
    }
}
