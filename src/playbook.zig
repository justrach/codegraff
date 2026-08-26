//! #381 + #383 — the itemized playbook: one durable, project-local ledger of
//! short imperative bullets that ride every brief.
//!
//! Two issues, one substrate, because they are the same bug seen from two
//! sides. #381: a user said "no navigation dots", the root compacted, and
//! fresh subagents — who were never told — put the dots back. #383: 120
//! subagent reports full of durable repo knowledge ("no mobile menu exists,
//! don't invent one") evaporated with the context that held them. In both
//! cases the harness HAD the fact and dropped it on the floor between the
//! place it was learned and the brief that needed it.
//!
//! ACE (Zhang et al., ICLR 2026) supplies the shape and the hard rule:
//!
//!   * ITEMIZED, not a blob. Iteratively asking a model to rewrite a
//!     prompt-sized artifact causes context collapse and brevity bias — the
//!     failure #383 quotes. Bullets with stable ids merge instead.
//!   * CURATION IS DETERMINISTIC CODE. Nothing in this file asks a model
//!     what the playbook should contain. add/retire are explicit ops, dedupe
//!     is an exact match on normalized text, and the caps are constants. A
//!     model may PROPOSE an item (the #383 reflector) and the user may state
//!     one (#381), but only this code decides what lands.
//!
//! ON-DISK FORMAT — `.graff/playbook.jsonl`, append-only JSONL, matching the
//! `.graff/trajectories` conventions (one self-describing JSON object per
//! line, written whole or not at all, never rewritten in place):
//!
//!   {"v":1,"op":"add","id":"pb-3f8c1d02","text":"…","source":"user",
//!    "provenance":"user:1754…","created_at":1754…}
//!   {"v":1,"op":"retire","id":"pb-3f8c1d02","t":1754…}
//!
//! A retire is a NEW RECORD (a tombstone), never an edit, so a concurrent
//! reader mid-append sees either the old state or the new one — never a torn
//! file. `parse` replays the log in order and lets the last op for an id win,
//! which also makes re-adding a retired item work for free.
//!
//! IDS ARE CONTENT-DERIVED: `pb-` + 32 bits of Wyhash over the NORMALIZED
//! text. That makes dedupe and identity the same operation — two phrasings
//! that normalize identically cannot both exist, and an id is stable across
//! sessions and machines, which is what lets a later change attribute
//! per-item fitness to it.
//!
//! ASSEMBLY READS THE FILE, NEVER CONVERSATION MEMORY. `blockNow`'s input is
//! the ledger on disk at the moment a brief is built. That single choice is
//! what makes compaction survival automatic rather than a feature: there is
//! no in-context copy for compaction to summarize away, and a brand-new
//! session in the same project starts with the same constraints.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const trace = @import("trace.zig");

pub const dir = ".graff";
pub const path = ".graff/playbook.jsonl";

/// Whole-ledger read cap. A playbook is bullets, not a corpus; past this the
/// file is something else and injecting it would be the bug, not the fix.
pub const max_file_bytes = 512 * 1024;
/// Longest single item, in bytes, kept on disk and injected.
pub const max_text = 240;
/// #383 curator ceiling on stored LEARNED items. v1 refuses past it with a
/// note rather than evicting: eviction needs per-item fitness to be safe, and
/// that attribution is deliberately follow-up scope.
pub const max_learned = 100;

/// Injection caps. User items outrank learned ones on every axis — more of
/// them, more bytes, and always printed first — because a user constraint is
/// a rule and a learned bullet is a hint.
pub const user_block_items = 30;
pub const user_block_bytes = 2048;
pub const learned_block_items = 12;
pub const learned_block_bytes = 1024;

pub const user_header = "HARD CONSTRAINTS (user, do not violate):";
pub const learned_header = "PLAYBOOK (learned, advisory):";

pub const Source = enum {
    /// #381: a rejection the user stated. Never model-editable, hard-injected.
    user,
    /// #383: an insight distilled from a scored run. Advisory, capped, and
    /// printed after every user item.
    learned,

    pub fn parse(s: []const u8) Source {
        return if (std.mem.eql(u8, s, "learned")) .learned else .user;
    }
};

