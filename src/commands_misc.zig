//! Misc slash commands + handleRest() fallback (600-line goal, #123).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const tool_balance = @import("tool_balance.zig"); // /tools: session tool-class tally
const codedbpro_report = @import("codedbpro_report.zig"); // /tools: licensed-gate fallback state
const provider_mod = @import("provider.zig");
const agent_mod = @import("agent.zig");
const util = @import("util.zig");
const doctor = @import("doctor.zig");
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

const goal_state = @import("goal_state.zig");
const goal_flow = @import("goal_flow.zig");
const prompts = @import("prompts.zig"); // #445: the transcript line's compaction flag resets with the conversation
const jobs = @import("jobs.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig"); // #416: which listed MCP tools are still schema-deferred
const subagent = @import("subagent.zig"); // #276 P0-3: g_agent_jobs, for /jobs

const models_table = @import("models_table.zig");

test { // main.zig is the test root, so this reference is what runs its tests
    _ = models_table;
}
const pricing = @import("pricing.zig");
const obs = @import("obs.zig");
const cache_hud = @import("prompt_cache_hud.zig");
const default_context = pricing.default_context;
const g_cost = &pricing.g_cost;
const pricing_db = @import("pricing_db.zig"); // #557: price-DB age for the /models footer
const models_cache = @import("models_cache.zig");
const kimi_catalog = @import("kimi_catalog.zig");
const providers = @import("providers.zig");
const command_catalog = @import("command_catalog.zig");
const side_question = @import("side_question.zig"); // #415 /btw
const peer_channel = @import("peer_channel.zig"); // #469 /tell + the /sessions "live now" section
const route_set = @import("route_set.zig"); // /routes: user-defined priced model lanes
const serde = @import("serde.zig");

const mcp_cli = @import("mcp_cli.zig");
const persistMcpServer = mcp_cli.persistMcpServer;
const persistMcpUrl = mcp_cli.persistMcpUrl;

const skills = @import("skills.zig");
const mcp_notes = skills.mcp_notes;

const vision = @import("vision.zig");
const visionModel = vision.visionModel;

const pickers = @import("pickers.zig");
const PickItem = pickers.PickItem;
const listPicker = pickers.listPicker;

const trace = @import("trace.zig");
const commands_privacy = @import("commands_privacy.zig");
const playbook_glue = @import("playbook_glue.zig"); // #381 /never: the durable user-constraint ledger
const learning_privacy = @import("learning_privacy.zig");

fn providerModelCount(provider_id: []const u8) usize {
    var count: usize = 0;
    for (pricing.models()) |model| if (std.mem.eql(u8, model.provider, provider_id)) {
        count += 1;
    };
    return count;
}

