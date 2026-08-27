//! Agent-authored project-local tools (#555). Skills stay instructions;
//! this is the executable half: `.graff/tools/<name>/` with a manifest +
//! script, validated at install, registered on every later session.
//!
//! Runner is a subprocess speaking a one-shot JSON contract (stdin args,
//! stdout text or `{"text","is_error"}`). Not MCP, not a skill.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const schema = @import("schema.zig");
const no_local_tools = @import("no_local_tools.zig");
const process_runner = @import("process_runner.zig");
const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");

const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const ToolSpec = schema.ToolSpec;

pub const install_name = "install_agent_tool";
pub const install_desc = "Install a project-local tool under .graff/tools/<name>/. Validates the manifest, dry-runs the script, and registers it as local__<name> for later turns. Skills stay instructions; this is the executable half.";
pub const install_schema =
    \\{"type": "object", "properties": {"name": {"type": "string", "description": "tool name (letters, digits, _-)"}, "description": {"type": "string"}, "schema": {"type": "string", "description": "JSON Schema object for the tool input"}, "runner": {"type": "string", "enum": ["python3", "bun", "sh"]}, "entry": {"type": "string", "description": "script filename inside the tool dir (no path separators)"}, "source": {"type": "string", "description": "script body"}}, "required": ["name", "description", "schema", "runner", "entry", "source"]}
;

pub const prefix = "local__";
pub const store_rel = ".graff/tools";

const install_spec = ToolSpec{ .name = install_name, .desc = install_desc, .schema = install_schema };

pub const Installed = struct {
    spec: ToolSpec,
    runner: []const u8,
    entry_path: []const u8,
};

var g_loaded: []Installed = &.{};

pub fn isInstall(name: []const u8) bool {
    return std.mem.eql(u8, name, install_name);
}

pub fn isLocal(name: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix);
}

pub fn nameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn runnerOk(runner: []const u8) bool {
    return std.mem.eql(u8, runner, "python3") or std.mem.eql(u8, runner, "bun") or std.mem.eql(u8, runner, "sh");
}

pub fn entryOk(entry: []const u8) bool {
    if (entry.len == 0 or std.mem.indexOfAny(u8, entry, "/\\") != null) return false;
    if (std.mem.eql(u8, entry, "..") or std.mem.indexOf(u8, entry, "..") != null) return false;
    return true;
}

pub fn schemaOk(raw: []const u8) bool {
    var parsed = std.json.parseFromSlice(Value, std.heap.page_allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const ty = parsed.value.object.get("type") orelse return false;
    return ty == .string and std.mem.eql(u8, ty.string, "object");
}

pub fn qualified(arena: Allocator, name: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, name }) catch name;
}

/// Scan `.graff/tools/` into the process-local table (session arena).
pub fn load(io: Io, arena: Allocator) void {
    g_loaded = &.{};
    if (no_local_tools.enabled or no_local_tools.lean) return;
    var dir = Io.Dir.cwd().openDir(io, store_rel, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate(io);
    var list: std.ArrayList(Installed) = .empty;
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        if (!nameOk(ent.name)) continue;
        const one = readOne(io, arena, ent.name) orelse continue;
        list.append(arena, one) catch break;
    }
    g_loaded = list.items;
}

fn readOne(io: Io, arena: Allocator, name: []const u8) ?Installed {
    const man_path = std.fmt.allocPrint(arena, "{s}/{s}/manifest.json", .{ store_rel, name }) catch return null;
    const raw = Io.Dir.cwd().readFileAlloc(io, man_path, arena, .limited(64 * 1024)) catch return null;
    const obj = std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch return null;
    if (obj != .object) return null;
    const desc = if (obj.object.get("description")) |v| (if (v == .string) v.string else "") else "";
    const schema_s = if (obj.object.get("schema")) |v| (if (v == .string) v.string else "") else "";
    const runner = if (obj.object.get("runner")) |v| (if (v == .string) v.string else "") else "";
    const entry = if (obj.object.get("entry")) |v| (if (v == .string) v.string else "") else "";
    if (desc.len == 0 or !schemaOk(schema_s) or !runnerOk(runner) or !entryOk(entry)) return null;
    const entry_path = std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ store_rel, name, entry }) catch return null;
    Io.Dir.cwd().access(io, entry_path, .{}) catch return null;
    return .{
        .spec = .{ .name = qualified(arena, name), .desc = desc, .schema = schema_s },
        .runner = runner,
        .entry_path = entry_path,
    };
}