pub const Item = struct {
    id: []const u8,
    text: []const u8,
    source: Source,
    /// What minted it: `user:<unix ms>` for a typed/observed rejection,
    /// `run:<trajectory run id>` for a distilled one.
    provenance: []const u8 = "",
    created_at: i64 = 0,
};

/// Why an `add` did or did not land. A refusal is reported, never silent:
/// the model and the user both need to know a constraint was NOT recorded.
pub const Add = struct {
    ok: bool = false,
    id: []const u8 = "",
    /// Human/model-facing explanation; "" on success.
    reason: []const u8 = "",
};

/// Word bytes for normalization: ASCII alphanumerics plus every non-ASCII
/// byte, so a UTF-8 word stays one token instead of shattering (the same rule
/// brief_diversity.isWordByte uses, and for the same reason).
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// U+2000–U+206F (General Punctuation) encodes as E2 80 xx / E2 81 xx, and
/// that block is where a model or a paste actually gets its punctuation: em
/// and en dashes, curly quotes, the ellipsis, the bullet. They are dropped
/// like their ASCII cousins — otherwise `no dots — really` and `no dots
/// really` would be two separate constraints forever. Every OTHER non-ASCII
/// byte stays a word byte, so a non-Latin constraint is not shredded.
fn isPunctSeq(text: []const u8, i: usize) bool {
    return i + 2 < text.len and text[i] == 0xE2 and (text[i + 1] == 0x80 or text[i + 1] == 0x81);
}

