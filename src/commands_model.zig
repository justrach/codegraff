//! Model/provider/thinking slash commands, split out of main.zig's
//! handleCommand (600-line goal, issue #123): /model /compact /rewind /fast
//! /thinking /title /ultracode /effort /keepcontext /fallback /key /login /image
//! /paste /strict.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const ansi = @import("ansi.zig");
const style = &ansi.style;
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const storeKey = keys_cli.storeKey;
const repl_glue = @import("repl_glue.zig");
const saveThinkingSettings = repl_glue.saveThinkingSettings;
const keys_cli = @import("keys_cli.zig");
const isLocalUrl = keys_cli.isLocalUrl;
const openAiModelsUrl = keys_cli.openAiModelsUrl;
const fetchOpenAIModels = keys_cli.fetchOpenAIModels;
const harness_version = main_mod.harness_version;
const Rewound = @import("tools.zig").Rewound; // what one /rewind restored/skipped

const pricing = @import("pricing.zig");
const kimi_catalog = @import("kimi_catalog.zig");
const resolveModelName = pricing.resolveModelName;

const pickers = @import("pickers.zig");
const modelPicker = pickers.modelPicker;
const PickItem = pickers.PickItem;
const listPicker = pickers.listPicker;
const listPickerAt = pickers.listPickerAt;
const pickUltracodeMode = pickers.pickUltracodeMode;
const reloadLoginKey = pickers.reloadLoginKey;
const offerProviderAuth = pickers.offerProviderAuth;

const providers = @import("providers.zig");
const switchProvider = providers.switchProvider;
const fallback_config = @import("fallback_config.zig");
const serde = @import("serde.zig");

const oauth = @import("oauth.zig");
const images_command = @import("images_command.zig");
const images = @import("images.zig");

const reasoning_levels = [_]PickItem{
    .{ .name = "Low", .desc = "Fast responses with lighter reasoning" },
    .{ .name = "Medium", .desc = "Balances speed and reasoning depth for everyday tasks" },
    .{ .name = "High", .desc = "Greater reasoning depth for complex problems" },
    .{ .name = "Extra high", .desc = "Extra high reasoning depth for complex problems" },
    .{ .name = "Max", .desc = "Maximum reasoning depth for the hardest problems" },
    .{ .name = "Ultra", .desc = "Maximum reasoning with automatic task delegation" },
};

const vision = @import("vision.zig");
const stageImagePath = vision.stageImagePath;
const visionCapable = vision.visionCapable;
const grabClipboardImage = vision.grabClipboardImage;

fn providerKnown(id: []const u8) bool {
    return provider_mod.specFor(id) != null;
}

fn showFallback(root: *Agent, arena: Allocator, out: *Io.Writer) !void {
    const saved = serde.loadModel(root.io, arena, root.home);
    try out.print("current: {s} via {s}{s}\n", .{ root.provider.model, root.provider.id, if (root.fallback_active) " (temporary fallback)" else "" });
    if (saved) |preferred| try out.print("saved default: {s} via {s}\n", .{ preferred.model, preferred.pid });
    if (root.fallback_allow.len == 0) {
        try out.writeAll("cross-provider fallback: off (same-provider rollout replacement remains allowed)\n");
    } else {
        try out.writeAll("cross-provider fallback allowed:");
        for (root.fallback_allow) |id| try out.print(" {s}", .{id});
        try out.writeByte('\n');
    }
    if (root.fallback_blocked) try out.print("{s}blocked: allow {s} with /fallback allow {s}, or choose /model{s}\n", .{ style.yellow, root.provider.id, root.provider.id, style.reset });
    try out.writeAll("manage: /fallback allow <provider> · remove <provider> · off\n");
    try out.flush();
}

