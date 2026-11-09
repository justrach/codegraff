//! Scope counting and R0 diagnostic formatting for workflow admission (#1759).
//! Split out of `escalation.zig` so PR/commit diff references and disambiguated
//! R0 admission counters stay under the 600-line ceiling.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const pb = @import("phase_budget.zig");

pub const fleet_scope_min: usize = 3;
pub const max_files_counted: usize = 32;

pub const solo_advice =
    "workflow declined (escalation R0): budget and scope fit solo work. This ask names 1-2 files, " ++
    "or the pool cannot cover a fleet plus the calls needed to land the work. Do it yourself — read " ++
    "the files, make the edits, verify — and re-invoke the workflow tool only if verification fails, " ++
    "which is the signal that earns a fleet.";

/// Bytes that can appear inside a path token. Excludes ':' and ',' so
/// `stats.py:24` and `a.py, b.py` still resolve to one file each.
pub fn isPathByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/' or c == '\\';
}

/// Does this token look like a file path? It needs an extension: a dot with
/// 1-5 letters after it and an alphanumeric before it. That refuses version
/// numbers ("3.11"), ellipses and sentence-ending periods, and accepts
/// `stats.py`, `src/main.zig` and `settings.json`.
pub fn looksLikeFile(tok: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, tok, '.') orelse return false;
    if (dot == 0 or dot + 1 >= tok.len) return false;
    if (!std.ascii.isAlphanumeric(tok[dot - 1])) return false;
    const ext = tok[dot + 1 ..];
    if (ext.len > 5) return false;
    for (ext) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

/// Does this token name a pull/diff path (`pull/123`, `pulls/123`, `pr/123`)
/// or a commit range (`main..feat`, `abc1234...def5678`)?
pub fn looksLikeDiffRef(tok: []const u8) ?[]const u8 {
    for ([_][]const u8{ "pull/", "pulls/", "pr/" }) |prefix| {
        if (std.mem.indexOf(u8, tok, prefix)) |idx| {
            const tail = tok[idx + prefix.len ..];
            var end: usize = 0;
            while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
            if (end > 0 and end <= 7) return tail[0..end];
        }
    }
    if (std.mem.indexOf(u8, tok, "..")) |dots| {
        const after = if (dots + 3 <= tok.len and tok[dots + 2] == '.') dots + 3 else dots + 2;
        const lhs = tok[0..dots];
        const rhs = tok[after..];
        if (lhs.len >= 2 and rhs.len >= 2 and isRevSide(lhs) and isRevSide(rhs)) return tok;
    }
    return null;
}

fn isRevSide(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '/') return false;
    }
    return true;
}

pub const FileSet = struct {
    hashes: [max_files_counted]u64 = @splat(0),
    n: usize = 0,

    pub fn add(self: *FileSet, tok: []const u8) void {
        if (self.n == self.hashes.len) return;
        var buf: [64]u8 = undefined;
        const m = @min(tok.len, buf.len);
        for (buf[0..m], tok[0..m]) |*d, s| d.* = std.ascii.toLower(s);
        const h = std.hash.Wyhash.hash(0, buf[0..m]);
        for (self.hashes[0..self.n]) |x| if (x == h) return;
        self.hashes[self.n] = h;
        self.n += 1;
    }

    pub fn scan(self: *FileSet, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and !isPathByte(text[i]) and text[i] != '#') : (i += 1) {}
            if (i >= text.len) break;
            if (text[i] == '#') {
                if (i == 0 or !std.ascii.isAlphanumeric(text[i - 1])) {
                    var j = i + 1;
                    while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) {}
                    const digits = text[i + 1 .. j];
                    if (digits.len > 0 and digits.len <= 7 and (j == text.len or !isPathByte(text[j]))) {
                        var ref_buf: [16]u8 = undefined;
                        const key = std.fmt.bufPrint(&ref_buf, "pr#{s}", .{digits}) catch "";
                        if (key.len > 0) self.add(key);
                        i = j;
                        continue;
                    }
                }
                i += 1;
                continue;
            }
            const start = i;
            while (i < text.len and isPathByte(text[i])) : (i += 1) {}
            if (i == start) continue;
            const tok = std.mem.trim(u8, text[start..i], ".");
            if (tok.len == 0) continue;
            if (looksLikeFile(tok)) {
                self.add(tok);
                continue;
            }
            if (looksLikeDiffRef(tok)) |ref_id| {
                if (std.ascii.isDigit(ref_id[0])) {
                    var ref_buf: [16]u8 = undefined;
                    const key = std.fmt.bufPrint(&ref_buf, "pr#{s}", .{ref_id}) catch "";
                    if (key.len > 0) self.add(key);
                } else {
                    self.add(ref_id);
                }
                continue;
            }
            if (parseExplicitFileCount(tok, text[i..])) |explicit_files| {
                const cap = @min(explicit_files, max_files_counted);
                for (0..cap) |idx| {
                    var unit_buf: [24]u8 = undefined;
                    const unit = std.fmt.bufPrint(&unit_buf, "diff-file-{d}", .{idx}) catch "";
                    if (unit.len > 0) self.add(unit);
                }
            }
        }
    }
};