/// Lowercase, drop punctuation, collapse runs of everything else to one
/// space. This is the whole dedupe key: "No emojis in code comments!" and
/// "no emojis in code comments" are the same constraint stated twice, and a
/// ledger that held both would inject the same rule twice forever.
pub fn normalize(out: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    var i: usize = 0;
    while (i < text.len) {
        if (isPunctSeq(text, i)) {
            pending_space = true;
            i += 3;
            continue;
        }
        const c = text[i];
        i += 1;
        if (!isWordByte(c)) {
            pending_space = true;
            continue;
        }
        if (n > 0 and pending_space and n < out.len) {
            out[n] = ' ';
            n += 1;
        }
        pending_space = false;
        if (n == out.len) break;
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    return out[0..n];
}

/// `pb-` + 32 bits of Wyhash over the normalized text (11 bytes).
pub fn idFor(out: *[11]u8, text: []const u8) []const u8 {
    var nbuf: [max_text]u8 = undefined;
    const h = std.hash.Wyhash.hash(0x381383, normalize(&nbuf, text));
    return std.fmt.bufPrint(out, "pb-{x:0>8}", .{@as(u32, @truncate(h))}) catch out[0..0];
}

fn strOf(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Replay the append-only log into the live item set, oldest first. Malformed
/// lines are skipped rather than fatal — a half-written tail from a killed
/// process must cost at most its own record.
pub fn parse(arena: Allocator, data: []const u8) []const Item {
    var list: std.ArrayList(Item) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (v != .object) continue;
        const id = strOf(v.object, "id") orelse continue;
        var at: ?usize = null;
        for (list.items, 0..) |item, i| if (std.mem.eql(u8, item.id, id)) {
            at = i;
            break;
        };
        if (std.mem.eql(u8, strOf(v.object, "op") orelse "add", "retire")) {
            if (at) |i| _ = list.orderedRemove(i);
            continue;
        }
        const text = strOf(v.object, "text") orelse continue;
        const created = v.object.get("created_at");
        const item: Item = .{
            .id = id,
            .text = text,
            .source = Source.parse(strOf(v.object, "source") orelse "user"),
            .provenance = strOf(v.object, "provenance") orelse "",
            .created_at = if (created) |c| (if (c == .integer) c.integer else 0) else 0,
        };
        if (at) |i| list.items[i] = item else list.append(arena, item) catch break;
    }
    return list.items;
}

/// The live ledger for the current working directory. An absent or unreadable
/// file is an empty playbook, never an error: every caller is on a path that
/// must keep working without one.
pub fn load(io: Io, arena: Allocator) []const Item {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch return &.{};
    return parse(arena, data);
}

pub fn countOf(items: []const Item, source: Source) usize {
    var n: usize = 0;
    for (items) |item| n += @intFromBool(item.source == source);
    return n;
}

pub fn find(items: []const Item, id: []const u8) ?Item {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

/// Unique live item whose normalized text contains `query`, or whose text
/// is contained in `query`. Ambiguous / too-short queries return null so a
/// caller can ask for an id instead of retiring the wrong rule (#638).
pub fn findByUniqueText(items: []const Item, query: []const u8) ?Item {
    var qbuf: [max_text]u8 = undefined;
    const q = normalize(&qbuf, query);
    if (q.len < 4) return null;
    var found: ?Item = null;
    for (items) |item| {
        var ibuf: [max_text]u8 = undefined;
        const it = normalize(&ibuf, item.text);
        if (it.len == 0) continue;
        if (std.mem.indexOf(u8, it, q) == null and std.mem.indexOf(u8, q, it) == null) continue;
        if (found != null) return null;
        found = item;
    }
    return found;
}

/// Append one already-serialized record. Positional write at the current end
/// of file so a whole line lands at once (serve_events.EventLog's shape).
fn appendLine(io: Io, line: []const u8) bool {
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return false;
    defer f.close(io);
    const st = f.stat(io) catch return false;
    f.writePositionalAll(io, line, st.size) catch return false;
    return true;
}

/// The one way an item is created. DETERMINISTIC: trim, cap, normalize,
/// derive the id, refuse an exact-normalized duplicate, enforce the learned
/// ceiling, append. No model is consulted and nothing existing is rewritten.
pub fn add(io: Io, arena: Allocator, text_in: []const u8, source: Source, provenance: []const u8) Add {
    const trimmed = std.mem.trim(u8, text_in, " \t\r\n-*");
    const text = util.utf8Prefix(trimmed, max_text);
    var nbuf: [max_text]u8 = undefined;
    if (normalize(&nbuf, text).len == 0) return .{ .reason = "empty constraint text" };
    var idbuf: [11]u8 = undefined;
    const id = arena.dupe(u8, idFor(&idbuf, text)) catch return .{ .reason = "out of memory" };
    const items = load(io, arena);
    if (find(items, id) != null) return .{ .id = id, .reason = "already recorded (same normalized text)" };
    if (source == .learned and countOf(items, .learned) >= max_learned)
        return .{ .id = id, .reason = "learned playbook is at its 100-item cap; retire some with /never rm <id> first" };
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(.{
        .v = @as(u8, 1),
        .op = "add",
        .id = id,
        .text = text,
        .source = @tagName(source),
        .provenance = provenance,
        .created_at = util.unixMs(io),
    }) catch return .{ .id = id, .reason = "could not serialize the record" };
    aw.writer.writeByte('\n') catch return .{ .id = id, .reason = "could not serialize the record" };
    if (!appendLine(io, aw.writer.buffered())) return .{ .id = id, .reason = "could not write " ++ path };
    return .{ .ok = true, .id = id };
}

/// Tombstone `id`. Returns false when no live item carries it, so a caller
/// can say "unknown id" instead of writing a tombstone for nothing.
pub fn retire(io: Io, arena: Allocator, id: []const u8) bool {
    if (find(load(io, arena), id) == null) return false;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(.{ .v = @as(u8, 1), .op = "retire", .id = id, .t = util.unixMs(io) }) catch return false;
    aw.writer.writeByte('\n') catch return false;
    return appendLine(io, aw.writer.buffered());
}

fn writeSection(w: *Io.Writer, items: []const Item, source: Source, header: []const u8, cap_items: usize, cap_bytes: usize) !void {
    var shown: usize = 0;
    var used: usize = 0;
    var omitted: usize = 0;
    // Newest first: the most recent "no" is the one most likely to be about
    // the work in flight, and it must survive the cap.
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const item = items[i];
        if (item.source != source) continue;
        if (shown >= cap_items or used + item.text.len + 3 > cap_bytes) {
            omitted += 1;
            continue;
        }
        if (shown == 0) try w.print("{s}\n", .{header});
        try w.print("- {s}\n", .{item.text});
        shown += 1;
        used += item.text.len + 3;
    }
    // An unstated truncation is a lie by omission: a worker told "these are
    // the constraints" must know when it was told only some of them.
    if (omitted > 0) try w.print("[{d} older item(s) omitted by the injection cap — the full ledger is {s}]\n", .{ omitted, path });
}

/// The injection block for `items`, or "" when there is nothing to say.
/// User items always precede learned ones and are capped more generously;
/// each section names itself so a worker can tell a rule from a hint.
pub fn blockFrom(arena: Allocator, items: []const Item) []const u8 {
    if (items.len == 0) return "";
    var aw: Io.Writer.Allocating = .init(arena);
    writeSection(&aw.writer, items, .user, user_header, user_block_items, user_block_bytes) catch return "";
    if (aw.writer.buffered().len > 0) aw.writer.writeByte('\n') catch return "";
    writeSection(&aw.writer, items, .learned, learned_header, learned_block_items, learned_block_bytes) catch return "";
    const out = std.mem.trim(u8, aw.writer.buffered(), "\n");
    return if (out.len == 0) "" else out;
}

/// The block for the ledger as it exists on disk RIGHT NOW. This is the
/// function every injection site calls, and reading the file here rather
/// than caching a copy in the conversation is the whole compaction-survival
/// mechanism.
pub fn blockNow(io: Io, arena: Allocator) []const u8 {
    return blockFrom(arena, load(io, arena));
}

/// Prepend the block to a brief. Identity when the ledger is empty, so a
/// project that never recorded anything pays nothing.
pub fn rideBrief(io: Io, arena: Allocator, prompt: []const u8) []const u8 {
    const b = blockNow(io, arena);
    if (b.len == 0) return prompt;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ b, prompt }) catch prompt;
}

