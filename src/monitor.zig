//! `monitor` — watch a line-oriented command as a background job (ADR 0013).
//!
//! Reuses `jobs.spawnJob` (same pump as `bash` `run_in_background`). The
//! third background semantic grok-build has as its own tool: wake on new
//! complete lines without stealing `bash_output`'s unread cursor. Volume is
//! capped in `job_wake.zig`; stop with `bash_kill`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const tools = @import("tools.zig");
const jobs = @import("jobs.zig");
const job_wake = @import("job_wake.zig");
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;

const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const strField = tools.strField;
const missingArg = tools.missingArg;

pub const tool_name = "monitor";
pub const tool_desc = "Watch a long-running command as complete lines. Starts a background job and wakes the next turn when new lines arrive (and when it exits). Prefer a line-buffered producer (grep --line-buffered, tail -f). Do not poll. bash_output still reads unread bytes; bash_kill stops it.";
pub const tool_schema =
    \\{"type": "object", "properties": {"command": {"type": "string", "description": "Shell command to watch. Prefer a line-buffered producer."}, "description": {"type": "string", "description": "Short label for wake notes"}}, "required": ["command"]}
;

pub fn exec(ctx: ToolCtx, input: Value) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const cmd = strField(input, "command") orelse return missingArg(gpa, "command");
    if (main_mod.plan_mode) {
        if (!Approvals.readOnlyAllowed(cmd)) {
            const ext_ok = !ctx.from_sub and if (ctx.approvals) |ap| ap.planReadAllowed(ctx.io, cmd) else false;
            if (!ext_ok) return .{
                .text = try gpa.dupe(u8, "plan mode is on — only read-only commands run; describe this command in the plan instead"),
                .is_error = true,
            };
        }
    }
    if (ctx.from_sub) if (ctx.approvals) |ap| if (!ap.allowed(ctx.io, cmd)) return .{
        .text = try gpa.dupe(u8, "command not pre-approved — subagents may only run user-approved or read-only commands"),
        .is_error = true,
    };
    const desc = strField(input, "description") orelse cmd;
    const job = jobs.spawnJob(gpa, io, cmd) catch |err| return .{
        .text = try std.fmt.allocPrint(gpa, "could not start monitor job ({t}) — run it in the foreground with bash instead", .{err}),
        .is_error = true,
    };
    job_wake.registerWatch(job.id, desc);
    return .{ .text = try std.fmt.allocPrint(gpa, "[monitor job {d} started: {s}]\nLine-oriented output wakes the next turn. bash_output still reads unread bytes; bash_kill stops it.", .{ job.id, job.cmd }) };
}

const testing = std.testing;

test "monitor schema names the command" {
    try testing.expectEqualStrings("monitor", tool_name);
    try testing.expect(std.mem.indexOf(u8, tool_schema, "\"command\"") != null);
    try testing.expect(std.mem.indexOf(u8, tool_schema, "\"description\"") != null);
    try testing.expect(std.mem.indexOf(u8, tool_desc, "line") != null);
}

test "monitor plan mode refuses a write command from a subagent" {
    const saved = main_mod.plan_mode;
    defer main_mod.plan_mode = saved;
    main_mod.plan_mode = true;
    var parsed = try std.json.parseFromSlice(Value, testing.allocator, "{\"command\":\"rm -rf /tmp/x\"}", .{});
    defer parsed.deinit();
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = true,
        .approvals = null,
        .tracer = null,
    };
    const out = try exec(ctx, parsed.value);
    defer testing.allocator.free(out.text);
    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "plan mode") != null);
}

test "monitor exec starts a job and registers a watch" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    job_wake.resetForTest();
    defer job_wake.resetForTest();
    jobs.g_jobs = .{};
    var parsed = try std.json.parseFromSlice(Value, testing.allocator, "{\"command\":\"printf hi\\\\n\",\"description\":\"t\"}", .{});
    defer parsed.deinit();
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
    const out = try exec(ctx, parsed.value);
    defer testing.allocator.free(out.text);
    defer jobs.jobsReap(testing.allocator, testing.io);
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.text, "monitor job") != null);
}
