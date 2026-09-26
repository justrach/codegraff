//! `graff cube spawn|runs|kill` — short-lived cloud agents on gateway runs.
//!
//! A run binds a sandbox to a launch token (`cg_lt_`) that expires on its own
//! and dies with one DELETE. spawn creates the sandbox, installs graff, asks
//! `POST /v1/runs` for the token, uploads the run file to the box (0600, never
//! argv or env), and starts `graff remote-control` there; the account key
//! never enters the sandbox. The box renews its own token (run_token.zig) and
//! exits when the run is killed. `runs` lists them; `kill` ends one or all —
//! by default that deletes the sandbox too (the run's `on_end`).
const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const cube = @import("cube.zig");
const util = @import("util.zig");
const style = &@import("ansi.zig").style;
const strFieldObj = util.strFieldObj;
const intFieldObj = util.intFieldObj;

/// GRAFF_GATEWAY_BASE points these commands at another gateway (tests).
fn base() []const u8 {
    if (std.c.getenv("GRAFF_GATEWAY_BASE")) |v| return std.mem.span(v);
    return @import("main.zig").codegraff_device_base;
}

fn url(arena: Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}" ++ fmt, .{base()} ++ args);
}

fn json(arena: Allocator, value: anytype) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(value);
    return aw.writer.buffered();
}

const Ctx = struct { io: Io, gpa: Allocator, arena: Allocator, key: []const u8 };

fn exec(c: Ctx, sandbox: []const u8, cmd_line: []const u8, timeout_s: i64, asynch: bool) !Value {
    const body = try json(c.arena, .{ .command = cmd_line, .timeoutSeconds = timeout_s, .async = asynch });
    return cube.gatewayJson(c.io, c.gpa, c.arena, .POST, try url(c.arena, "/v1/sandboxes/{s}/exec", .{sandbox}), c.key, body);
}

fn result(v: Value) []const u8 {
    return if (v == .object) (strFieldObj(v.object, "result") orelse strFieldObj(v.object, "output") orelse "") else "";
}

const Spawn = struct {
    model: ?[]const u8 = null,
    task: ?[]const u8 = null,
    name: ?[]const u8 = null,
    ttl_min: i64 = 30,
    max_ttl_min: i64 = 360,
    on_end: []const u8 = "delete",
};

fn spawn(c: Ctx, out: *Io.Writer, o: Spawn) !void {
    try out.writeAll("spinning up a cloud agent …\n");
    try out.flush();
    const labels = .{ .purpose = "cube-run", .@"cg-model" = o.model orelse "", .@"cg-task" = o.task orelse "" };
    const created = try cube.gatewayJson(c.io, c.gpa, c.arena, .POST, try url(c.arena, "/v1/sandboxes", .{}), c.key, try json(c.arena, .{
        .language = "python",
        .autoStopMinutes = 15,
        .labels = labels,
    }));
    if (created != .object) std.process.fatal("cube: unexpected create response", .{});
    const sandbox = strFieldObj(created.object, "id") orelse std.process.fatal("cube: create returned no id", .{});
    try out.print("  sandbox {s}\n", .{sandbox});
    try out.flush();
    spawnInto(c, out, o, sandbox) catch |err| {
        // Never leave a billing sandbox behind a failed spawn.
        _ = cube.gatewayFetch(c.io, c.gpa, c.arena, .DELETE, try url(c.arena, "/v1/sandboxes/{s}", .{sandbox}), c.key, null) catch {};
        try out.print("  {s}✗{s} spawn failed ({t}); sandbox {s} deleted\n", .{ style.red, style.reset, err, sandbox });
        try out.flush();
        return err;
    };
}