fn parseExplicitFileCount(tok: []const u8, rest: []const u8) ?usize {
    const trimmed_num = std.mem.trimEnd(u8, tok, "+");
    if (trimmed_num.len == 0 or trimmed_num.len > 4) return null;
    for (trimmed_num) |c| if (!std.ascii.isDigit(c)) return null;
    const count = std.fmt.parseInt(usize, trimmed_num, 10) catch return null;
    if (count < fleet_scope_min) return null;
    var j: usize = 0;
    while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t' or rest[j] == '+' or rest[j] == '-')) : (j += 1) {}
    const tail = rest[j..];
    if (std.ascii.startsWithIgnoreCase(tail, "files")) {
        const after = tail["files".len..];
        if (after.len == 0 or !std.ascii.isAlphabetic(after[0])) return count;
    }
    return null;
}

/// Distinct file paths and diff/PR scope units named in `text`. Pure, allocation-free, and bounded.
pub fn countDistinctFiles(text: []const u8) usize {
    var set: FileSet = .{};
    set.scan(text);
    return set.n;
}

pub fn taskPrompts(pv: Value, set: *FileSet, tasks: *usize, widest: *usize) void {
    if (pv != .object) return;
    const tv = pv.object.get("tasks") orelse return;
    if (tv != .array) return;
    widest.* = @max(widest.*, tv.array.items.len);
    for (tv.array.items) |task_val| {
        tasks.* += 1;
        if (task_val != .object) continue;
        const p = task_val.object.get("prompt") orelse continue;
        if (p == .string) set.scan(p.string);
    }
}

/// Disambiguated R0 advisory reporting the actual admission reason and counters (#1759).
pub fn soloAdvice(arena: Allocator, o: anytype) []const u8 {
    const l = pb.Ledger.init(o.cap);
    const floor = pb.fleetFloor(o.shape);
    const reserve = pb.totalReserve(o.cap);
    const spendable = l.spendable(o.remaining);
    const budget_blocked = !l.fits(o.remaining, floor) or (o.plan_estimate > 0 and !l.fits(o.remaining, o.plan_estimate));
    const scope_blocked = o.files < fleet_scope_min or o.widest < 2;
    const reason = if (budget_blocked and scope_blocked)
        "budget_and_scope"
    else if (budget_blocked)
        "insufficient_budget"
    else
        "narrow_scope";
    return std.fmt.allocPrint(
        arena,
        "{s} [admission: reason={s}, scope_units={d}/{d}, widest_phase={d}, spendable_budget={d}, reserve={d}, plan_estimate={d}, fleet_floor={d}]",
        .{ solo_advice, reason, o.files, fleet_scope_min, o.widest, spendable, reserve, o.plan_estimate, floor },
    ) catch solo_advice;
}
