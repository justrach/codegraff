//! The `graff repl` (chat-mode) bridge — run a full root-agent turn (tools +
//! MCP) per repl.TurnFn call, plus the model-switch/cancel adapters — and the
//! goal/eval steering-note assembly shared by both the REPL and interactive
//! loops. Also the Codex-style steering queue drain (popSteer/
//! resetSteerPartial/steerEcho) and the /effort /fast /ultracode persistence
//! (save/loadThinkingSettings). Split out of main.zig (600-line goal, #123).
//!
//! The mutable steer/thinking globals (g_steer_buf, g_steer_queue,
//! g_steer_echoed, g_steer_visible, g_out) stay declared in main.zig — they're
//! shared live with agent_interrupt.zig/agent_stream.zig via the same
//! `main_mod.g_x` pattern those files already use — so every access here goes
//! through `main_mod.g_x`, never a local alias (aliasing a `var` would freeze
//! its value at import time).
//!
//! parseEvalScore/steerEcho/saveThinkingSettings stay pub — subagent.zig,
//! agent_compact.zig, agent_interrupt.zig, and commands_model.zig already
//! back-import them as `main_mod.parseEvalScore` etc.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const Agent = agent_mod.Agent;
const Provider = provider_mod.Provider;
const ReasoningEffort = main_mod.ReasoningEffort;

const mcp = @import("mcp.zig");
const repl = @import("repl.zig");
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;
const pricing = @import("pricing.zig");
const contextFor = pricing.contextFor;

pub const ReplCtx = struct {
    io: Io,
    client: *std.http.Client,
    provider: Provider,
    registry: ?*mcp.Registry,
    sys_normal: []const u8,
    tools_anthropic: []const u8,
    tools_openai: []const u8,
    tools_responses: []const u8,
};

/// A thread-safe sink the worker writes the agent's output to and the repl's
/// render loop polls — this is what makes `graff repl` stream live. Custom
/// Io.Writer whose drain appends (under the StreamBuf mutex) to the repl buffer.
pub const ReplStreamSink = struct {
    target: *repl.StreamBuf,
    buf: [4096]u8 = undefined,
    writer: Io.Writer = undefined,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    pub fn init(self: *ReplStreamSink, target: *repl.StreamBuf) void {
        self.target = target;
        self.writer = .{ .vtable = &vtable, .buffer = &self.buf, .end = 0 };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *ReplStreamSink = @alignCast(@fieldParentPtr("writer", w));
        self.target.appendBytes(w.buffer[0..w.end]);
        w.end = 0;
        const slices = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        var written: usize = 0;
        for (slices) |b| {
            self.target.appendBytes(b);
            written += b.len;
        }
        var i: usize = 0;
        while (i < splat) : (i += 1) self.target.appendBytes(pattern);
        written += pattern.len * splat;
        return written;
    }
};

/// The standing-goal steering note appended to each turn when /goal is set: the
/// objective, an instruction to track it as a todo_write checklist, and the
/// current checklist render when one exists. Returns "" when goal is null so the
/// caller can skip the append. Pass todos_render="" when there are no todos — do
/// NOT pass renderTodos()'s "(no todos)" placeholder, which would leak into the prompt.
pub fn goalSteeringNote(arena: Allocator, goal: ?[]const u8, todos_render: []const u8) ![]const u8 {
    const g = goal orelse return "";
    const progress: []const u8 = if (todos_render.len > 0)
        try std.fmt.allocPrint(arena, "\n\nChecklist so far:\n{s}", .{todos_render})
    else
        "";
    return std.fmt.allocPrint(arena, "[standing goal: {s} - track this as a todo_write checklist and work through it, marking each item in_progress when you start and completed when done.]{s}", .{ g, progress });
}