fn spawnInto(c: Ctx, out: *Io.Writer, o: Spawn, sandbox: []const u8) !void {
    var state: []const u8 = "";
    var waits: usize = 0;
    while (waits < 60 and !std.mem.eql(u8, state, "started")) : (waits += 1) {
        if (waits > 0) c.io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
        const info = try cube.gatewayJson(c.io, c.gpa, c.arena, .GET, try url(c.arena, "/v1/sandboxes/{s}", .{sandbox}), c.key, null);
        if (info == .object) state = strFieldObj(info.object, "state") orelse "";
    }
    if (!std.mem.eql(u8, state, "started")) return error.SandboxNotStarted;

    // Private dir first; the run file lands in it later. The token never rides argv.
    const home = std.mem.trim(u8, result(try exec(c, sandbox, "umask 077; mkdir -p $HOME/.codegraff $HOME/bin && chmod 700 $HOME/.codegraff && echo $HOME", 30, false)), " \r\n");
    if (home.len == 0 or home[0] != '/') return error.NoHome;
    if (std.c.getenv("GRAFF_CUBE_GRAFF_BINARY")) |local| {
        // Developer path: ship this machine's Linux build (an unreleased graff).
        const path = std.mem.span(local);
        try out.print("  uploading graff from {s} …\n", .{path});
        try out.flush();
        const bin = Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(64 * 1024 * 1024)) catch return error.BinaryUnreadable;
        const enc = try c.arena.alloc(u8, std.base64.standard.Encoder.calcSize(bin.len));
        const up = try json(c.arena, .{ .path = try std.fmt.allocPrint(c.arena, "{s}/bin/graff", .{home}), .contentBase64 = std.base64.standard.Encoder.encode(enc, bin) });
        _ = try cube.gatewayJson(c.io, c.gpa, c.arena, .POST, try url(c.arena, "/v1/sandboxes/{s}/upload", .{sandbox}), c.key, up);
        _ = try exec(c, sandbox, "chmod 755 $HOME/bin/graff", 30, false);
    } else {
        try out.writeAll("  installing graff …\n");
        try out.flush();
        _ = try exec(c, sandbox, "curl -fsSL https://raw.githubusercontent.com/justrach/codegraff/main/install.sh | bash >/dev/null 2>&1", 120, false);
    }
    const ver = std.mem.trim(u8, result(try exec(c, sandbox, "$HOME/bin/graff --version 2>/dev/null | head -1", 30, false)), " \r\n");
    if (!std.mem.startsWith(u8, ver, "graff ")) return error.InstallFailed;
    try out.print("  {s}\n", .{ver});

    const name = o.name orelse o.model orelse "cloud-agent";
    const run_resp = try cube.gatewayFetch(c.io, c.gpa, c.arena, .POST, try url(c.arena, "/v1/runs", .{}), c.key, try json(c.arena, .{
        .sandbox_id = sandbox,
        .scopes = &[_][]const u8{ "inference", "remote-device" },
        .ttl_seconds = o.ttl_min * 60,
        .max_ttl_seconds = o.max_ttl_min * 60,
        .labels = .{ .name = name, .model = o.model orelse "", .task = o.task orelse "" },
        .on_end = o.on_end,
    }));
    if (run_resp.code < 200 or run_resp.code >= 300) {
        try out.print("  gateway refused the run: HTTP {d}: {s}\n", .{ run_resp.code, run_resp.body[0..@min(run_resp.body.len, 200)] });
        return error.RunCreateFailed;
    }
    const run = try std.json.parseFromSliceLeaky(Value, c.arena, run_resp.body, .{ .allocate = .alloc_always });
    if (run != .object) return error.RunCreateFailed;
    const run_id = strFieldObj(run.object, "run_id") orelse return error.RunCreateFailed;
    const run_file = strFieldObj(run.object, "run_file") orelse return error.RunCreateFailed;

    const b64 = try c.arena.alloc(u8, std.base64.standard.Encoder.calcSize(run_file.len));
    const upload = try json(c.arena, .{ .path = try std.fmt.allocPrint(c.arena, "{s}/.codegraff/run.json", .{home}), .contentBase64 = std.base64.standard.Encoder.encode(b64, run_file) });
    _ = try cube.gatewayJson(c.io, c.gpa, c.arena, .POST, try url(c.arena, "/v1/sandboxes/{s}/upload", .{sandbox}), c.key, upload);
    _ = try exec(c, sandbox, "chmod 600 $HOME/.codegraff/run.json", 30, false);

    var cmd: std.ArrayList(u8) = .empty;
    try cmd.print(c.arena, "cd $HOME && exec $HOME/bin/graff remote-control --yolo --name '{s}'", .{name});
    if (o.model) |m| try cmd.print(c.arena, " --model '{s}'", .{m});
    try cmd.appendSlice(c.arena, " > $HOME/.codegraff/remote-control.log 2>&1");
    _ = try exec(c, sandbox, cmd.items, 60, true);

    var online = false;
    var tries: usize = 0;
    while (tries < 15 and !online) : (tries += 1) {
        c.io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
        const log = result(exec(c, sandbox, "tail -c 600 $HOME/.codegraff/remote-control.log 2>/dev/null", 20, false) catch continue);
        if (std.mem.indexOf(u8, log, "graff remote-control ·") != null) online = true;
        if (std.mem.indexOf(u8, log, "refused") != null) {
            try out.print("  remote-control refused: {s}\n", .{std.mem.trim(u8, log, " \r\n")});
            return error.AgentRefused;
        }
    }
    try out.print("{s}✓{s} cloud agent {s}{s}{s} · run {s}\n", .{ style.green, style.reset, style.bold, name, style.reset, run_id });
    if (o.model) |m| try out.print("  model  {s}\n", .{m});
    try out.print("  expires in {d} min unless it keeps working (renewed up to {d} min)\n", .{ o.ttl_min, o.max_ttl_min });
    if (!online) try out.writeAll("  (still starting — `graff remote agents` shows it once it registers)\n");
    try out.print("  drive  graff remote new · graff remote send <session> \"…\"\n  kill   graff cube kill {s}\n", .{run_id});
    try out.flush();
}

