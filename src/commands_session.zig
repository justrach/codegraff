//! Session/environment slash commands, split out of main.zig's handleCommand
//! (600-line goal, issue #123): /clear /new /rename /goal /loop /bash /agents
//! /animation /theme /hooks /skills /trajectory /plan.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const util = @import("util.zig");
const tools_mod = @import("tools.zig");
const session_mod = @import("session.zig");
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const ToolCall = tools_mod.ToolCall;
const saveSession = session_mod.saveSession;
const unixMs = util.unixMs;
const utf8Prefix = util.utf8Prefix;
const session_ext = session_mod.session_ext;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const exec = @import("exec.zig");
const execTool = exec.execTool;

const fleet = @import("fleet.zig");
const promoteAgents = fleet.promoteAgents;

const scoring = @import("scoring.zig");
const promptFingerprint = scoring.promptFingerprint;

const anim = @import("anim.zig");

const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;

const trace = @import("trace.zig");
const trajectory_path = trace.trajectory_path;

const skills = @import("skills.zig");
const skillIndex = skills.skillIndex;
const skillDisabled = skills.skillDisabled;
const skillInstalled = skills.skillInstalled;
const saveSkillSetting = skills.saveSkillSetting;
const skills_registry = skills.skills_registry;

const title_mod = @import("title.zig");
const setTerminalTitle = title_mod.setTerminalTitle;