/// Catalog extras for this session: the install meta-tool plus every loaded local.
pub fn catalogExtras(arena: Allocator) []const ToolSpec {
    if (no_local_tools.enabled or no_local_tools.lean) return &.{};
    const n = 1 + g_loaded.len;
    const out = arena.alloc(ToolSpec, n) catch return &.{};
    out[0] = install_spec;
    for (g_loaded, 0..) |it, i| out[i + 1] = it.spec;
    return out;
}

pub fn handleInstall(self: *Agent, call: ToolCall) !ExecResult {
    if (self.sub) return .{ .text = "install_agent_tool is root-only", .is_error = true };
    if (no_local_tools.enabled or no_local_tools.lean) return .{ .text = "local tools are disabled under --no-local-tools / --lean", .is_error = true };
    const obj = tools_mod.json_args.object(call.input) orelse return .{ .text = "install_agent_tool needs an object", .is_error = true };
    const name = tools_mod.json_args.str(obj, "name") orelse "";
    const description = tools_mod.json_args.str(obj, "description") orelse "";
    const schema_s = tools_mod.json_args.str(obj, "schema") orelse "";
    const runner = tools_mod.json_args.str(obj, "runner") orelse "";
    const entry = tools_mod.json_args.str(obj, "entry") orelse "";
    const source = tools_mod.json_args.str(obj, "source") orelse "";
    if (!nameOk(name)) return .{ .text = "name must be 1-40 letters, digits, _ or -", .is_error = true };
    if (description.len == 0) return .{ .text = "description is required", .is_error = true };
    if (!schemaOk(schema_s)) return .{ .text = "schema must be a JSON object schema", .is_error = true };
    if (!runnerOk(runner)) return .{ .text = "runner must be python3, bun, or sh", .is_error = true };
    if (!entryOk(entry)) return .{ .text = "entry must be a filename in the tool dir", .is_error = true };
    if (source.len == 0) return .{ .text = "source is required", .is_error = true };

    const dir_rel = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ store_rel, name });
    Io.Dir.cwd().makePath(self.io, dir_rel) catch return .{ .text = "could not create .graff/tools dir", .is_error = true };
    const entry_rel = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir_rel, entry });
    Io.Dir.cwd().writeFile(self.io, .{ .sub_path = entry_rel, .data = source }) catch return .{ .text = "could not write the script", .is_error = true };
    const man = try std.fmt.allocPrint(self.arena,
        \\{{"name":{s},"description":{s},"schema":{s},"runner":{s},"entry":{s}}}
    , .{
        try jsonString(self.arena, name),
        try jsonString(self.arena, description),
        try jsonString(self.arena, schema_s),
        try jsonString(self.arena, runner),
        try jsonString(self.arena, entry),
    });
    const man_rel = try std.fmt.allocPrint(self.arena, "{s}/manifest.json", .{dir_rel});
    Io.Dir.cwd().writeFile(self.io, .{ .sub_path = man_rel, .data = man }) catch return .{ .text = "could not write the manifest", .is_error = true };

    if (!dryRun(self.io, self.gpa, runner, entry_rel)) {
        return .{ .text = "dry-run failed — the script must exit 0 on --dry-run", .is_error = true };
    }
    load(self.io, self.arena);
    self.invalidateRootTools();
    return .{ .text = try std.fmt.allocPrint(self.arena, "installed {s}{s} — registered for the next model call", .{ prefix, name }), .is_error = false };
}

fn jsonString(arena: Allocator, s: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var st: std.json.Stringify = .{ .writer = &aw.writer };
    try st.write(s);
    return aw.writer.buffered();
}