fn showModelsHealth(root: *Agent, keys: *Keys, arena: Allocator, out: *Io.Writer) !void {
    root.ensureStoredKeys(keys);
    providers.ensureModelQueryCatalogs(root, keys.*, "");
    const saved = serde.loadModel(root.io, arena, root.home);
    try out.print("{s}model health{s}\n", .{ style.bold, style.reset });
    try out.print("active: {s} via {s} · {d}k ctx · compact@{d}k{s}{s}\n", .{
        root.provider.model,
        root.provider.id,
        root.provider.context / 1000,
        root.provider.compactAt() / 1000,
        if (root.fallback_active) " · temporary fallback" else "",
        if (root.fallback_blocked) " · BLOCKED pending consent" else "",
    });
    if (saved) |preferred|
        try out.print("saved default: {s} via {s}\n", .{ preferred.model, preferred.pid })
    else
        try out.writeAll("saved default: none\n");

    var codex_models: usize = 0;
    for (pricing.models()) |model| if (std.mem.eql(u8, model.provider, "codex")) {
        codex_models += 1;
    };
    try out.print("Codex catalog: {s} · {d} model(s)\n", .{ models_cache.codex_catalog_source, codex_models });
    const transport = if (!main_mod.g_codex_ws)
        "SSE forced (GRAFF_CODEX_WS is off)"
    else if (root.ws_off)
        "SSE fallback (WebSocket failed this session)"
    else
        "WebSocket primary with automatic SSE fallback";
    try out.print("Codex transport: {s}\n", .{transport});

    if (root.fallback_allow.len == 0) {
        try out.writeAll("cross-provider fallback: off; same-provider rollout replacement allowed\n");
    } else {
        try out.writeAll("cross-provider fallback allowlist:");
        for (root.fallback_allow) |provider_id| try out.print(" {s}", .{provider_id});
        try out.writeByte('\n');
    }

    try out.writeAll("providers (credential values are never shown):\n");
    for (0..provider_mod.specCount()) |i| {
        const spec = provider_mod.specAt(i).?;
        const available = keys.get(spec.id) != null;
        const source = keys.source(spec.id);
        try out.print("  {s} {s:<11} {s:<12} {d:>2} model(s){s}\n", .{
            if (available) "✓" else "·",
            spec.id,
            if (available and source == .none) "resolved" else source.label(),
            providerModelCount(spec.id),
            if (std.mem.eql(u8, spec.id, root.provider.id)) "  ← active" else "",
        });
        if (!available) {
            if (std.mem.eql(u8, spec.id, "codex") or std.mem.eql(u8, spec.id, "codegraff") or std.mem.eql(u8, spec.id, "kimi"))
                try out.print("      fix: /login {s}\n", .{spec.id})
            else
                try out.print("      fix: /key {s} <key> or set {s}\n", .{ spec.id, spec.env_key });
        }
    }
    if (root.last_api_error != null) try out.writeAll("last request: provider/API failure recorded (details hidden; see trace for diagnostics)\n");
    try out.flush();
}

/// `/save <name>` and `/resume <name>`: a typed name is a slice of readline's
/// reused line buffer (readLine returns `buf.items`, cleared and regrown on the
/// next call), while root.session_name is read by every later autosave — so a
/// typed name is copied into the session arena, the same ownership /new and
/// /rename give theirs. An omitted name keeps the caller's owned fallback.
///
/// Both call sites are covered end-to-end by main_test.zig's "typed session
/// name survives readline reusing its line buffer" — a test against this
/// helper alone would stay green with either site reverted.
fn ownedSessionName(arena: Allocator, arg: []const u8, fallback: []const u8) Allocator.Error![]const u8 {
    return if (arg.len == 0) fallback else arena.dupe(u8, arg);
}

