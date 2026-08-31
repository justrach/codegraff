//! C ABI for in-process ACP (`libgraff` + `graff-core.wasm`).
//! Same-process: the host writes a JSON-RPC line into the input slot,
//! calls `graff_acp_feed`, then reads the output slot. No child process.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const engine = @import("acp_engine.zig");

const in_cap: usize = 64 * 1024;
const out_cap: usize = 256 * 1024;
const heap_cap: usize = 1024 * 1024;

var in_buf: [in_cap]u8 = undefined;
var out_buf: [out_cap]u8 = undefined;
var out_len: usize = 0;
var heap: [heap_cap]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&heap);
var seed: u32 = 1;
var created: u32 = 0;
var session_id_buf: [64]u8 = undefined;
var session_id: ?[]const u8 = null;

fn echoTurn(_: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    return std.fmt.allocPrint(arena, "echo:{s}", .{text});
}

fn dispatch() engine.Dispatch {
    return .{
        .turn = echoTurn,
        .ctx = undefined,
        .session_id = session_id,
        .seed = seed,
        .created = created,
    };
}

fn persistSession(d: *engine.Dispatch) void {
    created = d.created;
    if (d.session_id) |sid| {
        const n = @min(sid.len, session_id_buf.len);
        if (sid.ptr != &session_id_buf) {
            var tmp: [session_id_buf.len]u8 = undefined;
            @memcpy(tmp[0..n], sid[0..n]);
            @memcpy(session_id_buf[0..n], tmp[0..n]);
        }
        session_id = session_id_buf[0..n];
    }
}

export fn graff_acp_in_ptr() [*]u8 {
    return &in_buf;
}

export fn graff_acp_in_cap() usize {
    return in_cap;
}

export fn graff_acp_out_ptr() [*]const u8 {
    return &out_buf;
}

export fn graff_acp_out_len() usize {
    return out_len;
}

export fn graff_acp_out_consume() void {
    out_len = 0;
}

export fn graff_acp_create(new_seed: u32) void {
    fba.reset();
    out_len = 0;
    created = 0;
    session_id = null;
    seed = if (new_seed == 0) 1 else new_seed;
    engine.cancel_flag.store(false, .release);
    engine.implementation_version = "0.0.281-core";
}

export fn graff_acp_feed(len: usize) i32 {
    const n = @min(len, in_cap);
    var arena_state = std.heap.ArenaAllocator.init(fba.allocator());
    defer arena_state.deinit();
    var d = dispatch();
    var w: Io.Writer = .fixed(out_buf[out_len..]);
    engine.handleLine(&d, arena_state.allocator(), &w, in_buf[0..n]) catch return -1;
    out_len += w.buffered().len;
    persistSession(&d);
    return 0;
}

test "C ABI create / feed speaks ACP without a child process" {
    graff_acp_create(0xabc);
    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}";
    @memcpy(in_buf[0..init_line.len], init_line);
    try std.testing.expectEqual(@as(i32, 0), graff_acp_feed(init_line.len));
    const init_out = graff_acp_out_ptr()[0..graff_acp_out_len()];
    try std.testing.expect(std.mem.indexOf(u8, init_out, "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_out, "\"name\":\"graff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_out, "graff-login") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_out, "\"type\":\"terminal\"") != null);
    graff_acp_out_consume();

    const new_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}";
    @memcpy(in_buf[0..new_line.len], new_line);
    try std.testing.expectEqual(@as(i32, 0), graff_acp_feed(new_line.len));
    const new_out = graff_acp_out_ptr()[0..graff_acp_out_len()];
    try std.testing.expect(std.mem.indexOf(u8, new_out, "acp-abc-1") != null);
    graff_acp_out_consume();

    const prompt = "{\"id\":3,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}";
    @memcpy(in_buf[0..prompt.len], prompt);
    try std.testing.expectEqual(@as(i32, 0), graff_acp_feed(prompt.len));
    const prompt_out = graff_acp_out_ptr()[0..graff_acp_out_len()];
    try std.testing.expect(std.mem.indexOf(u8, prompt_out, "echo:hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt_out, "end_turn") != null);
}