fn dryRun(io: Io, gpa: Allocator, runner: []const u8, entry_rel: []const u8) bool {
    const argv = [_][]const u8{ runner, entry_rel, "--dry-run" };
    const run_res = process_runner.runCapped(gpa, io, &argv, 32 * 1024, 4 * 1024, 8_000) catch return false;
    defer gpa.free(run_res.stdout);
    defer gpa.free(run_res.stderr);
    return run_res.term == .exited and run_res.term.exited == 0;
}

pub fn call(gpa: Allocator, io: Io, name: []const u8, input: Value) !tools_mod.ToolOutput {
    if (!isLocal(name)) return .{ .text = try gpa.dupe(u8, "not a local tool"), .is_error = true };
    const inst = find(name) orelse return .{ .text = try gpa.dupe(u8, "local tool is not installed in this session"), .is_error = true };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var st: std.json.Stringify = .{ .writer = &aw.writer };
    st.write(input) catch return .{ .text = try gpa.dupe(u8, "could not encode args"), .is_error = true };
    const argv = [_][]const u8{ inst.runner, inst.entry_path, aw.writer.buffered() };
    const run_res = process_runner.runCapped(gpa, io, &argv, 256 * 1024, 16 * 1024, 30_000) catch |err| {
        return .{ .text = try std.fmt.allocPrint(gpa, "local tool failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer gpa.free(run_res.stdout);
    defer gpa.free(run_res.stderr);
    const raw_out = std.mem.trim(u8, run_res.stdout, " \t\r\n");
    if (std.json.parseFromSlice(Value, gpa, raw_out, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            const text = if (parsed.value.object.get("text")) |v| (if (v == .string) v.string else raw_out) else raw_out;
            const err = if (parsed.value.object.get("is_error")) |v| (v == .bool and v.bool) else false;
            return .{ .text = try gpa.dupe(u8, text), .is_error = err };
        }
    } else |_| {}
    const failed = run_res.term != .exited or run_res.term.exited != 0;
    return .{ .text = try gpa.dupe(u8, if (raw_out.len > 0) raw_out else run_res.stderr), .is_error = failed };
}

fn find(name: []const u8) ?Installed {
    for (g_loaded) |it| if (std.mem.eql(u8, it.spec.name, name)) return it;
    return null;
}

test "nameOk / runnerOk / entryOk / schemaOk" {
    try std.testing.expect(nameOk("digest"));
    try std.testing.expect(!nameOk("../x"));
    try std.testing.expect(!nameOk(""));
    try std.testing.expect(runnerOk("python3") and runnerOk("sh") and !runnerOk("node"));
    try std.testing.expect(entryOk("run.py") and !entryOk("../run.py") and !entryOk("a/b"));
    try std.testing.expect(schemaOk("{\"type\":\"object\",\"properties\":{}}"));
    try std.testing.expect(!schemaOk("[]"));
    try std.testing.expect(!schemaOk("{"));
}

test "install then load registers local__name" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    try tmp.dir.setAsCwd();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    defer {
        g_loaded = &.{};
    }
    const arena = arena_state.allocator();
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    var root: Agent = undefined;
    root.io = io;
    root.arena = arena;
    root.gpa = gpa;
    root.sub = false;
    root.client = &dummy_client;
    root.tools_anthropic = "keep";
    root.tools_openai = "keep";
    root.tools_responses = "keep";

    const input = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"name":"echo","description":"echo args","schema":"{\"type\":\"object\",\"properties\":{}}","runner":"python3","entry":"run.py","source":"import sys\nraise SystemExit(0) if '--dry-run' in sys.argv else print(sys.argv[2])\n"}
    , .{});
    const call: ToolCall = .{ .id = "t1", .name = install_name, .input = input };
    const r = try handleInstall(&root, call);
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "local__echo") != null);
    try std.testing.expectEqualStrings("", root.tools_anthropic);
    try std.testing.expect(g_loaded.len == 1);
    try std.testing.expectEqualStrings("local__echo", g_loaded[0].spec.name);
    const extras = catalogExtras(arena);
    try std.testing.expectEqualStrings(install_name, extras[0].name);
    const called = try call(gpa, io, "local__echo", input);
    defer gpa.free(called.text);
    try std.testing.expect(!called.is_error);
    g_loaded = &.{};
}