fn handleFallback(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/fallback") and !std.mem.startsWith(u8, line, "/fallback ")) return false;
    const rest = std.mem.trim(u8, line["/fallback".len..], " \t");
    if (rest.len == 0) {
        try showFallback(root, arena, out);
        return true;
    }
    if (std.mem.eql(u8, rest, "off")) {
        root.fallback_allow = &.{};
        _ = fallback_config.save(root.io, root.gpa, root.fallback_allow);
        try showFallback(root, arena, out);
        return true;
    }
    var words = std.mem.tokenizeAny(u8, rest, " \t");
    const action = words.next() orelse "";
    const id = words.next() orelse {
        try out.writeAll("usage: /fallback allow|remove <provider>  |  /fallback off\n");
        try out.flush();
        return true;
    };
    if ((!std.mem.eql(u8, action, "allow") and !std.mem.eql(u8, action, "remove")) or !providerKnown(id)) {
        try out.print("unknown fallback action/provider — use /fallback allow|remove <provider>; provider '{s}' must appear in /models\n", .{id});
        try out.flush();
        return true;
    }
    var updated: std.ArrayList([]const u8) = .empty;
    for (root.fallback_allow) |existing| {
        if (std.mem.eql(u8, action, "remove") and std.mem.eql(u8, existing, id)) continue;
        updated.append(arena, existing) catch {};
    }
    if (std.mem.eql(u8, action, "allow") and !fallback_config.contains(updated.items, id)) updated.append(arena, try arena.dupe(u8, id)) catch {};
    root.fallback_allow = updated.toOwnedSlice(arena) catch updated.items;
    const saved = fallback_config.save(root.io, root.gpa, root.fallback_allow);
    if (std.mem.eql(u8, action, "allow") and std.mem.eql(u8, id, root.provider.id)) root.fallback_blocked = false;
    if (!saved) try out.print("{s}warning: fallback setting is active now but was not persisted{s}\n", .{ style.yellow, style.reset });
    try showFallback(root, arena, out);
    return true;
}

