//! Misc slash commands + the unknown-command/help fallback, split out of
//! main.zig's handleCommand (600-line goal, issue #123): /todo /jobs /cost
//! /mcp /models /yolo /trace /fleet /save /resume /sessions, plus the
//! terminal handleRest() stage (unknown command → error, or /help dump).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const agent_mod = @import("agent.zig");
const util = @import("util.zig");
const provider_specs = provider_mod.provider_specs;
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const utf8Prefix = util.utf8Prefix;
const harness_version = main_mod.harness_version;
const mcp_config_path = main_mod.mcp_config_path;
const session_ext = session.session_ext;
const saveSession = session.saveSession;
const session = @import("session.zig");
const loadSession = session.loadSession;
const listSavedSessions = session.listSavedSessions;
const sessionAge = session.sessionAge;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const jobs = @import("jobs.zig");

const pricing = @import("pricing.zig");
const default_context = pricing.default_context;
const g_cost = &pricing.g_cost;
const models_cache = @import("models_cache.zig");

const schema = @import("schema.zig");
const renderRootTools = schema.renderRootTools;
const root_specs = schema.root_specs;

const mcp_cli = @import("mcp_cli.zig");
const persistMcpServer = mcp_cli.persistMcpServer;

const skills = @import("skills.zig");
const mcp_notes = skills.mcp_notes;

const vision = @import("vision.zig");
const visionModel = vision.visionModel;

const pickers = @import("pickers.zig");
const PickItem = pickers.PickItem;
const listPicker = pickers.listPicker;

const trace = @import("trace.zig");
const trace_path = trace.trace_path;

