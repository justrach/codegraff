//! The single source of truth for the REPL slash-command catalog, shared by
//! its three consumers so they never drift (600-line goal, issue #123):
//!   - the bare "/" fuzzy menu   (pickers.command_menu -> mainloop)
//!   - the /help dump            (commands_misc.handleRest)
//!   - tab completion            (main.repl_commands -> input_util)
//! Each entry's `name` is the runnable command — the bare "/" menu passes it
//! straight to handleCommand, so it must be the plain "/foo" form, never a
//! usage string. `usage` is the fuller "/foo <arg>" form shown only in the
//! /help dump (it falls back to `name` when empty). `desc` is the one-liner.

const std = @import("std");

/// One catalog entry. `name`/`desc` are the same two fields the generic
/// listPicker items carry (pickers.PickItem = this type), so both are always
/// set there; `usage` is catalog-only and defaults to the bare name.
pub const Item = struct {
    name: []const u8,
    desc: []const u8 = "",
    usage: []const u8 = "",
};

/// The canonical command list, in menu / help display order.
pub const commands = [_]Item{
    .{ .name = "/model", .usage = "/model [<provider>] <name>", .desc = "switch model/provider, fuzzy match (e.g. \"sonnet\", \"opus\"); name a provider to pin the seat" },
    .{ .name = "/models", .usage = "/models [health]", .desc = "list known models: context window, compaction point, provider and what that seat costs (plan/credits/api/local); health shows live state" },
    .{ .name = "/clear", .desc = "wipe the conversation and start fresh" },
    .{ .name = "/new", .desc = "start a fresh autosaved session" },
    .{ .name = "/rename", .usage = "/rename <title>", .desc = "set the current session title" },
    .{ .name = "/goal", .usage = "/goal [30m] [text|pause|resume|status|clear]", .desc = "set a standing objective and work it autonomously; an optional 30s/30m/2h budget paces the run; pause/resume steering, status shows state, clear removes it" },
    .{ .name = "/loop", .usage = "/loop [30m] <prompt>", .desc = "the same autonomous run as /goal, without adopting a standing objective" },
    .{ .name = "/review", .usage = "/review <target or instructions>", .desc = "run one isolated read-only review pass; no edits, delegation, or workflows" },
    .{ .name = "/never", .usage = "/never [<text>|rm <id>]", .desc = "standing constraints that ride every subagent brief and survive compaction; bare lists them, rm <id> retires one (alias /constraint)" },
    .{ .name = "/tell", .usage = "/tell <session|all> <text>", .desc = "message a running graff: <session> is a DM (only it hears, any folder); all broadcasts to every graff on this device; /sessions lists who's around" },
    .{ .name = "/peek", .usage = "/peek <session>", .desc = "see what a live co-resident session is doing right now (its transcript tail)" },
    .{ .name = "/routes", .usage = "/routes [<set>|add <set> <frontier|mid|small> <provider/model>]", .desc = "your own priced model lanes across providers — view the set and which seat wins each lane now" },
    .{ .name = "/plan", .desc = "toggle plan mode: read-only explore + propose; writes/edits denied" },
    .{ .name = "/ultracode", .desc = "toggle persistent workflow mode; bare opens an on/off picker, or /ultracode on|off" },
    .{ .name = "/fallback", .usage = "/fallback [allow|remove|off]", .desc = "opt-in cross-provider fallback for this workspace (same-provider rollout stays on)" },
    .{ .name = "/key", .usage = "/key [provider secret]", .desc = "show API-key status; /key <provider> <secret> adds one live (+ Keychain)" },
    .{ .name = "/login", .usage = "/login [codegraff|codex|kimi]", .desc = "OAuth sign-in (no key to paste); bare opens a picker (codex alias: oai)" },
    .{ .name = "/keepcontext", .desc = "toggle keeping the conversation when /model switches wire format (default on)" },
    .{ .name = "/effort", .desc = "reasoning depth: low|medium|high|... (codex, deepseek, codegraff; persists)" },
    .{ .name = "/reasoning", .desc = "alias for /effort" },
    .{ .name = "/fast", .desc = "codex only: priority service tier for lower latency (toggle, persists)" },
    .{ .name = "/thinking", .desc = "stream reasoning live vs spinner only (toggle, persists)" },
    .{ .name = "/title", .desc = "name the tab from your first prompt (AI session title; toggle, persists)" },
    .{ .name = "/strict", .desc = "toggle \"every message is a tool\" mode" },
    .{ .name = "/yolo", .desc = "toggle bash auto-approval (skip permission prompts)" },
    .{ .name = "/trace", .desc = "toggle this run's JSONL event trace (and show its path)" },
    .{ .name = "/privacy", .usage = "/privacy [local|aggregate|templates|examples]", .desc = "control prompt-learning data egress for this session" },
    .{ .name = "/trajectory", .desc = "show this session's agent tree — turns + spawned subagents" },
    .{ .name = "/agents", .desc = "list agent types — builtin personas + .harness/agents/*.md" },
    .{ .name = "/skills", .usage = "/skills [add|remove <name>]", .desc = "list SKILL.md playbooks + companion tools; add/remove enables or disables one" },
    .{ .name = "/plugins", .usage = "/plugins [list|load <name>]", .desc = "list Claude/Cursor/Grok/Codex plugin trees graff is reading in place; load names one" },
    .{ .name = "/hooks", .desc = "list lifecycle hooks and the built-in codedb guard" },
    .{ .name = "/doctor", .desc = "read-only health check: goal/todo invariants, and why steering will or will not be appended" },
    .{ .name = "/btw", .usage = "/btw <question>", .desc = "ask one side question about this conversation — no tools, billed, never added to the session" },
    .{ .name = "/compact", .desc = "compact history into a fresh context (OpenAI server-side when available)" },
    .{ .name = "/rewind", .usage = "/rewind [n|<snapshot>]", .desc = "list past prompts; /rewind <n> drops prompt n+after & reverts its file edits; /rewind <snapshot id> restores a sandbox filesystem instead, never the conversation" },
    .{ .name = "/snapshot", .usage = "/snapshot [attach [image]|detach|list]", .desc = "capture the attached sandbox's filesystem under .graff/sessions/<session>/snapshots; attach puts this session in a Docker sandbox, list shows what it has captured" },
    .{ .name = "/image", .usage = "/image <path>", .desc = "attach an image to your next message (vision models only)" },
    .{ .name = "/images", .desc = "open image URLs from the last response (e.g. issue attachments) in your browser" },
    .{ .name = "/paste", .desc = "attach the clipboard image — macOS; also Ctrl-V (⌘V can't be captured)" },
    .{ .name = "/bash", .usage = "/bash <command>", .desc = "run a shell command directly" },
    .{ .name = "/save", .usage = "/save [name]", .desc = "write the conversation to <name>.session.json (default: current)" },
    .{ .name = "/resume", .usage = "/resume [name]", .desc = "restore a saved conversation (no arg → interactive picker)" },
    .{ .name = "/sessions", .desc = "list saved sessions in the cwd" },
    .{ .name = "/workspace", .usage = "/workspace [list|use <name>]", .desc = "list git worktrees or switch this session into one (file tools follow)" },
    .{ .name = "/todo", .desc = "show the current task list" },
    .{ .name = "/jobs", .desc = "list background jobs" },
    .{ .name = "/cost", .desc = "session token usage and cost" },
    .{ .name = "/usage", .desc = "alias for /cost" },
    .{ .name = "/debug", .desc = "live content-free observability HUD (turns, tokens, tools, last events)" },
    .{ .name = "/tools", .desc = "session tool balance: codedb-pro vs zigrep vs native usage, gate refusals, skew" },
    .{ .name = "/animation", .desc = "pick the thinking animation; persists to settings" },
    .{ .name = "/theme", .usage = "/theme [name]", .desc = "pick a color theme; /theme off resets to your terminal default; persists" },
    .{ .name = "/fleet", .usage = "/fleet [on|off]", .desc = "federated DGM contribution (propose/submit/elite_pull)" },
    .{ .name = "/mcp", .usage = "/mcp [add …]", .desc = "list MCP servers/tools; /mcp add <name> <cmd> [args...] connects one live" },
    .{ .name = "/import-claude", .desc = "copy Claude/Cursor MCP servers and skills into ~/.codegraff and this repo" },
    .{ .name = "/help", .desc = "list every command" },
};

/// Bare command names for tab completion (re-exported as main.repl_commands),
/// derived from `commands` so completion never drifts from the menu.
pub const names = blk: {
    var arr: [commands.len][]const u8 = undefined;
    for (&arr, commands) |*slot, command| slot.* = command.name;
    break :blk arr;
};

// /doctor is dispatched from commands_misc.tryHandle now, so doctor.zig is
// reached through the production import graph and needs no hook here.

test "catalog is well-formed and names track commands" {
    try std.testing.expectEqual(commands.len, names.len);
    for (commands, names) |command, name| {
        try std.testing.expect(command.name.len > 1 and command.name[0] == '/');
        try std.testing.expect(command.desc.len > 0);
        try std.testing.expectEqualStrings(command.name, name);
    }
}