/// Try to handle a model/provider/thinking slash command. Returns false (line
/// unhandled) if `line` doesn't match any command in this file.
pub fn tryHandle(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (try handleFallback(root, arena, line, out)) return true;
    if (std.mem.startsWith(u8, line, "/model") and !std.mem.startsWith(u8, line, "/models")) {
        root.ensureStoredKeys(keys);
        const arg = std.mem.trim(u8, line["/model".len..], " \t");
        providers.ensureModelQueryCatalogs(root, keys.*, arg);
        if (arg.len == 0) {
            if (main_mod.use_color) { // interactive TTY → fuzzy picker
                if (modelPicker(root, keys, arena, out)) |idx| {
                    const m = pricing.models()[idx];
                    const provider = keys.providerById(m.provider, m.name) catch {
                        try offerProviderAuth(root, keys, arena, out, m.provider, m.name, false);
                        return true;
                    };
                    try switchProvider(root, arena, provider, out);
                }
                return true;
            }
            try out.print("current model: {s}{s}{s} via {s}\n", .{ style.accent, root.provider.model, style.reset, root.provider.id });
            try out.writeAll("switch with /model <name> or /model <provider>:\n");
            for (0..provider_mod.specCount()) |i| {
                const spec = provider_mod.specAt(i).?;
                const keyed = keys.get(spec.id) != null;
                const default_model = pricing.providerDefaultModel(spec.id, spec.default_model);
                try out.print("  {s} {s:<10}{s}  default {s}\n", .{
                    if (keyed) "✓" else "·",
                    spec.id,
                    if (keyed) "" else "  (no key)",
                    default_model,
                });
            }
            try out.print("{s}add a key now:  /key <provider> <key>   ·   full model list: /models{s}\n", .{ style.dim, style.reset });
            try out.flush();
            return true;
        }
        // `/model <provider> <model>` or `/model <provider>/<model>`: pin a
        // model to a SPECIFIC provider (e.g. `/model codex gpt-5.5` to force
        // codex when codegraff also serves gpt-5.5).
        if (std.mem.indexOfAny(u8, arg, " /\t")) |i| {
            const pid = arg[0..i];
            const mdl = std.mem.trim(u8, arg[i + 1 ..], " \t");
            if (provider_mod.specFor(pid)) |spec| {
                if (mdl.len == 0) return true;
                if (!isLocalUrl(spec.url) and !pricing.providerModelInTable(pid, mdl)) {
                    try out.print("unknown model '{s}' for {s} — choose /model, or run `graff models refresh` first\n", .{ mdl, pid });
                    try out.flush();
                    return true;
                }
                const m = try arena.dupe(u8, mdl);
                const provider = keys.providerById(pid, m) catch {
                    try offerProviderAuth(root, keys, arena, out, pid, m, false);
                    return true;
                };
                try switchProvider(root, arena, provider, out);
                return true;
            }
        }
        // If the query names a provider (e.g. "openai"), switch to THAT
        // provider on its default model — not the priority router's pick.
        if (provider_mod.specFor(arg)) |spec| {
            // Local OpenAI-compatible servers (LM Studio :1234, mlx-lm :8080) serve a
            // live, user-loaded model set — list what's actually there instead of a
            // baked default. One loaded → switch straight to it; many → list to pick.
            if (isLocalUrl(spec.url)) {
                const key = keys.get(spec.id) orelse {
                    try offerProviderAuth(root, keys, arena, out, spec.id, pricing.providerDefaultModel(spec.id, spec.default_model), true);
                    return true;
                };
                const murl = openAiModelsUrl(arena, spec.url);
                const models = fetchOpenAIModels(root.io, root.gpa, arena, murl, key);
                if (models.len == 0) {
                    try out.print("{s}{s}: no models at {s} — start the server and load a model{s}\n", .{ style.yellow, spec.id, murl, style.reset });
                    try out.flush();
                    return true;
                }
                if (models.len == 1) {
                    try switchProvider(root, arena, keys.build(spec, key, try arena.dupe(u8, models[0])), out);
                    return true;
                }
                try out.print("{s}{s} models{s} — pick with {s}/model {s} <id>{s}:\n", .{ style.bold, spec.id, style.reset, style.accent, spec.id, style.reset });
                for (models) |id| try out.print("  {s}{s}{s}\n", .{ style.accent, id, style.reset });
                try out.flush();
                return true;
            }
            const default_model = pricing.providerDefaultModel(spec.id, spec.default_model);
            const provider = keys.providerById(spec.id, default_model) catch {
                try offerProviderAuth(root, keys, arena, out, spec.id, default_model, true);
                return true;
            };
            try switchProvider(root, arena, provider, out);
            return true;
        }
        const resolved = resolveModelName(keys.*, arg) orelse {
            try out.print("unknown model '{s}' — choose /model, or run `graff models refresh` first; preference unchanged\n", .{arg});
            try out.flush();
            return true;
        };
        const name = try arena.dupe(u8, resolved);
        const provider = keys.providerFor(name) catch {
            for (pricing.models()) |mt| if (std.mem.eql(u8, mt.name, name)) {
                try offerProviderAuth(root, keys, arena, out, mt.provider, name, false);
                return true;
            };
            try out.writeAll("no API key for any provider serving that model — see /models, or add one with /key <provider> <key>\n");
            try out.flush();
            return true;
        };
        try switchProvider(root, arena, provider, out);
        return true;
    }
    if (std.mem.eql(u8, line, "/compact")) {
        _ = root.manualCompact() catch |err| switch (err) {
            error.ApiError, error.EmptySummary, error.IncompleteSummary, error.InvalidCompactionResponse => {},
            else => |e| return e,
        };
        return true;
    }
    if (std.mem.startsWith(u8, line, "/rewind")) {
        // Conversation rewind (à la Claude Code): drop a past prompt and
        // everything after it, so you can branch from an earlier point.
        // Human turns are user messages whose content is a plain string
        // (tool-result user messages carry a content array).
        const arg = std.mem.trim(u8, line["/rewind".len..], " \t");
        var turns: std.ArrayList(usize) = .empty;
        defer turns.deinit(root.gpa);
        for (root.messages.items, 0..) |m, i| {
            if (m != .object) continue;
            const role = if (m.object.get("role")) |r| (if (r == .string) r.string else "") else "";
            if (!std.mem.eql(u8, role, "user")) continue;
            if (m.object.get("content")) |c| if (c == .string) try turns.append(root.gpa, i);
        }
        if (turns.items.len == 0) {
            try out.writeAll("nothing to rewind — no prompts in this conversation yet\n");
            try out.flush();
            return true;
        }
        if (arg.len == 0) {
            try out.writeAll("rewind to before which prompt?\n");
            for (turns.items, 1..) |idx, n| {
                var snip = if (root.messages.items[idx].object.get("content")) |c| (if (c == .string) c.string else "[image]") else "";
                if (std.mem.indexOfScalar(u8, snip, '\n')) |nl| snip = snip[0..nl];
                const shown = if (snip.len > 70) snip[0..70] else snip;
                try out.print("  {s}{d}{s}: {s}{s}\n", .{ style.accent, n, style.reset, shown, if (snip.len > 70) "…" else "" });
            }
            try out.print("{s}usage: /rewind <n> — drops prompt <n>+after and reverts its write_file/edit_file changes (bash edits aren't tracked){s}\n", .{ style.dim, style.reset });
            try out.flush();
            return true;
        }
        const n = std.fmt.parseInt(usize, arg, 10) catch 0;
        if (n < 1 or n > turns.items.len) {
            try out.print("invalid — pick 1..{d} (see /rewind)\n", .{turns.items.len});
            try out.flush();
            return true;
        }
        const cut = turns.items[n - 1];
        const dropped = root.messages.items.len - cut;
        root.messages.items.len = cut; // truncate (entries are arena-owned)
        root.last_context_tokens = 0;
        root.context_local_tokens = 0;
        root.compact_transport_failures = 0;
        root.goal_note_fp = 0; // the goal note may have been in the dropped turns (#318)
        // Restore files written/edited during the rewound turns, and re-point the
        // turn counter so the next prompt re-takes turn n.
        var rw: Rewound = .{};
        if (root.snapshots) |snaps| {
            rw = snaps.restore(@intCast(n));
            snaps.turn = @intCast(n - 1);
        }
        try out.print("⏪ rewound to before prompt {d} — dropped {d} message(s)", .{ n, dropped });
        if (rw.restored > 0) try out.print(", restored {d} file(s)", .{rw.restored});
        // Left alone rather than deleted. State the fact, never a cause: `.unreadable` is every non-FileNotFound read failure, so the reason is not knowable here.
        if (rw.skipped > 0) try out.print(", left {d} file(s) as-is (no snapshot was captured)", .{rw.skipped});
        if (rw.restored == 0 and rw.skipped == 0) try out.print("{s} (no tracked file changes){s}", .{ style.dim, style.reset });
        try out.writeAll("\n");
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/fast") or std.mem.eql(u8, line, "/fast on") or std.mem.eql(u8, line, "/fast off")) {
        root.fast = if (std.mem.eql(u8, line, "/fast on")) true else if (std.mem.eql(u8, line, "/fast off")) false else !root.fast;
        _ = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("fast mode: {s}{s}\n", .{
            if (root.fast) "on" else "off",
            if (!std.mem.eql(u8, root.provider.id, "codex")) " (codex only — current model ignores it)" else "",
        });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/thinking") or std.mem.eql(u8, line, "/thinking on") or std.mem.eql(u8, line, "/thinking off")) {
        root.show_thinking = if (std.mem.eql(u8, line, "/thinking on")) true else if (std.mem.eql(u8, line, "/thinking off")) false else !root.show_thinking;
        const saved = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("thinking: {s} ({s}){s}\n", .{
            if (root.show_thinking) "shown" else "collapsed",
            if (root.show_thinking) "stream reasoning live" else "spinner only",
            if (saved) "" else " (not persisted)",
        });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/title") or std.mem.eql(u8, line, "/title on") or std.mem.eql(u8, line, "/title off")) {
        const was_on = root.ai_title;
        root.ai_title = if (std.mem.eql(u8, line, "/title on")) true else if (std.mem.eql(u8, line, "/title off")) false else !root.ai_title;
        if (was_on and !root.ai_title) root.title_generation +%= 1; // discard any detached result already in flight
        const saved = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("AI session title: {s} ({s}){s}\n", .{
            if (root.ai_title) "on" else "off",
            if (root.ai_title) "name the tab from your first prompt" else "use the prompt text verbatim",
            if (saved) "" else " (not persisted)",
        });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/ultracode") or std.mem.startsWith(u8, line, "/ultracode ")) {
        const arg = std.mem.trim(u8, line["/ultracode".len..], " \t\r\n");
        const next = if (arg.len == 0) blk: {
            if (main_mod.use_color and root.in != null) {
                break :blk pickUltracodeMode(root, arena, out) orelse return true;
            }
            try out.writeAll("usage: /ultracode on|off\n");
            try out.flush();
            return true;
        } else if (std.mem.eql(u8, arg, "on"))
            true
        else if (std.mem.eql(u8, arg, "off"))
            false
        else {
            try out.writeAll("usage: /ultracode on|off\n");
            try out.flush();
            return true;
        };
        root.ultracode_mode = next;
        const saved = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("ultracode mode: {s}{s}\n", .{ if (root.ultracode_mode) "on" else "off", if (saved) "" else " (not persisted)" });
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/effort") or std.mem.startsWith(u8, line, "/reasoning")) {
        const prefix: []const u8 = if (std.mem.startsWith(u8, line, "/effort")) "/effort" else "/reasoning";
        const arg = std.mem.trim(u8, line[prefix.len..], " \t");
        if (arg.len == 0 and main_mod.use_color and root.in != null) {
            const title = try std.fmt.allocPrint(arena, "Reasoning level for {s} ›", .{root.provider.model});
            const idx = listPickerAt(root, arena, out, title, &reasoning_levels, @intFromEnum(root.reasoning)) orelse return true;
            root.reasoning = @enumFromInt(idx);
        } else if (std.mem.eql(u8, arg, "med")) {
            root.reasoning = .medium;
        } else if (std.mem.eql(u8, arg, "extra") or std.mem.eql(u8, arg, "extra-high") or std.mem.eql(u8, arg, "extra high")) {
            root.reasoning = .xhigh;
        } else if (arg.len != 0) {
            root.reasoning = std.meta.stringToEnum(main_mod.ReasoningEffort, arg) orelse {
                try out.writeAll("usage: /effort low|medium|high|xhigh|max|ultra\n");
                try out.flush();
                return true;
            };
        } else {
            try out.print("reasoning effort: {s}\n", .{reasoning_levels[@intFromEnum(root.reasoning)].name});
            try out.flush();
            return true;
        }
        _ = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("reasoning effort: {s}{s}\n", .{
            reasoning_levels[@intFromEnum(root.reasoning)].name,
            if (!root.effortApplies()) " (current model ignores it — applies to codex, deepseek, codegraff)" else "",
        });
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/keepcontext")) {
        const arg = std.mem.trim(u8, line["/keepcontext".len..], " \t");
        if (std.mem.eql(u8, arg, "on")) {
            root.keep_context = true;
        } else if (std.mem.eql(u8, arg, "off")) {
            root.keep_context = false;
        } else root.keep_context = !root.keep_context; // bare: toggle
        try out.print("keep-context across model switches: {s} — {s}\n", .{
            if (root.keep_context) "ON" else "off",
            if (root.keep_context) "a wire-format switch (e.g. → claude) translates & keeps the dialogue" else "a wire-format switch clears history",
        });
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/key")) {
        root.ensureStoredKeys(keys);
        const rest = std.mem.trim(u8, line["/key".len..], " \t");
        if (rest.len == 0) { // show key status + how to add
            try out.writeAll("API keys (✓ = set via env / Keychain / login):\n");
            for (0..provider_mod.specCount()) |i| {
                const spec = provider_mod.specAt(i).?;
                try out.print("  {s} {s:<10}  {s}\n", .{ if (keys.get(spec.id) != null) "✓" else "·", spec.id, spec.env_key });
            }
            try out.print("{s}add one:  /key <provider> <key>   (used now + saved to the macOS Keychain){s}\n", .{ style.dim, style.reset });
            try out.flush();
            return true;
        }
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse {
            try out.writeAll("usage: /key <provider> <key>\n");
            try out.flush();
            return true;
        };
        const pid = rest[0..sp];
        const key = std.mem.trim(u8, rest[sp + 1 ..], " \t");
        if (provider_mod.specFor(pid) == null) {
            try out.print("unknown provider '{s}' — see /model for the list\n", .{pid});
            try out.flush();
            return true;
        }
        if (key.len == 0) {
            try out.writeAll("usage: /key <provider> <key>\n");
            try out.flush();
            return true;
        }
        const live_key = arena.dupe(u8, key) catch key;
        const home = root.home;
        const saved = storeKey(root.io, root.gpa, arena, home, pid, key); // persist
        _ = keys.set(pid, live_key, if (saved) .stored else .session);
        if (std.mem.eql(u8, pid, "kimi")) _ = kimi_catalog.load(root.io, root.gpa, arena, home, live_key);
        try out.print("✓ {s} key set (live{s}) — now: /model {s}\n", .{ pid, if (saved) " + Keychain" else "", pid });
        try out.flush();
        return true;
    }
    if (std.mem.startsWith(u8, line, "/login")) {
        root.ensureStoredKeys(keys);
        // Interactive OAuth sign-in for the providers that have a device/PKCE
        // flow (codegraff, codex/ChatGPT, kimi). Mirrors the `graff login`
        // subcommands but runs in-session and pulls the fresh key into the live
        // Keys, so this conversation keeps going without a restart. Pure
        // API-key providers don't log in — they point back at /key.
        const rest = std.mem.trim(u8, line["/login".len..], " \t");
        var lit = std.mem.tokenizeAny(u8, rest, " \t");
        var target = lit.next() orelse "";
        const refresh = while (lit.next()) |a| {
            if (std.mem.eql(u8, a, "--refresh")) break true;
        } else false;
        const login_targets = [_]PickItem{
            .{ .name = "codegraff", .desc = "free codegraff key (device-code OAuth)" },
            .{ .name = "codex", .desc = "ChatGPT / OpenAI sign-in (alias: oai)" },
            .{ .name = "kimi", .desc = "Kimi Code sign-in (device-code OAuth)" },
            .{ .name = "xai", .desc = "Grok / SuperGrok sign-in (device-code OAuth)" },
        };
        // Bare /login: pick a provider on a TTY, else just list the options.
        if (target.len == 0) {
            if (main_mod.use_color and root.in != null) {
                const idx = listPicker(root, arena, out, "Log in to \xe2\x80\xba", &login_targets) orelse return true;
                target = login_targets[idx].name;
            } else {
                try out.writeAll("interactive logins (OAuth \xe2\x80\x94 no key to paste):\n");
                for (login_targets) |t| try out.print("  {s} /login {s:<10} {s}\n", .{ if (keys.get(t.name) != null) "\xe2\x9c\x93" else "\xc2\xb7", t.name, t.desc });
                try out.print("{s}other providers use an API key:  /key <provider> <key>{s}\n", .{ style.dim, style.reset });
                try out.flush();
                return true;
            }
        }
        // codex is the OpenAI/ChatGPT login; accept the natural aliases.
        if (std.mem.eql(u8, target, "oai") or std.mem.eql(u8, target, "openai") or
            std.mem.eql(u8, target, "chatgpt") or std.mem.eql(u8, target, "gpt"))
            target = "codex";
        if (std.mem.eql(u8, target, "graff")) target = "codegraff";
        if (std.mem.eql(u8, target, "grok")) target = "xai";

        const home = root.home;
        try out.flush(); // hand stdout to the login flow's own writer
        if (std.mem.eql(u8, target, "codegraff")) {
            oauth.codegraffLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 codegraff login failed: {t}\n", .{err});
                try out.flush();
                return true;
            };
        } else if (std.mem.eql(u8, target, "codex")) {
            oauth.codexLogin(root.io, root.gpa, arena, home, refresh) catch |err| {
                try out.print("\xe2\x9c\x97 codex login failed: {t}\n", .{err});
                try out.flush();
                return true;
            };
        } else if (std.mem.eql(u8, target, "kimi")) {
            oauth.kimiLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 kimi login failed: {t}\n", .{err});
                try out.flush();
                return true;
            };
        } else if (std.mem.eql(u8, target, "xai")) {
            oauth.xaiLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 xai login failed: {t}\n", .{err});
                try out.flush();
                return true;
            };
        } else {
            // A pure API-key provider, or something unrecognized.
            if (provider_mod.specFor(target) != null) {
                try out.print("{s} uses an API key, not a login \xe2\x80\x94 /key {s} <key>\n", .{ target, target });
                try out.flush();
                return true;
            }
            try out.print("can't log into '{s}' \xe2\x80\x94 try /login codegraff | codex | kimi | xai (others: /key <provider> <key>)\n", .{target});
            try out.flush();
            return true;
        }
        // Login wrote its credential file; pull the key into the live session.
        reloadLoginKey(root, keys, arena, target);
        try out.flush();
        return true;
    }
    // startsWith, NOT eql: this branch owns BOTH `/images` (the URL opener,
    // dispatched on the exact match just below) and `/image <path>` (staging an
    // attachment). The #103 extraction overwrote this outer guard with a copy of
    // the inner exact-match, which made every `/image` line below unreachable -
    // the command stayed in the catalog and /help while answering "unknown".
    if (std.mem.startsWith(u8, line, "/image")) {
        if (std.mem.eql(u8, line, "/images")) return images_command.run(root, out);
        const path = std.mem.trim(u8, line["/image".len..], " \t");
        if (path.len == 0) {
            if (root.pending_image) |pi| {
                try out.print("staged image: {s} — send a message to include it ('/image clear' to drop)\n", .{pi.label});
            } else {
                try out.writeAll("usage: /image <path.png|jpg|gif|webp>  (attaches to your next message)\n");
            }
            try out.flush();
            return true;
        }
        if (std.mem.eql(u8, path, "clear")) {
            root.pending_image = null;
            try out.writeAll("cleared the staged image\n");
            try out.flush();
            return true;
        }
        var mbuf: [320]u8 = undefined; // the message, or (first 16 bytes) just the size
        const staged = stageImagePath(root, path);
        switch (staged) {
            .no_vision => try out.print("⚠ {s} can't see images — switch to a vision model first, e.g. /model claude-opus-4-8 or /model gpt-5.5\n", .{root.provider.model}),
            .ok => |o| try out.print("📎 attached {s} ({s}) — sent with your next message\n", .{ path, vision.fmtBytes(mbuf[0..16], o.bytes) }),
            // Sized, distinct lines instead of "missing, or larger than 5MB" (#349).
            .too_large, .not_found, .read_error => try out.print("{s}\n", .{vision.stageMessage(&mbuf, staged, path)}),
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/paste")) {
        if (builtin.os.tag != .macos) {
            try out.writeAll("clipboard image paste is macOS-only — use /image <path>\n");
            try out.flush();
            return true;
        }
        if (!visionCapable(root.provider)) {
            try out.print("⚠ {s} can't see images — /model to a vision model (claude-*, gpt-5*) first\n", .{root.provider.model});
            try out.flush();
            return true;
        }
        const grab = grabClipboardImage(root.io, root.gpa) orelse {
            vision.tracePaste(root, "no_image", "none", 0, ""); // #350
            try out.writeAll("no image on the clipboard — copy an image first (text? just paste it normally)\n");
            try out.flush();
            return true;
        };
        defer grab.release(root.io, root.gpa); // temp export never outlives the command
        var pbuf: [320]u8 = undefined;
        const pasted = stageImagePath(root, grab.path);
        vision.tracePasteResult(root, grab.flavor, pasted);
        switch (pasted) {
            .ok => |o| try out.print("📎 clipboard image attached ({s}, via {s}) — sent with your next message\n", .{ vision.fmtBytes(pbuf[0..16], o.bytes), grab.flavor.name() }),
            .no_vision => try out.print("⚠ {s} can't see images\n", .{root.provider.model}),
            .too_large, .not_found, .read_error => try out.print("{s}\n", .{vision.stageMessage(&pbuf, pasted, "the clipboard image")}),
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, line, "/strict")) {
        root.strict = !root.strict;
        root.rebaseContextMeter();
        try out.print("strict mode {s} — {s}\n", .{
            if (root.strict) "ON" else "off",
            if (root.strict) "every message must be a tool; finish with attempt_completion" else "free-text replies allowed",
        });
        try out.flush();
        return true;
    }
    return false;
}