/// Try to handle a misc slash command. Returns false (line unhandled) if
/// `line` doesn't match any command in this file — the caller falls through
/// to handleRest() for the unknown-command/help terminal stage.
pub fn tryHandle(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (std.mem.eql(u8, line, "/todo")) {
        try out.print("{s}\n", .{root.renderTodos()});
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/jobs")) {
        jobs.g_jobs.mutex.lockUncancelable(root.io);
        defer jobs.g_jobs.mutex.unlock(root.io);
        if (jobs.g_jobs.list.items.len == 0) {
            try out.writeAll("no background jobs — the model starts one with bash {run_in_background: true}\n");
            try out.flush();
            return true;
        }
        try out.print("{s}background jobs{s}\n", .{ style.bold, style.reset });
        for (jobs.g_jobs.list.items) |job| {
            var sbuf: [32]u8 = undefined;
            const status: []const u8 = if (!job.done)
                "running"
            else if (job.killed)
                "killed"
            else if (job.exit_code) |c|
                (std.fmt.bufPrint(&sbuf, "exit {d}", .{c}) catch "exited")
            else
                "abnormal";
            try out.print("  {s}{d:>3}{s}  {s}{s:<8}{s} {d:>7} unread B  {s}\n", .{
                style.cyan,                               job.id,                  style.reset,
                if (job.done) style.dim else style.green, status,                  style.reset,
                job.buf.items.len - job.cursor,           utf8Prefix(job.cmd, 60),
            });
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/cost")) {
        const c = g_cost.snap(root.io);
        if (c.api_calls == 0) {
            try out.writeAll("no API calls yet this session\n");
            try out.flush();
            return true;
        }
        try out.print("{s}session usage{s}\n", .{ style.bold, style.reset });
        try out.print("  api calls: {d}", .{c.api_calls});
        if (c.sub_calls > 0) try out.print(" ({d} subscription, flat-rate)", .{c.sub_calls});
        if (c.unpriced_calls > 0) try out.print(" ({d} on unpriced models)", .{c.unpriced_calls});
        try out.print("\n  tokens:    {d} in ({d} cached) + {d} out\n", .{ c.in_tokens + c.cache_tokens, c.cache_tokens, c.out_tokens });
        try out.print("  cost:      {s}${d:.4}{s}{s}\n", .{
            style.green,                                                                                     c.usd, style.reset,
            if (c.sub_calls > 0 or c.unpriced_calls > 0) " (API-key calls with a known price only)" else "",
        });
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/mcp")) {
        const arg = std.mem.trim(u8, line["/mcp".len..], " \t");
        const reg = root.registry.?; // always present now
        if (std.mem.startsWith(u8, arg, "add")) {
            // /mcp add <name> <command> [args...]
            var it = std.mem.tokenizeAny(u8, arg["add".len..], " \t");
            const name = it.next() orelse {
                try out.writeAll("usage: /mcp add <name> <command> [args...]   e.g. /mcp add fs npx -y @modelcontextprotocol/server-filesystem .\n");
                try out.flush();
                return true;
            };
            const command = it.next() orelse {
                try out.writeAll("usage: /mcp add <name> <command> [args...]\n");
                try out.flush();
                return true;
            };
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(arena);
            while (it.next()) |a| try args.append(arena, a);
            const added = reg.addServer(name, command, args.items) catch |err| {
                try out.print("{s}✗ failed to add MCP server '{s}': {t}{s}\n", .{ style.red, name, err, style.reset });
                try out.flush();
                return true;
            };
            // Re-render the tool lists so the new tools reach the model.
            root.tools_anthropic = try renderRootTools(arena, .anthropic, &root_specs, reg.tools);
            root.tools_openai = try renderRootTools(arena, .openai, &root_specs, reg.tools);
            root.tools_responses = try renderRootTools(arena, .responses, &root_specs, reg.tools);
            const persisted = persistMcpServer(root.io, arena, name, command, args.items);
            var has_note = false;
            for (mcp_notes) |mn| if (std.mem.eql(u8, mn.server, name)) {
                has_note = true;
            };
            try out.print("{s}✓{s} connected MCP server {s}{s}{s} — {d} tool(s){s}{s}\n", .{
                style.green, style.reset, style.cyan, name, style.reset, added,
                if (persisted) " · saved to .mcp.json" else " · (not persisted)",
                if (has_note) " · restart the harness to add its context note" else "",
            });
            try out.flush();
            return true;
        }
        if (std.mem.eql(u8, arg, "trust")) {
            // Connect workspace .mcp.json servers that were skipped at startup
            // (consent declined / no --yolo), live, without a restart.
            const n = reg.trustWorkspace(mcp_config_path) catch |err| {
                try out.print("{s}✗ /mcp trust failed: {t}{s}\n", .{ style.red, err, style.reset });
                try out.flush();
                return true;
            };
            if (n == 0) {
                try out.writeAll("no untrusted workspace MCP server(s) to connect.\n");
            } else {
                // Re-render the tool lists so the new tools reach the model.
                root.tools_anthropic = try renderRootTools(arena, .anthropic, &root_specs, reg.tools);
                root.tools_openai = try renderRootTools(arena, .openai, &root_specs, reg.tools);
                root.tools_responses = try renderRootTools(arena, .responses, &root_specs, reg.tools);
                try out.print("{s}✓{s} trusted workspace — connected {d} MCP server(s); {d} tool(s) total\n", .{ style.green, style.reset, n, reg.tools.len });
            }
            try out.flush();
            return true;
        }
        // Plain /mcp: list servers (with tool counts) then tools.
        const pending = reg.pendingWorkspace(mcp_config_path);
        if (reg.servers.len == 0) {
            try out.writeAll("no MCP servers connected.\n  add one: /mcp add <name> <command> [args...]\n  e.g.   /mcp add fs npx -y @modelcontextprotocol/server-filesystem .\n");
        } else {
            try out.print("{d} MCP server(s), {d} tool(s):\n", .{ reg.servers.len, reg.tools.len });
            for (reg.servers, 0..) |srv, i| {
                try out.print("  {s}{s}{s}  (mcp {s}, {d} tool(s))\n", .{ style.cyan, srv.name, style.reset, srv.protocol_version, reg.toolCount(i) });
            }
            for (reg.tools) |t| try out.print("    {s}{s}{s}\n", .{ style.dim, t.qualified_name, style.reset });
            try out.writeAll("  add more: /mcp add <name> <command> [args...]\n");
        }
        if (pending > 0) try out.print("  {s}{d} workspace server(s) not connected — /mcp trust to connect them{s}\n", .{ style.dim, pending, style.reset });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/models")) {
        try out.writeAll("model                      ctx      compact@   provider    key  vision\n");
        for (pricing.models()) |m| {
            const has_key = keys.get(m.provider) != null;
            const current = std.mem.eql(u8, m.name, root.provider.model) and std.mem.eql(u8, m.provider, root.provider.id);
            const context = pricing.contextFor(m.provider, m.name);
            try out.print("{s:<26} {d:>5}k   {d:>5}k    {s:<11} {s}    {s}{s}\n", .{
                m.name,
                context / 1000,
                context / 10 * 8 / 1000,
                m.provider,
                if (has_key) "✓" else "—",
                if (visionModel(m.name)) "✓" else "—",
                if (current) "  ← current" else "",
            });
        }
        try out.print("(codex catalog: {s})\n", .{models_cache.codex_catalog_source});
        try out.print("(unknown models: {d}k ctx; claude* → anthropic, else → codegraff)\n", .{default_context / 1000});
        // Live LM Studio models: query the local server so loaded models show up
        // in /models without hand-typing their ids. Best-effort and silent if the
        // server is down. Only probe when the user actually uses lmstudio (key set
        // or it's the current provider) so we never make a stray localhost hit.
        if (keys.get("lmstudio") != null or std.mem.eql(u8, root.provider.id, "lmstudio")) lmstudio: {
            var base: []const u8 = "";
            for (provider_specs) |sp| {
                if (std.mem.eql(u8, sp.id, "lmstudio")) {
                    base = sp.url;
                    break;
                }
            }
            if (base.len == 0) break :lmstudio;
            const suffix = "/chat/completions";
            const root_url = if (std.mem.endsWith(u8, base, suffix)) base[0 .. base.len - suffix.len] else base;
            const url = std.fmt.allocPrint(arena, "{s}/models", .{root_url}) catch break :lmstudio;
            var aw: Io.Writer.Allocating = .init(arena);
            defer aw.deinit();
            const res = root.client.fetch(.{
                .location = .{ .url = url },
                .method = .GET,
                .response_writer = &aw.writer,
                .headers = .{ .user_agent = .{ .override = "simple-harness/" ++ harness_version } },
            }) catch break :lmstudio; // server not running → skip silently
            if (@intFromEnum(res.status) != 200) break :lmstudio;
            if (aw.writer.buffered().len > 256 * 1024) break :lmstudio;
            const parsed = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch break :lmstudio;
            if (parsed != .object) break :lmstudio;
            const data = parsed.object.get("data") orelse break :lmstudio;
            if (data != .array) break :lmstudio;
            const has_key = keys.get("lmstudio") != null;
            var printed_header = false;
            for (data.array.items) |item| {
                if (item != .object) continue;
                const idv = item.object.get("id") orelse continue;
                if (idv != .string) continue;
                const id = idv.string;
                if (std.mem.indexOf(u8, id, "embed") != null) continue; // skip embedding models — not chat targets
                if (!printed_header) {
                    try out.print("{s}lm studio (live @ {s}):{s}\n", .{ style.dim, root_url, style.reset });
                    printed_header = true;
                }
                const current = std.mem.eql(u8, root.provider.id, "lmstudio") and std.mem.eql(u8, id, root.provider.model);
                try out.print("{s:<26} {s:>6}   {s:>6}    {s:<11} {s}    {s}{s}\n", .{
                    id,
                    "—",
                    "—",
                    "lmstudio",
                    if (has_key) "✓" else "—",
                    if (visionModel(id)) "✓" else "—",
                    if (current) "  ← current" else "",
                });
            }
            if (printed_header) try out.print("{s}  copy an id above: /model lmstudio <id>{s}\n", .{ style.dim, style.reset });
        }
        try out.print("{s}tip: /model <name> (fuzzy) · /model <provider> (its default) · /model <provider> <model> (pin, e.g. 'codex gpt-5.5'){s}\n", .{ style.dim, style.reset });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/yolo")) {
        const on = root.approvals.?.toggleYolo(root.io);
        try out.print("yolo mode {s} — {s}\n", .{
            if (on) "ON" else "off",
            if (on) "bash runs without asking" else "unapproved bash commands prompt y/a/n",
        });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/trace")) {
        if (root.tracer) |tr| {
            const on = tr.toggle();
            try out.print("tracing {s} → {s}\n", .{ if (on) "ON" else "off", trace_path });
        } else {
            try out.writeAll("no trace file (failed to open at startup)\n");
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/fleet") or std.mem.startsWith(u8, line, "/fleet ")) {
        const arg = std.mem.trim(u8, line["/fleet".len..], " \t");
        if (arg.len == 0) {
            try out.print("fleet contribution: {s} — federated DGM (propose/submit/elite_pull). /fleet off to disable, /fleet on to enable (or GRAFF_FLEET=off).\n", .{if (main_mod.g_fleet) "ON" else "off"});
        } else if (std.mem.eql(u8, arg, "on")) {
            main_mod.g_fleet = true;
            try out.writeAll("fleet ON — this session's persona variants + scores contribute to the federated grid.\n");
        } else if (std.mem.eql(u8, arg, "off")) {
            main_mod.g_fleet = false;
            try out.writeAll("fleet off — no propose/submit/elite_pull this session (usage telemetry unaffected; /fleet on to re-enable).\n");
        } else {
            try out.writeAll("usage: /fleet [on|off]\n");
        }
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/save")) {
        const arg = std.mem.trim(u8, line["/save".len..], " \t");
        const name = if (arg.len == 0) root.session_name else arg;
        saveSession(root, arena, name) catch |err| {
            try out.print("save failed: {t}\n", .{err});
            try out.flush();
            return true;
        };
        root.session_name = name;
        try out.print("saved session → {s}{s}\n", .{ name, session_ext });
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/resume")) {
        const arg = std.mem.trim(u8, line["/resume".len..], " \t");
        var name: []const u8 = if (arg.len == 0) "last" else arg;
        // Bare /resume on a TTY: pick from the saved sessions interactively,
        // labeled by stored title + age instead of raw file names (#109).
        if (arg.len == 0 and main_mod.use_color and root.in != null) {
            var entries = listSavedSessions(root, arena);
            defer entries.deinit(arena);
            if (entries.items.len == 0) {
                try out.writeAll("(no saved sessions in cwd — /save creates one)\n");
                try out.flush();
                return true;
            }
            var sessions: std.ArrayList(PickItem) = .empty;
            defer sessions.deinit(arena);
            for (entries.items) |e| {
                const age = sessionAge(arena, root.io, e.updated_ms);
                const desc = if (e.title == null)
                    age
                else if (age.len > 0)
                    std.fmt.allocPrint(arena, "{s} · {s}", .{ age, e.base }) catch e.base
                else
                    e.base;
                try sessions.append(arena, .{ .name = e.title orelse e.base, .desc = desc });
            }
            const idx = listPicker(root, arena, out, "Resume session ›", sessions.items) orelse return true;
            name = entries.items[idx].base;
        }
        loadSession(root, keys.*, arena, name) catch |err| {
            switch (err) {
                error.FileNotFound => try out.print("no session named '{s}' ({s}{s} not found in cwd) — /sessions lists saved ones\n", .{ name, name, session_ext }),
                else => try out.print("resume failed: {t}\n", .{err}),
            }
            try out.flush();
            return true;
        };
        root.session_name = name;
        try out.print("resumed {s}{s} — {d} message(s), {s} via {s}{s}\n", .{
            name,                                 session_ext, root.messages.items.len, root.provider.model, root.provider.id,
            if (root.strict) " (strict)" else "",
        });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/sessions")) {
        var entries = listSavedSessions(root, arena);
        defer entries.deinit(arena);
        for (entries.items) |e| {
            const age = sessionAge(arena, root.io, e.updated_ms);
            const cur = if (std.mem.eql(u8, e.base, root.session_name)) "  ← current" else "";
            if (e.title) |t| {
                try out.print("  {s}  {s}{s}{s}{s}{s}{s}\n", .{ t, style.dim, e.base, if (age.len > 0) " · " else "", age, style.reset, cur });
            } else {
                try out.print("  {s}{s}{s}{s}{s}{s}\n", .{ e.base, style.dim, if (age.len > 0) "  " else "", age, style.reset, cur });
            }
        }
        if (entries.items.len == 0) try out.writeAll("(no saved sessions in cwd)\n");
        try out.flush();
        return true;
    }
    return false;
}

/// Terminal stage: an unmatched slash command gets a short error; bare
/// /help dumps the full command list. Always handles `line` — never returns
/// "unhandled" — so callers just `try` it after every tryHandle() misses.
pub fn handleRest(line: []const u8, out: *Io.Writer) !void {
    // Unknown slash command → a short error + pointer (only /help dumps the list).
    if (!std.mem.eql(u8, line, "/help")) {
        try out.print("unknown command '{s}' — /help for the list\n", .{line});
        try out.flush();
        return;
    }
    try out.writeAll(
        \\commands:  (a bare "/" opens this list as a filterable menu)
        \\  /model <name>   switch model/provider, fuzzy match (e.g. "sonnet", "opus")
        \\  /models         list known models, context windows, compaction points
        \\  /clear          wipe the conversation and start fresh
        \\  /new            start a fresh autosaved session
        \\  /rename <title> set the current session title
        \\  /goal [text]    set/show a standing objective (tracked as a checklist); /goal clear clears
        \\  /loop <prompt>  run an autonomous plan→act→verify pass
        \\  /plan           toggle plan mode: read-only explore + propose; writes/edits denied
        \\  /ultracode      toggle persistent workflow mode; bare opens on/off picker, or /ultracode on|off
        \\  /key [prov key] show API-key status; /key <provider> <key> adds one live (+ Keychain)
        \\  /login [tgt]    OAuth sign-in (no key to paste): codegraff | codex (alias oai) | kimi; bare → picker
        \\  /keepcontext    toggle keeping the conversation when /model switches wire format (default on)
        \\  /effort         reasoning picker: low|medium|high|xhigh|max|ultra (persists)
        \\  /reasoning      alias for /effort
        \\  /fast           codex only: priority service tier for lower latency (toggle, persists)
        \\  /strict         toggle "every message is a tool" mode
        \\  /yolo           toggle bash auto-approval (skip permission prompts)
        \\  /trace          toggle the JSONL event trace (harness.trace.jsonl)
        \\  /trajectory     show this session's agent tree — turns + spawned
        \\                  subagents with system-prompt fingerprints
        \\                  (harness.trajectory.jsonl, DGM-style)
        \\  /agents         list agent types — builtin personas + .harness/agents/*.md
        \\                  (spawn with subagent agent:"<name>")
        \\  /compact        summarize history into a fresh context
        \\  /rewind [n]     list past prompts; /rewind <n> drops prompt n+after & reverts its file edits
        \\  /image <path>   attach an image to your next message (vision models only)
        \\  /paste          attach the clipboard image — macOS; also Ctrl-V (⌘V can't be captured)
        \\  /save [name]    write the conversation to <name>.session.json (default: current)
        \\  /resume [name]  restore a saved conversation (no arg → interactive picker)
        \\  /sessions       list saved sessions in the cwd
        \\  /todo           show the current task list
        \\  /animation      pick the thinking animation (braille/pulse/orbit-dots/block-wave/
        \\                  shimmer/matrix/pacman/starfield/random/off); persists to settings
        \\  /mcp [add …]    list MCP servers/tools; /mcp add <name> <cmd> [args...] connects one live; /mcp trust connects skipped workspace servers
        \\  exit / /exit    quit (also: ctrl-d, or ctrl-c on an empty line)
        \\
        \\esc during a response interrupts the turn (what streamed stays in history).
        \\"always allow" answers persist to .harness/settings.json in the cwd.
        \\codeword: include "ultracode" in any message to force one multi-agent
        \\workflow turn; /ultracode on persists that behavior for future prompts.
        \\
        \\launch flags: --model <name> · --yolo (skip prompts) · -p "prompt" (one-shot) · --system-prompt/--append-system-prompt · --timing · --cost · --json (SDK protocol) · --help · --version
        \\subcommands: `graff login [codex]` (OAuth) · `graff key set <provider> <key>` (Keychain) · `graff --schema`
        \\
    );
    try out.flush();
}