fn listRuns(c: Ctx, out: *Io.Writer) !void {
    const resp = try cube.gatewayJson(c.io, c.gpa, c.arena, .GET, try url(c.arena, "/v1/runs", .{}), c.key, null);
    const runs = if (resp == .object) (resp.object.get("runs") orelse Value{ .array = .init(c.arena) }) else resp;
    if (runs != .array or runs.array.items.len == 0) {
        try out.writeAll("no cloud agents\n");
        try out.flush();
        return;
    }
    const now = @divTrunc(util.unixMs(c.io), 1000);
    try out.print("{s}{s:<24}  {s:<8}  {s:<18}  {s:<22}  {s:<8}  {s}{s}\n", .{ style.dim, "run", "state", "name", "model", "left", "sandbox", style.reset });
    for (runs.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const labels = if (o.get("labels")) |l| (if (l == .object) l.object else null) else null;
        const state = strFieldObj(o, "state") orelse "?";
        const left = intFieldObj(o, "expires_at", 0) - now;
        const left_s = if (std.mem.eql(u8, state, "active") and left > 0) try std.fmt.allocPrint(c.arena, "{d}m", .{@divTrunc(left + 59, 60)}) else "—";
        const color = if (std.mem.eql(u8, state, "active")) style.green else style.dim;
        try out.print("{s:<24}  {s}{s:<8}{s}  {s:<18}  {s:<22}  {s:<8}  {s}\n", .{
            strFieldObj(o, "run_id") orelse "?",                      color,                                                     state,  style.reset,
            if (labels) |l| strFieldObj(l, "name") orelse "" else "", if (labels) |l| strFieldObj(l, "model") orelse "" else "", left_s, strFieldObj(o, "sandbox_state") orelse "",
        });
    }
    try out.flush();
}