/// Extract a 0-100 score from an eval command's output: a `score` key (JSON or
/// key=val) if present, else the last numeric line. Values in [0,1] are read as
/// fractions and scaled to 0-100.
pub fn parseEvalScore(out: []const u8) ?f64 {
    if (std.mem.indexOf(u8, out, "score")) |i| {
        var j = i + 5;
        while (j < out.len and out[j] != ':' and out[j] != '=' and out[j] != '\n') j += 1;
        if (j < out.len and (out[j] == ':' or out[j] == '=')) {
            j += 1;
            while (j < out.len and (out[j] == ' ' or out[j] == '\t' or out[j] == '"')) j += 1;
            if (parseLeadingNumber(out[j..])) |v| return normalizeScore(v);
        }
    }
    const trimmed = std.mem.trimEnd(u8, out, " \t\r\n");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |k| trimmed[k + 1 ..] else trimmed;
    if (parseLeadingNumber(std.mem.trim(u8, last, " \t\r\n"))) |v| return normalizeScore(v);
    return null;
}

fn parseLeadingNumber(s: []const u8) ?f64 {
    var end: usize = 0;
    while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '.' or s[end] == '-' or s[end] == '+')) end += 1;
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, s[0..end]) catch null;
}

fn normalizeScore(v: f64) f64 {
    if (v >= 0.0 and v <= 1.0) return v * 100.0;
    return v;
}

/// Steering injected each turn when --eval is set: the eval-driven loop
/// discipline (score -> one focused change -> re-score -> log -> stop at
/// target). Returns "" when no eval command is configured.
pub fn evalSteeringNote(arena: Allocator, eval_cmd: ?[]const u8, target: u8, has_judge: bool) ![]const u8 {
    if (eval_cmd == null) return "";
    const gate = if (has_judge)
        " An LLM judge is also configured, so the target is met only when BOTH the deterministic score AND the judge score reach it - read both numbers the `eval` tool reports."
    else
        "";
    return std.fmt.allocPrint(arena, "[eval-driven loop active. A scoring command is configured. Work it as a scored improvement loop: (1) call the `eval` tool to score the current state - the harness runs the command and logs to .graff/eval-log.tsv, so do NOT run it yourself via bash; (2) read the score, best-so-far, and output; (3) find the SINGLE biggest failure (inspect any artifacts or images directly); (4) make ONE focused change targeting it; (5) call `eval` again. Continue until `eval` reports the target ({d}/100) is met.{s} Do not stop at the first passing result, and do not revert unless `eval` shows a clear regression. After each `eval`, briefly note what you changed.]", .{ target, gate });
}

test "goalSteeringNote: goal + checklist assembly, no (no todos) leak" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // No goal -> empty note, caller skips the append.
    try std.testing.expectEqualStrings("", try goalSteeringNote(ar, null, ""));

    // Goal, no todos -> bracket note, no checklist, and never the "(no todos)" placeholder.
    const n1 = try goalSteeringNote(ar, "close all issues", "");
    try std.testing.expect(std.mem.startsWith(u8, n1, "[standing goal: close all issues - track this as a todo_write checklist"));
    try std.testing.expect(std.mem.indexOf(u8, n1, "Checklist so far") == null);
    try std.testing.expect(std.mem.indexOf(u8, n1, "(no todos)") == null);

    // Goal + live todos -> the rendered checklist is appended verbatim.
    const n2 = try goalSteeringNote(ar, "ship 0.0.177", "[x] wire steering\n[ ] add test");
    try std.testing.expect(std.mem.indexOf(u8, n2, "Checklist so far:\n[x] wire steering\n[ ] add test") != null);
}