/// Armed once by prompts.setRootSystemPrompts (production root agents only).
/// Unit tests never arm it, so prompts.setSystemPrompts stays the pure string
/// funnel its own tests assert — and no test path can reach the filesystem
/// through an `undefined` Io.
pub var g_root_inject: bool = false;

/// The ROOT's system prompt for the ledger as it exists on disk right now:
/// base, then the same block every worker brief carries. It lives in the
/// SYSTEM prompt rather than in a per-turn user message on purpose — a
/// re-pasted note lands in compaction input every single turn (#326's
/// lesson), while the system prompt is re-sent verbatim on every request and
/// is exactly what a compacted conversation cannot lose.
pub fn composeRoot(io: Io, arena: Allocator, base: []const u8) []const u8 {
    const items = load(io, arena);
    traceActive(arena, items);
    const b = blockFrom(arena, items);
    if (b.len == 0) return base;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ base, b }) catch base;
}

/// Comma-joined active ids, capped, for the trajectory row below.
pub fn idList(arena: Allocator, items: []const Item) []const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (items, 0..) |item, i| {
        if (i > 0) aw.writer.writeByte(',') catch break;
        aw.writer.writeAll(item.id) catch break;
    }
    return util.utf8Prefix(aw.writer.buffered(), 1024);
}

/// Fingerprint of the last emitted `kind:"playbook"` row, so re-composing an
/// unchanged ledger does not write the same row again.
var g_last_row: u64 = 0;

/// A NEW `kind:"playbook"` trajectory row naming which item ids were active,
/// rather than new columns on an existing row — the same additive discipline
/// #382's `kind:"diversity"` row established, and what a later change joins
/// against to attribute per-item fitness. Best-effort; never fails a caller.
pub fn traceActive(arena: Allocator, items: []const Item) void {
    const tj = trace.g_traj orelse return;
    const ids = idList(arena, items);
    const fp = std.hash.Wyhash.hash(0x381383, ids);
    if (fp == g_last_row) return;
    g_last_row = fp;
    tj.node(.{
        .kind = "playbook",
        .items = items.len,
        .user_items = countOf(items, .user),
        .learned_items = countOf(items, .learned),
        .ids = ids,
        .t = tj.elapsedMs(),
    });
}

test {
    _ = @import("playbook_tests.zig");
    _ = @import("playbook_pick.zig");
}
