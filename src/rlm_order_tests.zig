const std = @import("std");
const rlm = @import("rlm.zig");
const spec = @import("rlm_spec.zig");
const tools = @import("tools.zig");
const gpa = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    client: std.http.Client,
    cwd: []u8,
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "old" });
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        return .{ .tmp = tmp, .client = .{ .allocator = gpa, .io = io }, .cwd = try gpa.dupe(u8, buf[0..n]) };
    }
    fn ctx(self: *Fixture) tools.ToolCtx {
        return .{ .gpa = gpa, .io = io, .client = &self.client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null, .agent_cwd = self.cwd };
    }
    fn deinit(self: *Fixture) void {
        @import("jobs.zig").jobsReap(gpa, io);
        @import("job_notify.zig").resetForTest(io);
        rlm.resetLive(gpa, io);
        self.client.deinit();
        gpa.free(self.cwd);
        self.tmp.cleanup();
    }
    fn run(self: *Fixture, code: []const u8) !tools.ToolOutput {
        return rlm.runScript(self.ctx(), code);
    }
};

test "rlm order applies native edit before dependent verification" {
    var f = try Fixture.init();
    defer f.deinit();
    const code = if (@import("builtin").os.tag == .windows)
        "e = edit_file(path=\"target.txt\", old_string=\"old\", new_string=\"new\")\nv = bash(\"findstr /x new target.txt >nul && echo VERIFIED\")\nprint(v)"
    else
        "e = edit_file(path=\"target.txt\", old_string=\"old\", new_string=\"new\")\nv = bash(\"test $(cat target.txt) = new && printf VERIFIED\")\nprint(v)";
    const out = try f.run(code);
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error and !out.pending);
    try std.testing.expectEqualStrings("VERIFIED", std.mem.trim(u8, out.text, " \r\n"));
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

const Observed = struct {
    names: [8][]const u8 = undefined,
    count: usize = 0,
    fn record(context: *anyopaque, call: tools.ToolCall, _: tools.ExecResult) !void {
        const self: *Observed = @ptrCast(@alignCast(context));
        self.names[self.count] = try gpa.dupe(u8, call.name);
        self.count += 1;
    }
};

test "rlm order observes each lexical host output exactly once in execution order" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "items.json", .data = "[{\"id\":1},{\"id\":2}]" });
    var observed: Observed = .{};
    defer for (observed.names[0..observed.count]) |name| gpa.free(name);
    var state: @import("pr_local_checks.zig").State = .{};
    var ctx = f.ctx();
    ctx.publication_observer = .{ .context = &observed, .state = &state, .record = Observed.record };
    const out = try rlm.runScript(ctx, "items = read_file(\"items.json\")\nmapped = each(items, \"sleep_ms\", \"id\")\ne = write_file(path=\"target.txt\", content=\"new\")\nr = read_file(\"target.txt\")\nprint(r)");
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("new", out.text);
    try std.testing.expectEqual(@as(usize, 5), observed.count);
    for ([_][]const u8{ "read_file", "sleep_ms", "sleep_ms", "write_file", "read_file" }, observed.names[0..observed.count]) |want, got| try std.testing.expectEqualStrings(want, got);
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