/// repl.TurnFn — run a full ROOT agent turn (tools + MCP) for `graff repl`, so
/// the model can read files, run bash, search the codebase, etc. — not a bare
/// completion. Auto-approves tools (yolo: the chat repl has no permission UI),
/// in=null (never blocks on a prompt). Output streams into a thread-safe sink
/// the repl polls to render live; the clean final text is runTurn's return
/// value. Returns the final assistant text (raw markdown, owned by gpa) or null.
pub fn replTurnCb(ctx_ptr: ?*anyopaque, gpa: Allocator, history: []const repl.Turn, params: repl.Params, stream: *repl.StreamBuf) ?[]const u8 {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sink: ReplStreamSink = undefined;
    sink.init(stream); // agent output streams into the repl's live pane (thread-safe)
    var approvals: Approvals = .{ .yolo = true };
    const sys = if (params.goal.len > 0)
        (std.fmt.allocPrint(arena, "{s}\n\n# Standing goal (from the user)\n{s}\n\nTrack this as a todo_write checklist and work through it across turns - mark each item in_progress when you start and completed when done. Keep the list current; don't repeat finished items.", .{ c.sys_normal, params.goal }) catch c.sys_normal)
    else
        c.sys_normal;
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = c.io,
        .client = c.client,
        .provider = c.provider,
        .messages = std.json.Array.init(arena),
        .sub = false, // root: enables the full tool set + agentic loop
        .label = "repl",
        .out = &sink.writer,
        .in = null, // never prompt for tool approval / ask_user
        .stream_quiet = false, // stream tokens live into the repl pane
        .registry = c.registry,
        .approvals = &approvals,
        .sys_normal = sys,
        .tools_anthropic = c.tools_anthropic,
        .tools_openai = c.tools_openai,
        .tools_responses = c.tools_responses,
        .reasoning = switch (params.effort) {
            .low => .low,
            .medium => .medium,
            .high => .high,
            .xhigh => .xhigh,
            .max => .max,
            .ultra => .ultra,
        },
        .fast = params.fast,
        .ultracode_mode = params.ultracode,
        .show_thinking = params.thinking,
    };
    defer agent.tools_used.deinit(gpa);
    for (history) |t| {
        const role = switch (t.role) {
            .user => "user",
            .assistant => "assistant",
        };
        agent.messages.append(textMessage(arena, role, t.text) catch return null) catch return null;
    }
    const final = agent.runTurn() catch |err| switch (err) {
        // A mid-stream stall (#134): the repl turn IS live (stream_quiet=false),
        // so postStream can return error.StreamStalled. Don't collapse it to
        // null — the pane renders that as "model call failed — check /model and
        // your API key", mislabeling a harness stall as an auth/config problem.
        // Keep the streamed partial + an honest marker, mirroring mainloop.
        error.StreamStalled => {
            const partial = std.mem.trim(u8, agent.partial_text.items, " \t\r\n");
            return if (partial.len > 0)
                std.fmt.allocPrint(gpa, "{s}\n\n[response ended early: stream stalled]", .{partial}) catch null
            else
                gpa.dupe(u8, "[response ended early: stream stalled]") catch null;
        },
        else => return null,
    };
    const trimmed = std.mem.trim(u8, final, " \t\r\n");
    if (trimmed.len == 0) return null;
    return gpa.dupe(u8, trimmed) catch null;
}

/// repl.ModelFn adapter — switch the active model by name. Keeps the working
/// provider resolved at startup (its url/key/kind — e.g. the codegraff gateway
/// login) and only swaps the model field; re-resolving via providerFor can pick
/// a different, unauthenticated provider for the same model name. Returns the
/// new model name, or null on failure.
pub fn replModelCb(ctx_ptr: ?*anyopaque, gpa: Allocator, name: []const u8) ?[]const u8 {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    c.provider.model = gpa.dupe(u8, name) catch return null;
    c.provider.context = contextFor(c.provider.id, c.provider.model);
    return gpa.dupe(u8, name) catch null;
}
/// repl.CancelFn adapter — force-interrupt the running repl turn. Sets the
/// Agent-wide esc_cancel flag the streaming loops + watchdog poll, so the
/// in-flight runTurn unwinds (error.Interrupted) and the repl drains its steer
/// queue. Cross-thread safe (atomic) — the same signal the TTY esc-watch uses.
pub fn replCancelCb(ctx_ptr: ?*anyopaque) void {
    _ = ctx_ptr;
    Agent.esc_cancel.store(true, .release);
}

pub const SteerEntry = struct { text: []const u8, force: bool };

/// Pops the next queued steering prompt (FIFO), or null if none.
pub fn popSteer() ?SteerEntry {
    if (main_mod.g_steer_queue.items.len == 0) return null;
    return main_mod.g_steer_queue.orderedRemove(0);
}

/// Drops any half-typed steering line (no Enter yet) — called at the top
/// of each REPL iteration so a partial mid-turn draft never leaks into the
/// next prompt.
pub fn resetSteerPartial() void {
    main_mod.g_steer_buf.clearRetainingCapacity();
    main_mod.g_steer_echoed = false;
    main_mod.g_steer_visible.store(false, .release);
}