fn kill(c: Ctx, out: *Io.Writer, target: []const u8, sandbox_mode: ?[]const u8) !void {
    const all = std.mem.eql(u8, target, "--all");
    const q = if (sandbox_mode) |m| try std.fmt.allocPrint(c.arena, "?sandbox={s}", .{m}) else "";
    const u = if (all) try url(c.arena, "/v1/runs{s}", .{q}) else try url(c.arena, "/v1/runs/{s}{s}", .{ target, q });
    const resp = try cube.gatewayJson(c.io, c.gpa, c.arena, .DELETE, u, c.key, null);
    const killed: []const Value = if (resp == .object) blk: {
        if (resp.object.get("killed")) |k| if (k == .array) break :blk k.array.items;
        break :blk &[_]Value{resp};
    } else &.{};
    if (killed.len == 0) try out.writeAll("nothing to kill\n");
    for (killed) |k| if (k == .object) try out.print("{s}✓{s} run {s} killed · sandbox {s}\n", .{
        style.green, style.reset, strFieldObj(k.object, "run_id") orelse "?", strFieldObj(k.object, "sandbox") orelse "?",
    });
    try out.flush();
}

fn safeWord(s: []const u8) bool {
    if (s.len == 0 or s.len > 80) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "._/-:", ch) != null)) return false;
    return true;
}

test "spawn names that reach the box shell stay inert" {
    try std.testing.expect(safeWord("codegraff/mimo-v2.6-pro"));
    try std.testing.expect(safeWord("agent-1"));
    try std.testing.expect(!safeWord("x';rm -rf ~;'"));
    try std.testing.expect(!safeWord("a b"));
    try std.testing.expect(!safeWord(""));
}

const usage = "usage: graff cube spawn [--model M] [--task T] [--name N] [--ttl MIN] [--max-ttl MIN] [--on-end delete|stop|keep]\n" ++
    "       graff cube runs\n       graff cube kill <run_id>|--all [--sandbox delete|stop|keep]";

/// Returns false when `sub` is not one of this module's subcommands.
pub fn command(io: Io, gpa: Allocator, arena: Allocator, key: []const u8, args: []const []const u8) !bool {
    const sub = if (args.len > 0) args[0] else return false;
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const c: Ctx = .{ .io = io, .gpa = gpa, .arena = arena, .key = key };
    if (std.mem.eql(u8, sub, "runs")) {
        try listRuns(c, &ow.interface);
        return true;
    }
    if (std.mem.eql(u8, sub, "kill")) {
        if (args.len < 2) std.process.fatal("{s}", .{usage});
        var mode: ?[]const u8 = null;
        if (args.len >= 4 and std.mem.eql(u8, args[2], "--sandbox")) mode = args[3];
        try kill(c, &ow.interface, args[1], mode);
        return true;
    }
    if (!std.mem.eql(u8, sub, "spawn")) return false;
    var o: Spawn = .{};
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const flag = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, flag, "--model")) o.model = v else if (std.mem.eql(u8, flag, "--task")) o.task = v else if (std.mem.eql(u8, flag, "--name")) o.name = v else if (std.mem.eql(u8, flag, "--ttl")) o.ttl_min = std.fmt.parseInt(i64, v, 10) catch std.process.fatal("{s}", .{usage}) else if (std.mem.eql(u8, flag, "--max-ttl")) o.max_ttl_min = std.fmt.parseInt(i64, v, 10) catch std.process.fatal("{s}", .{usage}) else if (std.mem.eql(u8, flag, "--on-end")) o.on_end = v else std.process.fatal("{s}", .{usage});
    }
    if (i < args.len) std.process.fatal("{s}", .{usage});
    // These reach a shell command on the box, quoted; keep them inert.
    for ([_]?[]const u8{ o.model, o.name }) |field| if (field) |f| if (!safeWord(f))
        std.process.fatal("cube: --model/--name may use only letters, digits and . _ / - :", .{});
    try spawn(c, &ow.interface, o);
    return true;
}
