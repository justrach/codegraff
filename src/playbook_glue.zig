//! #381 capture surfaces for the playbook substrate: the `/never` REPL
//! command, the root-only `note_constraint` meta tool, and the root
//! system-prompt refresh both of them trigger.
//!
//! Split from playbook.zig so the substrate stays a leaf over std/util/trace.
//! Everything that needs an `*Agent` lives here.
//!
//! WHY TWO CAPTURE SURFACES. `/never` is for the user who knows they are
//! stating a standing rule. `note_constraint` is for the far commoner case
//! #381 actually reports: the user rejects something mid-conversation ("no,
//! stop adding scroll hints") and never thinks of it as configuration. The
//! root already understands that rejection at the moment it happens — the
//! only missing piece was somewhere durable to put it.
//!
//! THE TOOL CANNOT WIDEN ITSELF. `note_constraint` appends `source=user`
//! items and nothing else: no retire, no edit, no learned items, no reading
//! back a ledger it could then rewrite. A model that finds a constraint
//! inconvenient has no mechanism to remove it — only the user does, through
//! `/never` (picker or `rm`). Same shape as the #366 gate: the capability the model
//! gets is strictly the one that makes it safer to run unattended.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const ExecResult = @import("tools.zig").ExecResult;
const json_args = @import("json_args.zig");
const prompts = @import("prompts.zig");
const playbook = @import("playbook.zig");
const playbook_pick = @import("playbook_pick.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;

/// Re-derive the root's four system-prompt variants from its stored BASE, so
/// a constraint recorded mid-session reaches the very next request instead of
/// waiting for a restart. Cheap: one small file read plus four allocPrints,
/// only on an actual mutation. Best-effort — a failed refresh leaves the
/// previous (still valid) prompt in place, and the ledger on disk is already
/// correct for every brief assembled after it.
pub fn refreshRoot(agent: *Agent, arena: Allocator) void {
    _ = refreshFrom(agent, arena, false);
}

fn refreshFrom(agent: *Agent, arena: Allocator, arm_root: bool) bool {
    if (agent.sub) return false;
    if (!arm_root and agent.sys_base.len == 0) return false;
    const old = .{ agent.sys_normal, agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict };
    const result = if (arm_root)
        prompts.setRootSystemPrompts(agent, agent.sys_base, arena)
    else
        prompts.setSystemPrompts(agent, agent.sys_base, arena);
    result catch {
        agent.sys_normal = old[0];
        agent.sys_strict = old[1];
        agent.sys_ultra = old[2];
        agent.sys_ultra_strict = old[3];
        return false;
    };
    // A Responses continuation may otherwise retain the old instructions on
    // the server. Re-send the refreshed prefix on this turn's next request.
    if (!std.mem.eql(u8, old[0], agent.sys_normal)) agent.closeCodexWs();
    return true;
}

/// The `note_constraint` meta-tool handler (root-only; the spec lives in
/// root_specs, so a subagent is never even told it exists). Append-only by
/// construction — see this file's header.
pub fn noteConstraint(agent: *Agent, input: std.json.Value) ExecResult {
    if (agent.sub) return .{ .text = "Only the root may record user constraints.", .is_error = true };
    const text = if (json_args.object(input)) |o| (json_args.str(o, "text") orelse "") else "";
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{
        .text = "note_constraint needs a `text` field: one short imperative line, e.g. \"never add scroll hints or progress dots\"",
        .is_error = true,
    };
    var prov_buf: [32]u8 = undefined;
    const provenance = std.fmt.bufPrint(&prov_buf, "user:{d}", .{@import("util.zig").unixMs(agent.io)}) catch "user";
    const r = playbook.add(agent.io, agent.arena, text, .user, provenance);
    const duplicate = std.mem.eql(u8, r.reason, "already recorded (same normalized text)");
    if (!r.ok and !duplicate) return .{
        .text = std.fmt.allocPrint(agent.arena, "constraint NOT recorded ({s}){s}{s}", .{
            r.reason,
            if (r.id.len > 0) " — existing id " else "",
            r.id,
        }) catch "constraint not recorded",
        // An already-recorded constraint is the desired end state, not a
        // failure: flagging it as an error would push the model into
        // retrying or apologising for a ledger that is already correct.
        .is_error = !std.mem.eql(u8, r.reason, "already recorded (same normalized text)"),
    };
    @import("prompt_cache_hud.zig").noteBust(.playbook);
    // A duplicate must reconcile a stale prefix too. Never promise same-turn
    // activation after a failed refresh (the durable write already succeeded).
    const refreshed = refreshFrom(agent, agent.arena, true) and
        std.mem.indexOf(u8, agent.sys_normal, r.id) != null;
    const effect = if (refreshed)
        "It takes effect immediately, in this same turn: user instructions override built-in authoring/style defaults (including optional attribution), not secret-safety or disclosure-approval requirements. Act on the constraint now rather than waiting for the next turn."
    else
        "Durable state is saved, but the active prompt could not be refreshed. Do not claim activation; retry note_constraint to reconcile it.";
    // ADR 0021: the user just said this. Echoing "constraint recorded" is
    // machine state, not progress. The tool result still tells the model.
    return .{ .text = std.fmt.allocPrint(agent.arena, "constraint recorded as {s}. It is now in {s} and rides every subagent, workflow and pipeline brief from here on, in this session and in later ones — you do not need to restate it. {s}", .{ r.id, playbook.path, effect }) catch "constraint recorded; active prompt refresh status unavailable", .is_error = false };
}

/// Privacy-safe operational trace: id + success, never constraint text (#644).
fn emitRetire(root: *Agent, id: []const u8, ok: bool) void {
    if (root.tracer) |tr| tr.write(.{
        .t = tr.elapsedMs(),
        .ev = "never_retire",
        .id = id,
        .ok = ok,
    });
}

fn applyRetire(root: *Agent, arena: Allocator, id: []const u8) playbook.Retire {
    const result = playbook.retire(root.io, arena, id);
    emitRetire(root, id, result == .ok);
    return result;
}

fn retireOne(root: *Agent, arena: Allocator, out: *Io.Writer, id: []const u8, needle: []const u8) !void {
    switch (applyRetire(root, arena, id)) {
        .ok => {
            @import("prompt_cache_hud.zig").noteBust(.playbook);
            refreshRoot(root, arena);
            try out.print("retired {s} — it no longer rides new briefs (the record stays in the log as a tombstone)\n", .{id});
        },
        .write_failed => try out.print("could not write the retirement tombstone to {s} — {s} is still active\n", .{ playbook.path, id }),
        .unknown => try out.print("no live playbook item matching '{s}' — /never lists them (id or unique text)\n", .{needle}),
    }
    try out.flush();
}

/// First whitespace-separated token and the rest. Tabs count as separators
/// so `/never rm<TAB>pb-…` is `rm`, not a new constraint named "rm\t…".
fn wordAndRest(arg: []const u8) struct { word: []const u8, rest: []const u8 } {
    const t = std.mem.trim(u8, arg, " \t");
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return .{ .word = t[0..end], .rest = std.mem.trim(u8, t[end..], " \t") };
}

fn list(io: Io, arena: Allocator, out: *Io.Writer) !void {
    const items = playbook.load(io, arena);
    if (items.len == 0) {
        try out.print("playbook empty — /never <text> records a standing constraint ({s})\n", .{playbook.path});
        try out.flush();
        return;
    }
    try out.print("{s}playbook{s} — {s}\n", .{ style.bold, style.reset, playbook.path });
    for (items) |item| try out.print("  {s}  {s:<9} {s}\n", .{ item.id, @tagName(item.source), item.text });
    try out.print("{d} item(s) · /never <text> adds one · /never rm <id-or-text> retires one\n", .{items.len});
    try out.flush();
}

pub fn isCommand(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    for ([_][]const u8{ "/never", "/constraint" }) |name| {
        if (std.mem.eql(u8, t, name)) return true;
        if (std.mem.startsWith(u8, t, name) and t.len > name.len and t[name.len] == ' ') return true;
    }
    return false;
}

fn wantsRetire(text: []const u8) bool {
    var nbuf: [playbook.max_text]u8 = undefined;
    const n = playbook.normalize(&nbuf, text);
    for ([_][]const u8{
        "retire",
        "forget",
        "override",
        "supersede",
        "never mind",
        "no longer",
        "stop following",
        "you can now",
        "drop the constraint",
        "remove the constraint",
        "ignore the",
        "ignore that",
    }) |verb| {
        if (std.mem.indexOf(u8, n, verb) != null) return true;
    }
    return false;
}

fn extractPlaybookId(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, "pb-") orelse return null;
    const rest = text[start..];
    if (rest.len < 11) return null;
    for (rest[3..11]) |c| if (!std.ascii.isHex(c)) return null;
    return rest[0..11];
}

