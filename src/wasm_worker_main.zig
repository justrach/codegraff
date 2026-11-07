//! JSPI capability ABI for a Worker-native Graff chat turn.
//! Build: zig build wasm-worker. Deliberately separate from the echo ACP ABI.
const std = @import("std");
const core = @import("worker_agent.zig");

const input_cap = 64 * 1024;
const output_cap = 1024 * 1024;
const heap_cap = 16 * 1024 * 1024;
var input: [input_cap]u8 = undefined;
var output: [output_cap]u8 = undefined;
var output_len: usize = 0;
var reply: [output_cap]u8 = undefined;
var heap: [heap_cap]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&heap);
var agent: ?core.Agent = null;
var cancelled = false;
var busy = false;
var failed = false;

extern "env" fn graff_host_call(kind: u32, ptr: [*]const u8, len: usize, out: [*]u8, cap: usize) i32;

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @trap();
}

fn hostCall(kind: u32, request: []const u8) ![]const u8 {
    if (cancelled) return error.Interrupted;
    if (request.len > output_cap) return error.RequestTooLarge;
    const n = graff_host_call(kind, request.ptr, request.len, &reply, reply.len);
    if (cancelled) return error.Interrupted;
    if (n < 0) return error.HostCallFailed;
    if (n > reply.len) return error.ResponseTooLarge;
    return reply[0..@intCast(n)];
}

fn report(value: anytype) i32 {
    var writer: std.Io.Writer = .fixed(&output);
    std.json.Stringify.value(value, .{}, &writer) catch {
        const fallback = "{\"error\":\"OutputTooLarge\"}";
        @memcpy(output[0..fallback.len], fallback);
        output_len = fallback.len;
        return -1;
    };
    output_len = writer.buffered().len;
    return 0;
}

fn failure(err: anyerror) i32 {
    _ = report(.{ .@"error" = @errorName(err) });
    return -1;
}

export fn graff_worker_in_ptr() [*]u8 {
    return &input;
}
export fn graff_worker_in_cap() usize {
    return input.len;
}
export fn graff_worker_out_ptr() [*]const u8 {
    return &output;
}
export fn graff_worker_out_len() usize {
    return output_len;
}
export fn graff_worker_cancel() void {
    cancelled = true;
}

export fn graff_worker_create(len: usize) i32 {
    if (busy) return failure(error.Busy);
    agent = null;
    failed = false;
    cancelled = false;
    output_len = 0;
    fba.reset();
    if (len > input.len) return failure(error.InputTooLarge);
    const a = fba.allocator();
    const config = std.json.parseFromSliceLeaky(std.json.Value, a, input[0..len], .{ .allocate = .alloc_always }) catch |err| return failure(err);
    agent = core.Agent.init(a, config, hostCall, &cancelled) catch |err| return failure(err);
    return 0;
}

export fn graff_worker_prompt(len: usize) i32 {
    if (busy) return failure(error.Busy);
    if (failed) return failure(error.SessionFailed);
    if (len > input.len) return failure(error.InputTooLarge);
    if (agent) |*a| {
        busy = true;
        defer busy = false;
        const result = a.prompt(input[0..len]) catch |err| {
            // Partial tool batches must never be replayed implicitly after an
            // uncertain transport failure. A fresh create starts a new session.
            failed = true;
            return failure(err);
        };
        const status = report(result);
        if (status != 0) failed = true;
        return status;
    }
    return failure(error.NotInitialized);
}