/// Try to handle a misc slash command. Returns false (line unhandled) if
/// `line` doesn't match any command in this file — the caller falls through
/// to handleRest() for the unknown-command/help terminal stage.
pub fn tryHandle(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (try @import("adopt.zig").trySlash(root.io, arena, root.home, line, out)) return true;
    if (try commands_privacy.tryHandle(root, line, out)) return true;
    if (try playbook_glue.command(root, arena, line, out)) return true; // #381 /never | /constraint
    if (std.mem.startsWith(u8, line, "/schedule") and (line.len == 9 or line[9] == ' ' or line[9] == '\t')) return @import("schedule.zig").slashCommand(root, arena, line, out);
    if (std.mem.startsWith(u8, line, "/adapter") and (line.len == 8 or line[8] == ' ' or line[8] == '\t')) return @import("channel_worker.zig").slashCommand(root, arena, line, out);
    if (try side_question.command(root, arena, line, out)) return true; // #415 /btw
    // #321: doctor.zig shipped with a catalog entry but no dispatch, so /doctor
    // was advertised in /help and the `/` menu while answering "unknown command".
    if (std.mem.eql(u8, line, "/doctor")) {
        const checks = try doctor.run(arena, doctor.snapshot(root, util.unixMs(root.io)));
        try out.writeAll(try doctor.render(arena, checks));
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/todo")) {
        const epoch = goal_state.currentEpoch(root.goal);
        try out.print("{s}\n", .{root.renderTodos(epoch)});
        const parked = goal_state.parkedOpenCount(root.todos.items, epoch);
        if (parked > 0) try out.print("(+{d} unfinished item(s) parked from an earlier goal \xe2\x80\x94 kept in the session, not steering)\n", .{parked});
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/jobs")) {
        jobs.g_jobs.mutex.lockUncancelable(root.io);
        if (jobs.g_jobs.list.items.len == 0) {
            try out.writeAll("no background bash jobs — the model starts one with bash {run_in_background: true}\n");
        } else {
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
                    style.accent,                             job.id,                  style.reset,
                    if (job.done) style.dim else style.green, status,                  style.reset,
                    job.buf.items.len - job.cursor,           utf8Prefix(job.cmd, 60),
                });
            }
        }
        jobs.g_jobs.mutex.unlock(root.io);

        // #276 P0-3: background subagents (subagent {run_in_background:true}),
        // same listing shape as bash jobs above.
        subagent.g_agent_jobs.mutex.lockUncancelable(root.io);
        if (subagent.g_agent_jobs.list.items.len == 0) {
            try out.writeAll("no background agents — the model starts one with subagent {run_in_background: true}\n");
        } else {
            try out.print("{s}background agents{s}\n", .{ style.bold, style.reset });
            for (subagent.g_agent_jobs.list.items) |job| {
                const status: []const u8 = if (!job.admitted)
                    "queued"
                else if (!job.done)
                    "running"
                else if (job.is_error)
                    "failed"
                else
                    "done";
                try out.print("  {s}{d:>3}{s}  {s}{s:<8}{s} {d:>7}ms  {s}\n", .{
                    style.accent,                             job.id,                    style.reset,
                    if (job.done) style.dim else style.green, status,                    style.reset,
                    job.usage.duration_ms,                    utf8Prefix(job.label, 60),
                });
            }
        }
        subagent.g_agent_jobs.mutex.unlock(root.io);
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/debug") or std.mem.eql(u8, line, "/cache")) {
        if (std.mem.eql(u8, line, "/debug")) try obs.renderHud(out) else try cache_hud.render(out);
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/cost") or std.mem.eql(u8, line, "/usage")) {
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
    if (std.mem.eql(u8, line, "/tools")) {
        var snap = tool_balance.snapshot();
        const text = try tool_balance.render(arena, &snap, main_mod.g_codedbpro_licensed, codedbpro_report.fallbackOpen());
        try out.writeAll(text);
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/mcp")) {
        const arg = std.mem.trim(u8, line["/mcp".len..], " \t");
        const reg = root.registry.?; // always present now
        if (@import("mcp_boot.zig").joinPending(reg)) {
            root.invalidateRootTools();
            try root.ensureRootTools(root.provider.kind);
        }
        if (std.mem.startsWith(u8, arg, "add")) {
            // /mcp add <name> <command> [args...] or <name> --url <URL>
            var it = std.mem.tokenizeAny(u8, arg["add".len..], " \t");
            const name = it.next() orelse {
                try out.writeAll("usage: /mcp add <name> <command> [args...] | /mcp add <name> --url <URL>\n");
                try out.flush();
                return true;
            };
            const command = it.next() orelse {
                try out.writeAll("usage: /mcp add <name> <command> [args...] | /mcp add <name> --url <URL>\n");
                try out.flush();
                return true;
            };
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(arena);
            while (it.next()) |a| try args.append(arena, a);
            const is_remote = std.mem.eql(u8, command, "--url");
            if (is_remote and args.items.len != 1) {
                try out.writeAll("usage: /mcp add <name> --url <URL>\n");
                try out.flush();
                return true;
            }
            const added = (if (is_remote)
                reg.addRemoteServer(name, args.items[0], &.{})
            else
                reg.addServer(name, command, args.items)) catch |err| {
                try out.print("{s}✗ failed to add MCP server '{s}': {t}{s}\n", .{ style.red, name, err, style.reset });
                try out.flush();
                return true;
            };
            // Re-render the active catalog so the new tools reach the model;
            // inactive provider formats stay lazy until a later switch.
            root.invalidateRootTools();
            @import("prompt_cache_hud.zig").noteBust(.mcp);
            try root.ensureRootTools(root.provider.kind);
            root.rebaseContextMeter();
            const persisted = if (is_remote)
                persistMcpUrl(root.io, arena, name, args.items[0], &.{})
            else
                persistMcpServer(root.io, arena, name, command, args.items);
            var has_note = false;
            for (mcp_notes) |mn| if (std.mem.eql(u8, mn.server, name)) {
                has_note = true;
            };
            try out.print("{s}✓{s} connected MCP server {s}{s}{s} — {d} tool(s){s}{s}\n", .{
                style.green, style.reset, style.accent, name, style.reset, added,
                if (persisted) " · saved to .mcp.json" else " · (not persisted)",
                if (has_note) " · restart the harness to add its context note" else "",
            });
            try out.flush();
            return true;
        }
        if (std.mem.eql(u8, arg, "trust")) {
            // Connect the .mcp.json / ~/.codegraff/mcp.json servers that were
            // skipped at startup (consent declined / no --yolo), live, without
            // a restart.
            const n = reg.trustWorkspace(mcp_config_path) catch |err| {
                try out.print("{s}✗ /mcp trust failed: {t}{s}\n", .{ style.red, err, style.reset });
                try out.flush();
                return true;
            };
            if (n == 0) {
                try out.writeAll("no untrusted MCP server(s) left to connect.\n");
            } else {
                // Re-render the active catalog; other wire formats remain lazy.
                root.invalidateRootTools();
                try root.ensureRootTools(root.provider.kind);
                root.rebaseContextMeter();
                try out.print("{s}✓{s} trusted the configured servers — connected {d} MCP server(s); {d} tool(s) total\n", .{ style.green, style.reset, n, reg.tools.len });
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
                // #327: if the modern probe ran and this connection landed on
                // legacy anyway, say why — a silent downgrade is invisible here
                // otherwise, since a fallback and a genuinely-legacy server
                // print the identical revision.
                const probe_note = if (srv.probe_fallback) |reason| reason.note() else "";
                try out.print("  {s}{s}{s}  (mcp {s}, {d} tool(s)){s}{s}{s}\n", .{ style.accent, srv.name, style.reset, srv.protocol_version, reg.toolCount(i), style.dim, probe_note, style.reset });
            }
            // #416: a deferred tool is registered but carries no schema yet, so
            // say so — otherwise the difference is invisible from here.
            for (reg.tools) |t| try out.print("    {s}{s}{s}{s}\n", .{ style.dim, t.qualified_name, if (mcp_schema_gate.isDeferred(reg.tools, t)) "  schema deferred (#416); the model loads it on demand" else "", style.reset });
            try out.writeAll("  add more: /mcp add <name> <command> [args...]\n");
        }
        if (pending > 0) try out.print("  {s}{d} configured server(s) not connected — /mcp trust to connect them{s}\n", .{ style.dim, pending, style.reset });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/models health")) {
        try showModelsHealth(root, keys, arena, out);
        return true;
    }
    if (std.mem.eql(u8, line, "/models")) {
        root.ensureStoredKeys(keys);
        providers.ensureModelQueryCatalogs(root, keys.*, "");
        // The explicit listing is the freshness moment: live-refresh the
        // router-catalog providers, bypassing the per-process latch and 6h
        // TTL that made /models show a boot-time snapshot until restart.
        const pinged = providers.refreshModelListing(root, keys.*);
        if (pinged > 0) try out.print("{s}(pinged {d} provider catalog(s) live){s}\n", .{ style.dim, pinged, style.reset });
        // `cost` answers what a model name cannot: the same model through codex
        // (plan), codegraff (credits) and openai (api) is three different
        // bills. Same wording as the TUI picker; the surfaces must agree.
        try out.writeAll(models_table.header);
        try models_table.writeRows(out, arena, pricing.models(), keys.*, root.provider.model, root.provider.id, visionModel);
        try out.print("(codex catalog: {s})\n", .{models_cache.codex_catalog_source});
        try out.print("(kimi catalog: {s})\n", .{kimi_catalog.catalog_source});
        if (pricing_db.source.len != 0) try out.print("(price db: {s})\n", .{pricing_db.source});
        try out.print("(unknown models: {d}k ctx; claude* → anthropic, else → codegraff)\n", .{default_context / 1000});
        // Live LM Studio models: query the local server so loaded models show up
        // in /models without hand-typing their ids. Best-effort and silent if the
        // server is down. Only probe when the user actually uses lmstudio (key set
        // or it's the current provider) so we never make a stray localhost hit.
        if (keys.get("lmstudio") != null or std.mem.eql(u8, root.provider.id, "lmstudio")) lmstudio: {
            const base = (provider_mod.specFor("lmstudio") orelse break :lmstudio).url;
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
        try out.print("yolo mode {s}{s}{s} — {s}\n", .{
            if (on) style.red else style.green,
            if (on) "ON" else "off",
            style.reset,
            if (on) "bash runs without asking" else "unapproved bash commands prompt y/a/n",
        });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/trace")) {
        if (root.tracer) |tr| {
            const on = tr.toggle();
            try out.print("tracing {s} → {s}\n", .{ if (on) "ON" else "off", tr.path });
        } else {
            try out.writeAll("no trace file (failed to open at startup)\n");
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/fleet") or std.mem.startsWith(u8, line, "/fleet ")) {
        const arg = std.mem.trim(u8, line["/fleet".len..], " \t");
        if (arg.len == 0) {
            try out.print("fleet master switch: {s} · learning privacy: {s}. /fleet off kills contribution; /privacy controls what may leave.\n", .{ if (main_mod.g_fleet) "ON" else "off", learning_privacy.current().label() });
        } else if (std.mem.eql(u8, arg, "on")) {
            main_mod.g_fleet = true;
            try out.writeAll("fleet master switch ON — contribution still follows /privacy (Local sends nothing).\n");
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
        // Caught, not propagated: an error out of here reaches mainloop's
        // unguarded handleCommand call and ends the REPL, where every other
        // way /save can fail just prints and returns to the prompt.
        const name = ownedSessionName(arena, arg, root.session_name) catch |err| {
            try out.print("save failed: {t}\n", .{err});
            try out.flush();
            return true;
        };
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
        root.ensureStoredKeys(keys);
        const arg = std.mem.trim(u8, line["/resume".len..], " \t");
        var name: []const u8 = ownedSessionName(arena, arg, "last") catch |err| {
            try out.print("resume failed: {t}\n", .{err});
            try out.flush();
            return true;
        };
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
            name = entries.items[idx].base; // arena-owned by listSavedSessions, so it outlives the turn too
        }
        loadSession(root, keys, arena, name) catch |err| {
            switch (err) {
                error.FileNotFound => try out.print("no session named '{s}' ({s}{s} not found in cwd) — /sessions lists saved ones\n", .{ name, name, session_ext }),
                else => try out.print("resume failed: {t}\n", .{err}),
            }
            try out.flush();
            return true;
        };
        root.session_name = name;
        // #445: after the rename, so the re-arm reads the resumed session. The
        // history just loaded IS that file's contents, so the #410 line would
        // again only describe what the live window already holds.
        prompts.resetSessionCompacted(root, arena);
        // The third restore path (#318): --goal outranks the restored goal here
        // too, idempotently, or /resume was the one door that silently dropped it.
        if (root.goal_flag) |g| root.pending_goal_note = goal_flow.reapplyFlagGoal(arena, root, g, util.unixMs(root.io)) catch null;
        try out.print("resumed {s}{s} — {d} message(s), {s} via {s}{s}\n", .{
            name,                                 session_ext, root.messages.items.len, root.provider.model, root.provider.id,
            if (root.strict) " (strict)" else "",
        });
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/tell") and (line.len == 5 or line[5] == ' ' or line[5] == '\t')) return peer_channel.tellCommand(root, arena, line, out); // #469
    if (std.mem.startsWith(u8, line, "/peek") and (line.len == 5 or line[5] == ' ' or line[5] == '\t')) return peer_channel.peekCommand(root, arena, line, out); // #469
    if (std.mem.startsWith(u8, line, "/routes") and (line.len == 7 or line[7] == ' ' or line[7] == '\t')) return route_set.command(root, keys, arena, line, out); // user-defined priced lanes
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
        try peer_channel.writeLiveSection(root, arena, out); // #469: co-resident live sessions, with goals
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
    try @import("help.zig").render(out);
    try out.flush();
}
