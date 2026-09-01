//! Credential-free `graff acp` bootstrap. This loop exists only when startup
//! found no usable provider credential; authenticated launches continue into
//! the unchanged live Agent runtime in acp.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const engine = @import("acp_engine.zig");

pub fn serve(gpa: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    while (true) {
        const line = in.takeDelimiter('\n') catch |err| switch (err) {
            // Reader.takeDelimiter leaves an overlong record untouched. Drop
            // it through its newline with constant memory, then keep serving.
            error.StreamTooLong => {
                _ = in.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => return,
                    else => |e| return e,
                };
                continue;
            },
            else => |e| return e,
        };
        const record = line orelse break;
        try engine.handlePreAuthLine(scratch, out, record);
        // The writer may still refer to request data until it drains. Do this
        // before resetting the scratch arena for the next record.
        try out.flush();
        _ = scratch_state.reset(.retain_capacity);
    }
}

pub fn run(io: Io, gpa: Allocator, implementation_version: []const u8) !void {
    engine.implementation_version = implementation_version;
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    try serve(gpa, &stdin_reader.interface, &stdout_writer.interface);
}

fn serveFixed(gpa: Allocator, input: []const u8, storage: []u8) ![]const u8 {
    var read_buf: [64 * 1024]u8 = undefined;
    const calls = [_]std.testing.Reader.Call{.{ .buffer = input }};
    var source = std.testing.Reader.init(&read_buf, &calls);
    var writer: Io.Writer = .fixed(storage);
    try serve(gpa, &source.interface, &writer);
    return writer.buffered();
}

fn appendPaddedLine(input: *std.array_list.Managed(u8), line_len: usize, prefix: []const u8) !void {
    const start = input.items.len;
    try input.appendSlice(prefix);
    try input.resize(start + line_len);
    @memset(input.items[start + prefix.len ..], ' ');
    try input.append('\n');
}

test "pre-auth returns ACP auth_required with terminal-login instructions" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [2048]u8 = undefined;
    const output = try serveFixed(state.allocator(),
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}
        \\{"jsonrpc":"2.0","id":"prompt-1","method":"session/prompt","params":{}}
        \\
    , &buf);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32000,\"message\":\"Authentication required: run `graff login`, then restart the ACP agent.\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":\"prompt-1\",\"error\":{\"code\":-32000,\"message\":\"Authentication required: run `graff login`, then restart the ACP agent.\"}}\n",
        output,
    );
}

test "pre-auth answers multiple initialize requests from the shared engine" {
    engine.implementation_version = "preauth-test";
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [4096]u8 = undefined;
    const output = try serveFixed(state.allocator(),
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":9}}
        \\
    , &buf);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "\"authMethods\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "graff-login"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "preauth-test"));
}

test "pre-auth ignores invalid input and continues serving requests" {
    engine.implementation_version = "preauth-test";
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [2048]u8 = undefined;
    const output = try serveFixed(state.allocator(),
        \\{not json
        \\[1,2]
        \\{"jsonrpc":"2.0","method":"initialize"}
        \\{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":1}}
        \\
    , &buf);
    try std.testing.expect(std.mem.startsWith(u8, output, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\n"));
}

test "pre-auth accepts 65535 bytes and discards 65536 and 70000 byte records" {
    engine.implementation_version = "preauth-boundaries";
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var input = std.array_list.Managed(u8).init(a);
    try appendPaddedLine(&input, 65535, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"initialize\",\"params\":{}}");
    try appendPaddedLine(&input, 65536, "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"session/new\",\"params\":{}}");
    try appendPaddedLine(&input, 70000, "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"session/new\",\"params\":{}}");
    try input.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"initialize\",\"params\":{}}\n");
    var buf: [4096]u8 = undefined;
    const output = try serveFixed(a, input.items, &buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":20") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":21") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "\"authMethods\""));
}

test "pre-auth reclaims scratch allocations across near-limit records" {
    engine.implementation_version = "preauth-reclaim";
    var backing: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);

    var record: [64 * 1024]u8 = undefined;
    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"blob\":\"";
    const suffix = "\"}}";
    const record_len = record.len - 1;
    @memcpy(record[0..prefix.len], prefix);
    @memset(record[prefix.len .. record_len - suffix.len], 'x');
    @memcpy(record[record_len - suffix.len .. record_len], suffix);
    record[record_len] = '\n';

    var calls: [2048]std.testing.Reader.Call = undefined;
    for (&calls) |*call| call.* = .{ .buffer = &record };
    var read_buf: [64 * 1024]u8 = undefined;
    var source = std.testing.Reader.init(&read_buf, &calls);
    var sink_buf: [256]u8 = undefined;
    var sink = Io.Writer.Discarding.init(&sink_buf);
    try serve(fixed.allocator(), &source.interface, &sink.writer);
    try std.testing.expectEqual(calls.len, source.next_call_index);
}

test "pre-auth discards an oversized record that reaches EOF without newline" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var input = std.array_list.Managed(u8).init(a);
    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"session/new\",\"params\":{}}";
    try input.appendSlice(prefix);
    try input.resize(70000);
    @memset(input.items[prefix.len..], ' ');
    var buf: [256]u8 = undefined;
    const output = try serveFixed(a, input.items, &buf);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "pre-auth exits cleanly on EOF" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [64]u8 = undefined;
    const output = try serveFixed(state.allocator(), "", &buf);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}
