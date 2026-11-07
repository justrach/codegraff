const std = @import("std");
const rlm = @import("rlm.zig");
const spec = @import("rlm_spec.zig");
const tools = @import("tools.zig");
const gpa = std.testing.allocator;
const io = std.testing.io;

pub const Fixture = struct { // shared with rlm_literal_tests.zig
    tmp: std.testing.TmpDir,
    client: std.http.Client,
    cwd: []u8,
    pub fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "old" });
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        return .{ .tmp = tmp, .client = .{ .allocator = gpa, .io = io }, .cwd = try gpa.dupe(u8, buf[0..n]) };
    }
    pub fn ctx(self: *Fixture) tools.ToolCtx {
        return .{ .gpa = gpa, .io = io, .client = &self.client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null, .agent_cwd = self.cwd };
    }
    pub fn deinit(self: *Fixture) void {
        @import("jobs.zig").jobsReap(gpa, io);
        @import("job_notify.zig").resetForTest(io);
        rlm.resetLive(gpa, io);
        self.client.deinit();
        gpa.free(self.cwd);
        self.tmp.cleanup();
    }
    pub fn run(self: *Fixture, code: []const u8) !tools.ToolOutput {
        return rlm.runScript(self.ctx(), code);
    }
};

test "rlm order applies native edit before dependent verification" {
    var f = try Fixture.init();
    defer f.deinit();
    const code = if (@import("builtin").os.tag == .windows)
        "e = edit_file(path=\"target.txt\", old_string=\"old\", new_string=\"new\")\nv = bash(\"type target.txt\")\nprint(v)"
    else
        "e = edit_file(path=\"target.txt\", old_string=\"old\", new_string=\"new\")\nv = bash(\"test $(cat target.txt) = new && printf VERIFIED\")\nprint(v)";
    const out = try f.run(code);
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error and !out.pending);
    try std.testing.expectEqualStrings(if (@import("builtin").os.tag == .windows) "new" else "VERIFIED", std.mem.trim(u8, out.text, "\r\n"));
}

test "rlm order failed edit prevents following verification side effects" {
    var f = try Fixture.init();
    defer f.deinit();
    const out = try f.run("e = edit_file(path=\"target.txt\", old_string=\"absent\", new_string=\"new\")\nv = bash(\"printf ran > marker\")\nprint(v)");
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
}

test "rlm order repeated mutations execute twice and post mutation read is fresh" {
    var f = try Fixture.init();
    defer f.deinit();
    const out = try f.run("before = read_file(\"target.txt\")\na = bash(\"printf x >> target.txt\")\nb = bash(\"printf x >> target.txt\")\nafter = read_file(\"target.txt\")\nprint(before, after)");
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("old\noldxx", out.text);
}

test "rlm order nested failed host prevents later mutation" {
    var f = try Fixture.init();
    defer f.deinit();
    const code = if (@import("builtin").os.tag == .windows)
        "print(bash(\"echo FAILED & exit /b 7\"), write_file(path=\"marker\", content=\"ran\"))"
    else
        "print(bash(\"printf FAILED; exit 7\"), write_file(path=\"marker\", content=\"ran\"))";
    const out = try f.run(code);
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "FAILED") != null);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
}

test "rlm order pending direct and nested hosts stop and preserve status" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{
        "v = bash(command=\"sleep 0.1\", run_in_background=true)\nx = write_file(path=\"marker\", content=\"ran\")\nprint(v)",
        "print(bash(command=\"sleep 0.1\", run_in_background=true), write_file(path=\"marker\", content=\"ran\"))",
    }) |code| {
        const out = try f.run(code);
        defer gpa.free(out.text);
        try std.testing.expect(out.pending and !out.is_error);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
    }
}