/// Try to handle a session/environment slash command. Returns false (line
/// unhandled) if `line` doesn't match any command in this file — the caller
/// (handleCommand in main.zig) then tries the next peer module.
pub fn tryHandle(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    _ = keys; // unused in this file's command set; kept for a uniform tryHandle signature
    if (std.mem.eql(u8, line, "/clear")) {
        root.messages = std.json.Array.init(arena);
        root.last_context_tokens = 0;
        root.last_cache_read = 0;
        root.tui_header_shown = false;
        root.session_title = null; // re-summarize the now-empty conversation
        root.ai_title_done = false;
        root.todos.clearRetainingCapacity();
        saveSession(root, arena, root.session_name) catch {};
        setTerminalTitle(out, "Chat", main_mod.g_cwd_display);
        try out.writeAll("context cleared — fresh conversation\n");
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/new")) {
        root.messages = std.json.Array.init(arena);
        root.last_context_tokens = 0;
        root.last_cache_read = 0;
        root.todos.clearRetainingCapacity();
        root.goal = null;
        root.ultracode_mode = false;
        root.session_title = null;
        root.ai_title_done = false; // let the new session earn its own AI title
        root.tui_header_shown = false;
        root.session_name = try std.fmt.allocPrint(arena, "session-{d}", .{unixMs(root.io)});
        saveSession(root, arena, root.session_name) catch {};
        try out.print("new session → {s}{s}\n", .{ root.session_name, session_ext });
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/rename")) {
        const title = std.mem.trim(u8, line["/rename".len..], " \t");
        if (title.len == 0) {
            try out.writeAll("usage: /rename <title>\n");
        } else {
            root.session_title = try arena.dupe(u8, title);
            root.ai_title_done = true; // a manual /rename wins over the auto-titler
            saveSession(root, arena, root.session_name) catch {};
            try out.print("session title → {s}\n", .{title});
        }
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/goal")) {
        const text = std.mem.trim(u8, line["/goal".len..], " \t");
        if (text.len == 0) {
            if (root.goal) |goal| try out.print("Current goal: {s}\nClear it with /goal clear.\n", .{goal}) else try out.writeAll("No active goal. Set one with /goal <objective>.\n");
        } else if (std.ascii.eqlIgnoreCase(text, "clear") or std.ascii.eqlIgnoreCase(text, "off")) {
            root.goal = null;
            saveSession(root, arena, root.session_name) catch {};
            try out.writeAll("Goal cleared. Future turns will not get goal steering.\n");
        } else {
            root.goal = try arena.dupe(u8, text);
            saveSession(root, arena, root.session_name) catch {};
            try out.print("Goal set: {s}\nI'll track it as a live checklist (todo_write) and work through it across turns.\n", .{text});
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/loop")) {
        try out.writeAll("usage: /loop <prompt> — run an autonomous plan→act→verify pass.\n");
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/bash") or std.mem.startsWith(u8, line, "/bash ")) {
        const cmd = std.mem.trim(u8, line["/bash".len..], " \t\r\n");
        if (cmd.len == 0) {
            try out.writeAll("usage: /bash <command>\n");
            try out.flush();
            return true;
        }
        var input_obj: std.json.ObjectMap = .empty;
        try input_obj.put(arena, "command", .{ .string = cmd });
        const call: ToolCall = .{ .id = "slash-bash", .name = "bash", .input = .{ .object = input_obj } };
        if (try root.gateTool(call)) |denied| {
            try out.print("{s}\n", .{denied.text});
            try out.flush();
            return true;
        }
        const result = execTool(.{
            .gpa = root.gpa,
            .io = root.io,
            .client = root.client,
            .provider = root.provider,
            .registry = root.registry,
            .from_sub = false,
            .approvals = root.approvals,
            .tracer = root.tracer,
            .snapshots = root.snapshots,
            .tools_used = &root.tools_used,
        }, call);
        defer root.gpa.free(result.text);
        try out.writeAll(result.text);
        if (result.text.len == 0 or result.text[result.text.len - 1] != '\n') try out.writeAll("\n");
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/agents promote")) {
        const personal = std.mem.indexOf(u8, line, "--personal") != null or std.mem.indexOf(u8, line, "--global") != null;
        try out.print("{s}promoting local champions{s} → {s} tier (from {s})\n", .{ style.bold, style.reset, if (personal) "personal ~/.harness/agents" else "private ./.harness/agents", trajectory_path });
        const n = promoteAgents(root.io, root.gpa, out, fleet.g_home, personal);
        if (n > 0) try out.print("{s}✓ promoted {d} niche(s) — they load on next start{s}\n", .{ style.green, n, style.reset });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/agents")) {
        try out.print("{s}agent types{s} — MAP-Elites niches: builtins + {s}/*.md (file shadows builtin); spawn via subagent agent:\"<name>\"\n", .{ style.bold, style.reset, fleet.agents_dir });
        for (fleet.g_agent_types) |t| {
            const fp = promptFingerprint(t.prompt);
            try out.print("  {s}{s:<14}{s} {s} {s}{s}{s}", .{
                style.cyan,
                t.name,
                style.reset,
                if (t.builtin) "builtin" else "file   ",
                style.dim,
                &fp,
                style.reset,
            });
            if (t.score) |sc| try out.print(" {s}score {d:.2}{s}", .{ style.green, sc, style.reset });
            try out.print("  {s}\n", .{t.desc});
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/animation") or std.mem.startsWith(u8, line, "/animation ")) {
        const arg = std.mem.trim(u8, line["/animation".len..], " ");
        if (arg.len == 0) {
            const current: []const u8 = if (anim.g_anim_off) "off" else if (anim.g_anim_random) "random" else anim.anims[anim.g_anim_index].name;
            try out.print("{s}thinking animations{s} (current: {s}{s}{s}) — /animation <name> picks one, persists to {s}\n", .{ style.bold, style.reset, style.cyan, current, style.reset, Approvals.settings_path });
            for (anim.anims) |a| {
                try out.print("  {s}{s:<12}{s} {s}  preview: ", .{ style.cyan, a.name, style.reset, a.desc });
                try a.frame(out, 3);
                try out.writeAll("\n");
            }
            try out.print("  {s}{s:<12}{s} a different one each request\n  {s}{s:<12}{s} no animation\n", .{ style.cyan, "random", style.reset, style.cyan, "off", style.reset });
            try out.flush();
            return true;
        }
        if (std.mem.eql(u8, arg, "off")) {
            anim.g_anim_off = true;
            anim.g_anim_random = false;
        } else if (std.mem.eql(u8, arg, "random")) {
            anim.g_anim_off = false;
            anim.g_anim_random = true;
        } else if (anim.animIndex(arg)) |i| {
            anim.g_anim_off = false;
            anim.g_anim_random = false;
            anim.g_anim_index = i;
        } else {
            try out.print("unknown animation '{s}' — /animation lists them\n", .{arg});
            try out.flush();
            return true;
        }
        const saved = anim.saveAnimationSetting(root.io, root.gpa, arg);
        try out.print("{s}✓ thinking animation: {s}{s}", .{ style.green, arg, style.reset });
        if (!anim.g_anim_off and !anim.g_anim_random) {
            try out.writeAll("  ");
            try anim.anims[anim.g_anim_index].frame(out, 3);
        }
        try out.writeAll("\n");
        if (!saved) try out.print("{s}warning: could not persist to {s} — lasts only this session{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/theme") or std.mem.startsWith(u8, line, "/theme ")) {
        const arg = std.mem.trim(u8, line["/theme".len..], " ");
        if (arg.len == 0) {
            const current: []const u8 = if (anim.g_theme) |i| anim.themes[i].name else "off";
            try out.print("{s}color themes{s} (current: {s}{s}{s}) — /theme <name> applies + persists, /theme off resets to your terminal default\n", .{ style.bold, style.reset, style.cyan, current, style.reset });
            for (anim.themes) |t| try out.print("  {s}{s:<12}{s} {s}\n", .{ style.cyan, t.name, style.reset, t.desc });
            try out.print("  {s}{s:<12}{s} terminal default (no theme)\n", .{ style.cyan, "off", style.reset });
            try out.flush();
            return true;
        }
        if (std.ascii.eqlIgnoreCase(arg, "off") or std.ascii.eqlIgnoreCase(arg, "none")) {
            if (anim.g_theme != null) out.writeAll(anim.theme_reset) catch {};
            anim.g_theme = null;
        } else if (anim.themeIndex(arg)) |i| {
            anim.g_theme = i;
            out.writeAll(anim.themes[i].seq) catch {};
            out.flush() catch {};
        } else {
            try out.print("unknown theme '{s}' — /theme lists them\n", .{arg});
            try out.flush();
            return true;
        }
        const saved = anim.saveThemeSetting(root.io, root.gpa, arg);
        const shown: []const u8 = if (anim.g_theme) |i| anim.themes[i].name else "off";
        try out.print("{s}✓ theme: {s}{s}\n", .{ style.green, shown, style.reset });
        if (!saved) try out.print("{s}warning: could not persist to {s} — lasts only this session{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/hooks")) {
        try out.print("{s}codedb guard{s} (built-in, issue #626): {s} — blocks bash grep/sed/cat/wc on indexed source files and redirects to the codedb tool; GRAFF_NO_CODEDB_GUARD=1 disables.\n", .{ style.bold, style.reset, if (main_mod.g_codedb_guard) "on" else "off" });
        if (main_mod.g_hooks.total() == 0) {
            try out.print("no lifecycle hooks. Add them to {s}:\n  {s}{{\"hooks\": {{\"pre_tool\": [{{\"match\": \"bash\", \"command\": \"./guard.sh\"}}]}}}}{s}\n  events: pre_tool (exit 2 blocks, stderr → model) · post_tool · turn_end; loaded at startup\n", .{ Approvals.settings_path, style.dim, style.reset });
            try out.flush();
            return true;
        }
        try out.print("{s}lifecycle hooks{s} (from {s}; event JSON on stdin, pre_tool exit 2 blocks):\n", .{ style.bold, style.reset, Approvals.settings_path });
        inline for (.{ "pre_tool", "post_tool", "turn_end" }) |ev| {
            for (@field(main_mod.g_hooks, ev)) |h| {
                try out.print("  {s}{s:<9}{s} match {s}{s:<16}{s} {d}ms  {s}\n", .{ style.cyan, ev, style.reset, style.dim, h.match, style.reset, h.timeout_ms, h.command });
            }
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/skills") or std.mem.startsWith(u8, line, "/skills ")) {
        const rest = std.mem.trim(u8, line["/skills".len..], " ");
        if (std.mem.startsWith(u8, rest, "remove ")) {
            const name = std.mem.trim(u8, rest["remove ".len..], " ");
            if (skillIndex(name)) |i| {
                if (main_mod.g_skill_disabled[i]) {
                    try out.print("{s} is already disabled\n", .{name});
                } else {
                    main_mod.g_skill_disabled[i] = true;
                    const saved = saveSkillSetting(root.io, root.gpa, name, false);
                    try out.print("{s}✓ {s} disabled{s} — ignored even when its binaries are on PATH (webfetch falls back, no context note); /skills add {s} re-enables\n", .{ style.green, name, style.reset, name });
                    if (!saved) try out.print("{s}warning: could not persist to {s} — the opt-out lasts only this session{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
                }
                try out.flush();
                return true;
            }
            try out.print("unknown skill: {s} — /skills lists the registry\n", .{name});
            try out.flush();
            return true;
        }
        if (std.mem.startsWith(u8, rest, "add ")) {
            const name = std.mem.trim(u8, rest[4..], " ");
            for (skills_registry) |sk| {
                if (!std.mem.eql(u8, sk.name, name)) continue;
                if (skillDisabled(sk.name)) {
                    main_mod.g_skill_disabled[skillIndex(sk.name).?] = false;
                    const saved = saveSkillSetting(root.io, root.gpa, sk.name, true);
                    try out.print("{s}✓ {s} re-enabled{s}{s}\n", .{ style.green, sk.name, style.reset, if (skillInstalled(root.io, sk)) " — restart the harness to add its context note" else "" });
                    if (!saved) try out.print("{s}warning: could not persist to {s}{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
                    if (skillInstalled(root.io, sk)) {
                        try out.flush();
                        return true;
                    }
                    // not installed: fall through to the installer below
                }
                if (skillInstalled(root.io, sk)) {
                    try out.print("{s} is already installed\n", .{sk.name});
                    try out.flush();
                    return true;
                }
                try out.print("installing {s}{s}{s}: {s}{s}{s}\n", .{ style.cyan, sk.name, style.reset, style.dim, sk.install, style.reset });
                try out.flush();
                // The user typed the install command themselves — that's the
                // consent; the installer runs with our stdio so its progress
                // and any sudo prompt reach the terminal directly.
                var child = std.process.spawn(root.io, .{ .argv = &.{ "/bin/sh", "-c", sk.install } }) catch |err| {
                    try out.print("failed to launch installer: {t}\n", .{err});
                    try out.flush();
                    return true;
                };
                const term = child.wait(root.io) catch {
                    try out.writeAll("installer did not exit cleanly\n");
                    try out.flush();
                    return true;
                };
                const ok = term == .exited and term.exited == 0 and skillInstalled(root.io, sk);
                if (ok) {
                    try out.print("{s}✓ {s} installed{s} — usable via bash now; restart the harness to add its context note\n", .{ style.green, sk.name, style.reset });
                } else {
                    try out.print("{s}{s} install did not complete{s} — run it manually: {s}\n", .{ style.yellow, sk.name, style.reset, sk.install });
                }
                try out.flush();
                return true;
            }
            try out.print("unknown skill: {s} — /skills lists the registry\n", .{name});
            try out.flush();
            return true;
        }
        try out.print("{s}skills{s} — optional companion tools (codex-style; one context line each when installed)\n", .{ style.bold, style.reset });
        for (skills_registry) |sk| {
            const inst = skillInstalled(root.io, sk);
            const disabled = skillDisabled(sk.name);
            const state: []const u8 = if (disabled) "disabled     " else if (inst) "installed    " else "not installed";
            try out.print("  {s}{s:<8}{s} {s}{s}{s}  {s}\n", .{
                style.cyan,                                                           sk.name, style.reset,
                if (disabled) style.yellow else if (inst) style.green else style.dim, state,   style.reset,
                sk.desc,
            });
        }
        try out.writeAll("  install/enable: /skills add <name> · disable: /skills remove <name>\n");
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/trajectory")) {
        const data = Io.Dir.cwd().readFileAlloc(root.io, trajectory_path, arena, .limited(4 << 20)) catch "";
        const S = struct {
            fn str(o: std.json.ObjectMap, k: []const u8) []const u8 {
                const v = o.get(k) orelse return "";
                return if (v == .string) v.string else "";
            }
            fn int(o: std.json.ObjectMap, k: []const u8) i64 {
                const v = o.get(k) orelse return 0;
                return if (v == .integer) v.integer else 0;
            }
            fn flag(o: std.json.ObjectMap, k: []const u8) bool {
                const v = o.get(k) orelse return false;
                return v == .bool and v.bool;
            }
            // Latest score recorded for a prompt fingerprint, across the
            // whole archive (scores persist between sessions).
            fn scoreFor(all: []const std.json.ObjectMap, sha: []const u8) ?f64 {
                var found: ?f64 = null;
                for (all) |o| {
                    if (!std.mem.eql(u8, str(o, "kind"), "score")) continue;
                    if (!std.mem.eql(u8, str(o, "prompt_sha"), sha)) continue;
                    const v = o.get("score") orelse continue;
                    found = switch (v) {
                        .float => |x| x,
                        .integer => |x| @floatFromInt(x),
                        else => found,
                    };
                }
                return found;
            }
        };
        var objs: std.ArrayList(std.json.ObjectMap) = .empty;
        var it = std.mem.tokenizeScalar(u8, data, '\n');
        while (it.next()) |ln| {
            const v = std.json.parseFromSliceLeaky(Value, arena, ln, .{ .allocate = .alloc_always }) catch continue;
            if (v == .object) objs.append(arena, v.object) catch {};
        }
        // Tree shows the CURRENT session (ids restart per session); scores
        // come from the whole archive.
        var session_start: usize = 0;
        for (objs.items, 0..) |o, i| {
            if (std.mem.eql(u8, S.str(o, "kind"), "session")) session_start = i + 1;
        }
        const session = objs.items[session_start..];
        var turns: usize = 0;
        for (session) |o| {
            if (std.mem.eql(u8, S.str(o, "kind"), "turn")) turns += 1;
        }
        if (turns == 0) {
            try out.writeAll("no trajectory recorded yet — run a turn first (the archive lives in harness.trajectory.jsonl)\n");
            try out.flush();
            return true;
        }
        try out.print("{s}session trajectory{s} — {d} turn(s); archive: {s} ({d} record(s) total)\n", .{ style.bold, style.reset, turns, trajectory_path, objs.items.len });
        for (session) |o| {
            if (!std.mem.eql(u8, S.str(o, "kind"), "turn")) continue;
            const turn_id = S.int(o, "id");
            out.print("{s}●{s} turn {d} {s} {d}ms · prompt {s}{s}{s}{s} · {s}", .{
                style.cyan,
                style.reset,
                turn_id,
                if (S.flag(o, "ok")) "✓" else "✗",
                S.int(o, "ms"),
                style.dim,
                S.str(o, "prompt_sha"),
                if (S.flag(o, "prompt_mutated")) " (mutated)" else "",
                style.reset,
                utf8Prefix(S.str(o, "task"), 80),
            }) catch {};
            if (S.scoreFor(objs.items, S.str(o, "prompt_sha"))) |sc|
                out.print(" {s}· score {d:.2}{s}", .{ style.green, sc, style.reset }) catch {};
            out.writeAll("\n") catch {};
            // children: subagents / workflow tasks spawned during this turn
            var remaining: usize = 0;
            for (session) |c| {
                if (S.int(c, "parent") == turn_id and !std.mem.eql(u8, S.str(c, "kind"), "turn")) remaining += 1;
            }
            for (session) |c| {
                if (S.int(c, "parent") != turn_id or std.mem.eql(u8, S.str(c, "kind"), "turn")) continue;
                remaining -= 1;
                out.print("  {s} {s} {s} {d}ms · prompt {s}{s}{s}{s} · {s}", .{
                    if (remaining == 0) "└─" else "├─",
                    S.str(c, "label"),
                    if (S.flag(c, "ok")) "✓" else "✗",
                    S.int(c, "ms"),
                    style.dim,
                    S.str(c, "prompt_sha"),
                    if (S.flag(c, "prompt_mutated")) " (variant)" else "",
                    style.reset,
                    utf8Prefix(S.str(c, "task"), 70),
                }) catch {};
                if (S.scoreFor(objs.items, S.str(c, "prompt_sha"))) |sc|
                    out.print(" {s}· score {d:.2}{s}", .{ style.green, sc, style.reset }) catch {};
                out.writeAll("\n") catch {};
            }
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/plan")) {
        main_mod.plan_mode = !main_mod.plan_mode;
        if (main_mod.plan_mode) {
            try out.print("plan mode {s}on{s} — read-only: the agent explores and proposes; writes/edits/mutating bash are denied. /plan again to execute.\n", .{ style.cyan, style.reset });
        } else {
            try out.writeAll("plan mode off — tools may modify things again (normal gating applies)\n");
        }
        try out.flush();
        return true;
    }
    return false;
}
