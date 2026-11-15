//! Local-only service commands run before credentials or a model are resolved.
const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
pub fn isCommand(words: []const []const u8) bool {
    return words.len > 0 and (std.mem.eql(u8, words[0], "lsp") or std.mem.eql(u8, words[0], "extensions"));
}
pub fn run(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, words: []const []const u8, no_local: bool) !bool {
    if (std.mem.eql(u8, words[0], "extensions")) return @import("extension_commands.zig").runCli(io, a, environ, words[1..]);
    if (no_local or environ.get("GRAFF_NO_LOCAL_TOOLS") != null) return error.LocalToolsDisabled;
    @import("tool_env.zig").init(a, environ);
    var input: std.json.ObjectMap = .empty;
    const operation = if (words.len > 1) words[1] else "status";
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
