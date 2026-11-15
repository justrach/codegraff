//! Local-only service commands run before credentials or a model are resolved.
const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
pub fn isCommand(words: []const []const u8) bool {
    return words.len > 0 and (std.mem.eql(u8, words[0], "lsp") or std.mem.eql(u8, words[0], "extensions"));
}
pub fn run(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, flags: *const @import("args.zig").Flags) !bool {
    const words = flags.positionals.items;
    if (std.mem.eql(u8, words[0], "extensions")) return @import("extension_commands.zig").runCli(io, a, environ, words[1..]);
    if (@import("no_local_tools.zig").enabled or environ.get("GRAFF_NO_LOCAL_TOOLS") != null) return error.LocalToolsDisabled;
    @import("tool_env.zig").init(a, environ);
    const operation = if (words.len > 1) words[1] else "status";
    if (std.mem.eql(u8, operation, "setup")) return runSetup(io, a, words, flags.update_check);
    if (flags.update_check) return error.InvalidLspCommand;
    var input: std.json.ObjectMap = .empty;
    try input.put(a, "operation", .{ .string = operation });
    const positional = @import("lsp.zig").positional(operation);
    const expected: usize = if (std.mem.eql(u8, operation, "status")) 2 else if (positional) 5 else 3;
    if (words.len != expected and !(words.len == 1 and expected == 2)) return error.InvalidLspCommand;
    if (words.len > 2) try input.put(a, "path", .{ .string = words[2] });
    if (positional) {
        try input.put(a, "line", .{ .integer = try std.fmt.parseInt(i64, words[3], 10) });
        try input.put(a, "character", .{ .integer = try std.fmt.parseInt(i64, words[4], 10) });
    }
    const output = try @import("lsp.zig").execute(.{
        .gpa = a,
        .io = io,
        .client = undefined,
        .provider = .{ .id = "local", .url = "", .api_key = "", .model = "", .kind = .openai, .auth = .bearer, .context = 0 },
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .lsp_registry = @import("lsp_config.zig").load(io, a),
    }, Value{ .object = input });
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    try writer.interface.print("{s}\n", .{output.text});
    try writer.interface.flush();
    if (output.is_error) return error.LspQueryFailed;
    return true;
}
fn runSetup(io: Io, a: std.mem.Allocator, words: []const []const u8, flag_check: bool) !bool {
    if (words.len > 3) return error.InvalidLspCommand;
    var check_only = flag_check;
    if (words.len == 3) {
        if (!std.mem.eql(u8, words[2], "--check") and !std.mem.eql(u8, words[2], "check")) return error.InvalidLspCommand;
        check_only = true;
    }
    const req = try std.json.Stringify.valueAlloc(a, .{ .check_only = check_only }, .{});
    const runner = @import("process_runner.zig");
    var empty = std.process.Environ.Map.init(a);
    defer empty.deinit();
    const argv: []const []const u8 = &.{ "python3", "-c", @embedFile("lsp_setup.py"), req };
    const result = runner.runCappedWithOptions(a, io, argv, 64 * 1024, 16 * 1024, 180_000, .{
        .environ_map = @import("tool_env.zig").get() orelse &empty,
        .kill_process_tree = true,
    }) catch return error.LspQueryFailed;
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    const body = std.mem.trimEnd(u8, if (result.stdout.len > 0) result.stdout else result.stderr, "\r\n");
    try writer.interface.print("{s}\n", .{body});
    try writer.interface.flush();
    if (!runner.ranOk(result)) return error.LspQueryFailed;
    return true;
}
