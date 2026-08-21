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
//! `/never rm <id>`. Same shape as the #366 gate: the capability the model
//! gets is strictly the one that makes it safer to run unattended.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const ExecResult = @import("tools.zig").ExecResult;
const json_args = @import("json_args.zig");
const prompts = @import("prompts.zig");
const playbook = @import("playbook.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;

/// Re-derive the root's four system-prompt variants from its stored BASE, so
/// a constraint recorded mid-session reaches the very next request instead of
/// waiting for a restart. Cheap: one small file read plus four allocPrints,
/// only on an actual mutation. Best-effort — a failed refresh leaves the
/// previous (still valid) prompt in place, and the ledger on disk is already
/// correct for every brief assembled after it.
pub fn refreshRoot(agent: *Agent, arena: Allocator) void {
    if (agent.sub or agent.sys_base.len == 0) return;
    prompts.setSystemPrompts(agent, agent.sys_base, arena) catch {};
}

/// The `note_constraint` meta-tool handler (root-only; the spec lives in
/// root_specs, so a subagent is never even told it exists). Append-only by
/// construction — see this file's header.
pub fn noteConstraint(agent: *Agent, input: std.json.Value) ExecResult {
    const text = if (json_args.object(input)) |o| (json_args.str(o, "text") orelse "") else "";
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{
        .text = "note_constraint needs a `text` field: one short imperative line, e.g. \"never add scroll hints or progress dots\"",
        .is_error = true,
    };
    var prov_buf: [32]u8 = undefined;
    const provenance = std.fmt.bufPrint(&prov_buf, "user:{d}", .{@import("util.zig").unixMs(agent.io)}) catch "user";
    const r = playbook.add(agent.io, agent.arena, text, .user, provenance);
    if (!r.ok) return .{
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
    refreshRoot(agent, agent.arena);
    // ADR 0021: the user just said this. Echoing "constraint recorded" is
    // machine state, not progress. The tool result still tells the model.
    return .{ .text = std.fmt.allocPrint(agent.arena, "constraint recorded as {s}. It is now in {s} and rides every subagent, workflow and pipeline brief from here on, in this session and in later ones — you do not need to restate it.", .{ r.id, playbook.path }) catch "constraint recorded", .is_error = false };
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
    try out.print("{d} item(s) · /never <text> adds one · /never rm <id> retires one\n", .{items.len});
    try out.flush();
}

/// `/never` (alias `/constraint`). Returns false when `line` is neither, so
/// the caller falls through to the rest of the command chain.
///
///   /never                  list the live ledger
///   /never <text>           record a user constraint
///   /never rm <id>          retire one (the ONLY removal path there is)
pub fn command(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const rest = for ([_][]const u8{ "/never", "/constraint" }) |name| {
        if (std.mem.eql(u8, line, name)) break "";
        if (std.mem.startsWith(u8, line, name) and line.len > name.len and line[name.len] == ' ') break line[name.len + 1 ..];
    } else return false;
    const arg = std.mem.trim(u8, rest, " \t");
    if (arg.len == 0) {
        try list(root.io, arena, out);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "rm ") or std.mem.startsWith(u8, arg, "remove ")) {
        const id = std.mem.trim(u8, arg[if (arg[0] == 'r' and arg[1] == 'm') 3 else 7..], " \t");
        if (playbook.retire(root.io, arena, id)) {
            @import("prompt_cache_hud.zig").noteBust(.playbook);
            refreshRoot(root, arena);
            try out.print("retired {s} — it no longer rides new briefs (the record stays in the log as a tombstone)\n", .{id});
        } else try out.print("no live playbook item with id '{s}' — /never lists them\n", .{id});
        try out.flush();
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