/// Writes steering echo to the stdout writer (the same buffered writer the
/// streaming text uses, already flushed before escPressed runs, so ordering
/// stays correct) and flushes so the user sees queued keystrokes live.
pub fn steerEcho(bytes: []const u8) void {
    if (main_mod.g_out) |w| {
        w.writeAll(bytes) catch {};
        w.flush() catch {};
    }
}

/// Persist the thinking controls (/effort, /fast) to .harness/settings.json,
/// preserving every other key. Default values (medium effort, fast off) are
/// removed rather than written so the file stays clean. Best-effort.
pub fn saveThinkingSettings(io: Io, gpa: Allocator, effort: ReasoningEffort, fast: bool, ultracode: bool, show_thinking: bool, ai_title: bool) bool {
    Io.Dir.cwd().createDir(io, Approvals.settings_dir, .default_dir) catch {}; // already-exists is fine
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    if (effort == .medium) {
        _ = root_obj.orderedRemove("effort");
    } else {
        root_obj.put(a, "effort", .{ .string = @tagName(effort) }) catch return false;
    }
    if (!fast) {
        _ = root_obj.orderedRemove("fast");
    } else {
        root_obj.put(a, "fast", .{ .bool = true }) catch return false;
    }
    if (!ultracode) {
        _ = root_obj.orderedRemove("ultracode");
    } else {
        root_obj.put(a, "ultracode", .{ .bool = true }) catch return false;
    }
    if (show_thinking) {
        _ = root_obj.orderedRemove("show_thinking");
    } else {
        root_obj.put(a, "show_thinking", .{ .bool = false }) catch return false;
    }
    if (ai_title) {
        _ = root_obj.orderedRemove("ai_title");
    } else {
        root_obj.put(a, "ai_title", .{ .bool = false }) catch return false;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, Approvals.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}

/// Load persisted thinking controls into the root agent at startup:
/// {"effort": "low|medium|high|xhigh|max|ultra"} and {"fast": true}. Best-effort — a missing
/// or garbled file just leaves the defaults (medium, off).
pub fn loadThinkingSettings(io: Io, arena: Allocator, root: *Agent) void {
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    if (v.object.get("effort")) |e| if (e == .string) {
        root.reasoning = std.meta.stringToEnum(ReasoningEffort, e.string) orelse root.reasoning;
    };
    if (v.object.get("fast")) |fv| if (fv == .bool) {
        root.fast = fv.bool;
    };
    if (v.object.get("ultracode")) |uv| if (uv == .bool) {
        root.ultracode_mode = uv.bool;
    };
    if (v.object.get("show_thinking")) |sv| if (sv == .bool) {
        root.show_thinking = sv.bool;
    };
    if (v.object.get("ai_title")) |tv| if (tv == .bool) {
        root.ai_title = tv.bool;
    };
}

/// REPL slash commands share the leading `/` with absolute POSIX paths. Only
/// treat the line as command syntax when the first token is command-shaped;
/// `/System/Library/... explain this` should be sent to the model as a prompt,
/// not rejected as an unknown slash command.
pub fn isSlashCommandLine(line: []const u8) bool {
    if (line.len == 0 or line[0] != '/') return false;
    if (line.len == 1) return true; // bare `/` opens the command picker

    const token_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const token = line[0..token_end];
    // Absolute paths with more than one component are prompts/attachments.
    if (token.len > 1 and std.mem.indexOfScalar(u8, token[1..], '/') != null) return false;

    return true;
}

test "absolute path prompts are not mistaken for slash commands" {
    try std.testing.expect(isSlashCommandLine("/"));
    try std.testing.expect(isSlashCommandLine("/help"));
    try std.testing.expect(isSlashCommandLine("/bash echo hi"));
    try std.testing.expect(isSlashCommandLine("/not-a-command"));

    try std.testing.expect(!isSlashCommandLine("/System/Library/PrivateFrameworks/StorageManagement.framework/PlugIns/StorageManagementService what causes this to start"));
    try std.testing.expect(!isSlashCommandLine("/Users/blackfloofie/codedb/src/main.zig explain this"));
}