const ReadHost = struct {
    var started: std.atomic.Value(usize) = .init(0);
    var overlap: std.atomic.Value(bool) = .init(false);
    fn run(ctx: tools.ToolCtx, _: @import("spec_ptc.zig").Call) tools.ToolOutput {
        _ = started.fetchAdd(1, .seq_cst);
        for (0..100) |_| {
            if (started.load(.seq_cst) >= 2) {
                overlap.store(true, .seq_cst);
                break;
            }
            ctx.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        return .{ .text = ctx.gpa.dupe(u8, "read") catch unreachable };
    }
};

test "rlm order streamed prefix reads overlap and barrier survives partial chunks" {
    var f = try Fixture.init();
    defer f.deinit();
    const saved = spec.run_host;
    defer spec.run_host = saved;
    spec.run_host = ReadHost.run;
    ReadHost.started.store(0, .seq_cst);
    ReadHost.overlap.store(false, .seq_cst);
    spec.feedLive(f.ctx(), "a = read_file(\"a\")\nb = read_file(\"b\")\ne = edit_file(path=\"target.txt\", ");
    spec.feedLive(f.ctx(), "old_string=\"old\", new_string=\"new\")\nc = read_file(\"target.txt\")\n");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var claimed = std.StringHashMap(tools.ToolOutput).init(gpa);
    defer {
        var it = claimed.valueIterator();
        while (it.next()) |out| gpa.free(out.text);
        claimed.deinit();
    }
    spec.takeLive(f.ctx(), &claimed, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), ReadHost.started.load(.seq_cst));
    try std.testing.expect(ReadHost.overlap.load(.seq_cst));
}

test "rlm order cancelled shell preserves cancellation and prevents tail mutation" {
    var f = try Fixture.init();
    defer f.deinit();
    const cancel = @import("cancel_source.zig");
    defer cancel.clear();
    cancel.cancel(.json_cancel);
    const out = try f.run("print(bash(\"sleep 0.1\"), write_file(path=\"marker\", content=\"ran\"))");
    defer gpa.free(out.text);
    try std.testing.expect(out.cancelled and out.is_error);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
}

const StoppedHost = struct {
    var count: usize = 0;
    var pending: bool = false;
    fn run(ctx: tools.ToolCtx, _: @import("spec_ptc.zig").Call) tools.ToolOutput {
        count += 1;
        return .{ .text = ctx.gpa.dupe(u8, "stopped") catch unreachable, .pending = pending, .cancelled = !pending };
    }
};

test "rlm order each preserves pending and cancellation without binding partial results" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for ([_]bool{ true, false }) |pending| {
        StoppedHost.count = 0;
        StoppedHost.pending = pending;
        const binds = [_]spec.Binding{.{ .name = "items", .text = "[{\"id\":1},{\"id\":2}]" }};
        var outputs: std.ArrayList(spec.Binding) = .empty;
        const hit = try @import("rlm_mcp.zig").evalEach(f.ctx(), arena.allocator(), "out = each(items, \"read_file\", \"id\")", &binds, &outputs, StoppedHost.run);
        try std.testing.expect(hit == .fail);
        defer gpa.free(hit.fail.text);
        try std.testing.expectEqual(pending, hit.fail.pending);
        try std.testing.expectEqual(!pending, hit.fail.cancelled);
        try std.testing.expectEqual(@as(usize, 1), StoppedHost.count);
        try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
    }
}

test "rlm order unresolved print argument prevents speculative tail reads" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const order = @import("rlm_order.zig");
    try std.testing.expect(try order.leading(arena.allocator(), "print(bash(command=cmd), read_file(\"x\"))") == null);
    try std.testing.expect(try order.leading(arena.allocator(), "print(read_file(\"a\"), read_file(\"b\"))") != null);
}

test "rlm unsupported indexed print refuses before executing its nested command or tail" {
    var f = try Fixture.init();
    defer f.deinit();
    const out = try f.run("print(bash(\"printf ran > nested-marker\")[\"stdout\"])\nx = write_file(path=\"marker\", content=\"ran\")");
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "host results are text") != null);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "nested-marker", .{}));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
}

test "rlm unsupported bound field access reports text contract without rerunning host" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ "r[\"stdout\"]", "r.get(\"exit_code\")" }) |expr| {
        const code = try std.fmt.allocPrint(gpa, "r = bash(\"printf x >> target.txt\")\nprint({s})", .{expr});
        defer gpa.free(code);
        const out = try f.run(code);
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "assign then print(name)") != null);
    }
    const out = try f.run("print(read_file(\"target.txt\"))");
    defer gpa.free(out.text);
    try std.testing.expectEqualStrings("oldxx", out.text);
}

