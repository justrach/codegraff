//! `graff repl` — top-level entry points: the live TUI loop (run), the
//! headless/scriptable twin for CI and non-TTY stdin (runScripted), and the
//! standalone `graff-repl` exe's main(). Split out of repl.zig (#123,
//! 600-line goal).

const std = @import("std");
const builtin = @import("builtin");
const zz = @import("zigzag");

const repl = @import("repl.zig");
const Model = repl.Model;

/// Run the REPL. Pass a `turn_fn` (+ opaque ctx + model name) to chat with a
/// model; pass null/null/"" for the offline arithmetic engine.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    turn_ctx: ?*anyopaque,
    turn_fn: ?repl.TurnFn,
    model_fn: ?repl.ModelFn,
    cancel_fn: ?repl.CancelFn,
    model_name: []const u8,
    models: []const u8,
) !void {
    repl.g_turn_ctx = turn_ctx;
    repl.g_turn_fn = turn_fn;
    repl.g_model_fn = model_fn;
    repl.g_cancel_fn = cancel_fn;
    repl.g_model_name = model_name;
    repl.g_debug = environ_map.get("GRAFF_REPL_DEBUG") != null;
    repl.g_models = models;
    var program = zz.Program(Model).initWithOptions(gpa, io, environ_map, .{ .mouse = true });
    defer program.deinit();
    try program.run();
}

/// Headless, scriptable twin of run(): drives the SAME Model + turn_fn as the
/// live TUI, but reads input lines from `in` and prints each turn's new output to
/// `out` instead of taking over the terminal. Lets
///   printf '/goal X\n<prompt>\n' | graff repl
/// exercise the exact repl path (goal steering, todo_write, cross-turn continuity)
/// from a script / CI / test — a 1:1 map of the interactive behavior. main() routes
/// here automatically when stdin is not a TTY. GRAFF_REPL_DEBUG=1 additionally dumps
/// each turn's raw agent stream to stderr (where mid-turn renders like the
/// todo_write checklist appear).
pub fn runScripted(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    turn_ctx: ?*anyopaque,
    turn_fn: ?repl.TurnFn,
    model_fn: ?repl.ModelFn,
    cancel_fn: ?repl.CancelFn,
    model_name: []const u8,
    models: []const u8,
) !void {
    repl.g_turn_ctx = turn_ctx;
    repl.g_turn_fn = turn_fn;
    repl.g_model_fn = model_fn;
    repl.g_cancel_fn = cancel_fn;
    repl.g_model_name = model_name;
    repl.g_debug = environ_map.get("GRAFF_REPL_DEBUG") != null;
    repl.g_models = models;

    var m: Model = undefined;
    m.setup(gpa);
    defer m.deinit();

    while (true) {
        const raw = (in.takeDelimiter('\n') catch null) orelse break; // EOF ends the script
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;

        try out.print("\n> {s}\n", .{line});
        try out.flush();

        const before = m.history.items.len;
        const eff = m.applyLine(line);

        // A chat line spawns a background turn; a slash command runs inline.
        if (m.pending != null) {
            while (m.pending) |job| {
                if (job.done.load(.acquire)) {
                    m.finishJob();
                    break;
                }
                io.sleep(.fromMilliseconds(20), .awake) catch {};
            }
        }

        // Print what the line produced — slash-command info, the assistant reply,
        // or an error. The user line is already echoed above; the pending
        // placeholder is gone once finishJob ran.
        var i = before;
        while (i < m.history.items.len) : (i += 1) {
            switch (m.history.items[i].kind) {
                .pending, .input, .welcome => {},
                else => try out.print("{s}\n", .{m.history.items[i].text}),
            }
        }
        try out.flush();

        if (eff == .quit) break;
    }

    const pane = try m.render(gpa, 100, 60, 0);
    defer gpa.free(pane);
    try out.print("\n===== final repl pane =====\n{s}\n===========================\n", .{pane});
    try out.flush();
}

pub fn main(init: std.process.Init) !void {
    // Standalone `graff-repl` never visits src/main.zig. zigzag enableRawMode
    // also sets CP 65001; this covers any bytes printed before raw mode (#607).
    if (builtin.os.tag == .windows) @import("term.zig").tty.enableVtOutput();
    return run(init.gpa, init.io, init.environ_map, null, null, null, null, "", "");
}

test "standalone graff-repl enables Windows UTF-8 before zigzag raw mode (#607)" {
    const src = @embedFile("repl_run.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "tty.enableVtOutput()") != null);
}