/// When the current user message explicitly asks to drop a standing rule,
/// tombstone the matching live item and refresh the prefix (#638). The
/// model still cannot retire a constraint on its own — only this user
/// message, or `/never rm`, can. Returns how many items left the ledger.
pub fn applyUserOverride(root: *Agent, arena: Allocator, user_text: []const u8) usize {
    if (root.sub or !wantsRetire(user_text)) return 0;
    const items = playbook.load(root.io, arena);
    if (items.len == 0) return 0;
    var n: usize = 0;
    if (extractPlaybookId(user_text)) |id| {
        if (applyRetire(root, arena, id) == .ok) n += 1;
    } else if (playbook.findByUniqueText(items, user_text)) |item| {
        if (applyRetire(root, arena, item.id) == .ok) n += 1;
    }
    if (n > 0) {
        @import("prompt_cache_hud.zig").noteBust(.playbook);
        refreshRoot(root, arena);
    }
    return n;
}

/// `/never` (alias `/constraint`). Returns false when `line` is neither, so
/// the caller falls through to the rest of the command chain.
///
///   /never                  TTY: searchable picker + two confirms; else list
///   /never <text>           record a user constraint
///   /never rm <id|text>     retire one (id, or a unique text fragment)
///   /never rm               TTY picker, else list + usage — never add "rm" (#644)
pub fn command(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const rest = for ([_][]const u8{ "/never", "/constraint" }) |name| {
        if (std.mem.eql(u8, trimmed, name)) break "";
        if (std.mem.startsWith(u8, trimmed, name) and trimmed.len > name.len and trimmed[name.len] == ' ') break trimmed[name.len + 1 ..];
    } else return false;
    const arg = std.mem.trim(u8, rest, " \t");
    if (arg.len == 0) {
        switch (try playbook_pick.interactive(root, arena, out)) {
            .fallback => try list(root.io, arena, out),
            .handled => {},
            .retire => |id| try retireOne(root, arena, out, id, id),
        }
        return true;
    }
    const parts = wordAndRest(arg);
    if (std.mem.eql(u8, parts.word, "rm") or std.mem.eql(u8, parts.word, "remove")) {
        // `/never rm` with no needle used to fall through to add("rm"), leaving
        // the live constraint untouched and no tombstone (#644). List (or the
        // TTY picker) instead; never record the verb as a constraint.
        if (parts.rest.len == 0) {
            switch (try playbook_pick.interactive(root, arena, out)) {
                .fallback => {
                    try out.print("rm needs an id or unique text fragment — /never lists them\n", .{});
                    try list(root.io, arena, out);
                },
                .handled => {},
                .retire => |id| try retireOne(root, arena, out, id, id),
            }
            return true;
        }
        const needle = parts.rest;
        const items = playbook.load(root.io, arena);
        const id = if (playbook.find(items, needle) != null) needle else if (playbook.findByUniqueText(items, needle)) |item| item.id else needle;
        try retireOne(root, arena, out, id, needle);
        return true;
    }
    var prov_buf: [32]u8 = undefined;
    const provenance = std.fmt.bufPrint(&prov_buf, "user:{d}", .{@import("util.zig").unixMs(root.io)}) catch "user";
    const r = playbook.add(root.io, arena, arg, .user, provenance);
    if (r.ok) {
        @import("prompt_cache_hud.zig").noteBust(.playbook);
        refreshRoot(root, arena);
        try out.print("{s}⛔ recorded {s}{s} — this now rides every brief, in this session and later ones\n", .{ style.yellow, r.id, style.reset });
    } else try out.print("not recorded: {s}\n", .{r.reason});
    try out.flush();
    return true;
}