test "rlm print keeps literals known and missing binds and supported reducers" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "items.json", .data = "[{\"id\":1},{\"id\":2}]" });
    const out = try f.run("items = read_file(\"items.json\")\ncount = len(items)\nids = project(items, \"id\")\nprint(\"literal [data]\", 'quoted', count, ids, len(items), project(items, \"id\"), missing_bind)");
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("literal [data]\nquoted\n2\n[1,2]\n2\n[1,2]\nmissing_bind", out.text);
}

const Gate = struct {
    seen: usize = 0,
    call_id: []const u8 = "",
    fn check(context: *anyopaque, call: tools.ToolCall) ?tools.ToolOutput {
        const self: *Gate = @ptrCast(@alignCast(context));
        self.seen += 1;
        self.call_id = call.id;
        if (!@import("shell_tool.zig").runsCommand(call.name)) return null;
        return .{ .text = gpa.dupe(u8, "gate denied") catch &.{}, .is_error = true };
    }
};

test "rlm host calls pass the agent gate and a denial stops the script (#1292)" {
    var f = try Fixture.init();
    defer f.deinit();
    var gate: Gate = .{};
    var ctx = f.ctx();
    ctx.host_gate = .{ .context = &gate, .call_id = "call-rlm", .check = Gate.check };
    const out = try rlm.runScript(ctx, "r = read_file(\"target.txt\")\nv = bash(\"printf ran > marker\")\nw = write_file(path=\"after\", content=\"x\")\nprint(v)");
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expectEqualStrings("gate denied", out.text);
    try std.testing.expectEqual(@as(usize, 2), gate.seen); // read_file, then the denied bash
    try std.testing.expectEqualStrings("call-rlm", gate.call_id);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "after", .{}));
}

const Agent = @import("agent.zig").Agent;
const Approvals = @import("approvals.zig").Approvals;
const permission = @import("engine_permission.zig");

const Deny = struct {
    calls: usize = 0,
    fn ask(ptr: *anyopaque, _: std.Io, req: permission.Request) permission.Decision {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        std.debug.assert(std.mem.eql(u8, req.call_id, "call-rlm"));
        return .deny;
    }
};

fn rlmCall(arena: std.mem.Allocator, code: []const u8) !tools.ToolCall {
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "code", .{ .string = code });
    return .{ .id = "call-rlm", .name = rlm.tool_name, .input = .{ .object = args } };
}

test "rlm bash and write_file at the root ask the permission handler like catalog calls (#1292)" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for ([_][]const u8{
        "print(bash(\"printf ran > marker\"))",
        "w = write_file(path=\"marker\", content=\"ran\")\nprint(w)",
    }) |code| {
        var deny: Deny = .{};
        var approvals: Approvals = .{};
        var agent: Agent = .{ .gpa = gpa, .arena = arena.allocator(), .io = io, .client = &f.client, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 1000 }, .messages = .init(arena.allocator()), .sub = false, .label = "root", .out = null, .approvals = &approvals, .permission = .{ .ctx = &deny, .request = Deny.ask }, .agent_cwd = f.cwd };
        defer agent.tools_used.deinit(gpa);
        const results = try agent.runTools(&.{try rlmCall(arena.allocator(), code)});
        try std.testing.expectEqual(@as(usize, 1), deny.calls);
        try std.testing.expect(results[0].is_error);
        try std.testing.expect(std.mem.indexOf(u8, results[0].text, "declined") != null);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
    }
}

test "rlm loaded peer_message reports structured-only support and stops the script (#1413)" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const fold = @import("native_fold.zig");
    const saved_enabled = fold.enabled;
    defer {
        fold.enabled = saved_enabled;
        fold.resetSession();
    }
    fold.enabled = true;
    fold.resetSession();
    var agent: Agent = .{ .gpa = gpa, .arena = arena.allocator(), .io = io, .client = &f.client, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 1000 }, .messages = .init(arena.allocator()), .sub = false, .label = "root", .out = null, .agent_cwd = f.cwd };
    defer agent.tools_used.deinit(gpa);
    const load = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"tools\":[\"peer_message\"]}", .{});
    const loaded = try agent.runTools(&.{.{ .id = "load", .name = "load_tool_schemas", .input = load }});
    try std.testing.expect(!loaded[0].is_error);
    try std.testing.expect(fold.isLoaded("peer_message"));
    const results = try agent.runTools(&.{try rlmCall(arena.allocator(), "p = peer_message(action=\"inbox\")\nw = write_file(path=\"marker\", content=\"ran\")\nprint(p)")});
    try std.testing.expect(results[0].is_error);
    try std.testing.expectEqualStrings("rlm: peer_message is agent-managed and is not supported inside rlm; call peer_message directly as a structured tool.", results[0].text);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
    // Loading still enables the normal inline handler, not a host function.
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"action\":\"invalid-fixture-action\"}", .{});
    const direct = try agent.runTools(&.{.{ .id = "direct", .name = "peer_message", .input = input }});
    try std.testing.expect(direct[0].is_error);
    try std.testing.expect(std.mem.startsWith(u8, direct[0].text, "peer_message action must be "));
}

test "rlm agent-managed hosts refuse direct nested and each calls without executing the tail (#1413)" {
    var f = try Fixture.init();
    defer f.deinit();
    for (@import("schema.zig").meta_names) |name| {
        const code = try std.fmt.allocPrint(gpa, "x = {s}()\nw = write_file(path=\"marker\", content=\"ran\")", .{name});
        defer gpa.free(code);
        const out = try f.run(code);
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "is not supported inside rlm") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.text, name) != null);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
    }
    for ([_][]const u8{
        "print(peer_message(action=\"inbox\"), write_file(path=\"marker\", content=\"ran\"))",
        "x = each([\"inbox\", \"list\"], \"peer_message\", \"action\")\nw = write_file(path=\"marker\", content=\"ran\")",
    }) |code| {
        const out = try f.run(code);
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "call peer_message directly as a structured tool") != null);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
    }
}

test "rlm destructive git in a yolo subagent hits the subagent block (#1292)" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var approvals: Approvals = .{ .yolo = true };
    var agent: Agent = .{ .gpa = gpa, .arena = arena.allocator(), .io = io, .client = &f.client, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 1000 }, .messages = .init(arena.allocator()), .sub = true, .label = "sub", .out = null, .approvals = &approvals, .agent_cwd = f.cwd };
    defer agent.tools_used.deinit(gpa);
    // A missing branch: harmless even if the gate ever regresses.
    const code = "v = bash(\"git branch -D graff-1294-no-such-branch\")\nw = write_file(path=\"marker\", content=\"ran\")\nprint(v)";
    const results = try agent.runTools(&.{try rlmCall(arena.allocator(), code)});
    try std.testing.expect(results[0].is_error);
    try std.testing.expect(std.mem.indexOf(u8, results[0].text, "destructive git is blocked for subagents") != null);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, "marker", .{}));
}

test "rlm projection assignments take comments, keywords and sparse fields, then print (#1536)" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "items.json", .data = "[{\"id\":1,\"name\":\"a\"},{\"id\":2}]" });
    const out = try f.run("items = read_file(\"items.json\")\nids = project(items, \"id\")  # plain ids\nnames = project(x=items, field=\"name\")\nn = len(items) # count\nprint(ids, names, n)");
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("[1,2]\n[\"a\",null]\n2", out.text);

    const bad = try f.run("t = read_file(\"target.txt\")\nv = project(t, \"id\")\nprint(v)");
    defer gpa.free(bad.text);
    try std.testing.expect(bad.is_error);
    try std.testing.expect(std.mem.indexOf(u8, bad.text, "unsupported statement") == null);
    try std.testing.expect(std.mem.indexOf(u8, bad.text, "not a JSON array") != null);
}
