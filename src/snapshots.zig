//! `/rewind`'s file-mutation history: the pre-write snapshot every mutating
//! tool (write_file/edit_file/imagegen) takes, and the restore that walks the
//! working tree back to an earlier turn. Split out of tools.zig (600-line cap)
//! when the snapshot grew its third state.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What a file looked like before the tool that is about to modify it ran.
/// Three states, not two: "could not read it" is NOT "it was not there", and
/// folding the first into the second made `/rewind` DELETE a file it had never
/// captured — a >4 MiB overwrite came back as StreamTooLong, was recorded as
/// absent, and the rewind removed it.
pub const Before = union(enum) {
    absent, // the file did not exist — rewind deletes it
    content: []const u8, // the bytes rewind writes back
    unreadable, // it existed but could not be read — rewind leaves it alone
};

/// Classify the pre-write read of the file a tool is about to clobber. ONLY
/// FileNotFound may become `.absent`; every other failure (StreamTooLong past
/// the read cap, AccessDenied, a mid-read I/O error) leaves us with no
/// snapshot, which must never turn into a delete.
pub fn beforeFromRead(result: anyerror![]u8) Before {
    const bytes = result catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .unreadable,
    };
    return .{ .content = bytes };
}

/// One pre-modification file snapshot, tagged with the turn that's about to
/// modify it.
const Snapshot = struct { turn: u32, path: []const u8, before: Before };

/// What one `/rewind` did: files put back (content rewritten, or deleted
/// because they were new), and files left exactly as they are because no
/// usable snapshot was ever taken.
pub const Rewound = struct { restored: usize = 0, skipped: usize = 0 };

pub const max_rewind_entries: usize = 8;
pub const max_rewind_paths: usize = 8;
pub const max_rewind_reason: usize = 120;

/// One append-only rewind ledger entry that survives `/rewind` and context
/// compaction so the agent does not repeat the same rolled-back dead-end.
pub const RewindRecord = struct {
    from_turn: u32,
    restored: usize = 0,
    skipped: usize = 0,
    paths: [][]const u8 = &.{},
    reason: []const u8 = "",
};

/// Per-session record of file mutations (write_file/edit_file), so `/rewind`
/// can restore the working tree to an earlier turn. Mutex-guarded — tools run
/// on the pool concurrently. Bash edits are NOT tracked.
pub const Snapshots = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    list: std.ArrayList(Snapshot) = .empty,
    rewinds: std.ArrayList(RewindRecord) = .empty,
    turn: u32 = 0, // the turn currently executing (set by the REPL loop)

    /// Record a file's pre-modification state (called before the write).
    pub fn record(self: *Snapshots, path: []const u8, before: Before) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const p = self.gpa.dupe(u8, path) catch return;
        const b: Before = switch (before) {
            .content => |x| .{ .content = self.gpa.dupe(u8, x) catch {
                self.gpa.free(p);
                return;
            } },
            else => before,
        };
        self.list.append(self.gpa, .{ .turn = self.turn, .path = p, .before = b }) catch {
            self.gpa.free(p);
            if (b == .content) self.gpa.free(b.content);
        };
    }

    /// Restore every file modified at turn ≥ n to its state before turn n, then
    /// drop those snapshots.
    pub fn restore(self: *Snapshots, n: u32) Rewound {
        return self.restoreWithReason(n, "");
    }

    /// Restore every file modified at turn ≥ n and record an append-only rewind
    /// ledger entry (with the rewound prompt or reason) that survives the drop.
    pub fn restoreWithReason(self: *Snapshots, n: u32, reason: []const u8) Rewound {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var done: std.ArrayList([]const u8) = .empty;
        defer done.deinit(self.gpa);
        var out: Rewound = .{};
        for (self.list.items) |snap| {
            if (snap.turn < n) continue;
            var seen = false;
            for (done.items) |d| if (std.mem.eql(u8, d, snap.path)) {
                seen = true;
            };
            if (seen) continue; // earliest snapshot per path wins (= state before turn n)
            done.append(self.gpa, snap.path) catch {};
            switch (snap.before) {
                .content => |b| Io.Dir.cwd().writeFile(self.io, .{ .sub_path = snap.path, .data = b }) catch continue,
                // A delete that FAILED left the file exactly as the rewound
                // turns wrote it, so it must not be counted as restored.
                // FileNotFound is the one exception: something else already
                // removed it, so the tree is in the state the rewind wanted.
                .absent => Io.Dir.cwd().deleteFile(self.io, snap.path) catch |err| {
                    if (err != error.FileNotFound) continue;
                },
                // Nothing was captured: there is nothing to put back, and
                // deleting would destroy content /rewind never owned.
                .unreadable => {
                    out.skipped += 1;
                    continue;
                },
            }
            out.restored += 1;
        }
        self.appendRewindLocked(n, out, done.items, reason);
        // Drop (and free) snapshots from the rewound turns.
        var i: usize = 0;
        while (i < self.list.items.len) {
            if (self.list.items[i].turn >= n) {
                const s = self.list.orderedRemove(i);
                self.gpa.free(s.path);
                if (s.before == .content) self.gpa.free(s.before.content);
            } else i += 1;
        }
        return out;
    }

    fn appendRewindLocked(self: *Snapshots, n: u32, out: Rewound, paths: []const []const u8, reason_in: []const u8) void {
        const trimmed = std.mem.trim(u8, reason_in, " \t\r\n");
        const first_line = if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| trimmed[0..nl] else trimmed;
        const capped_reason = first_line[0..@min(first_line.len, max_rewind_reason)];
        if (out.restored == 0 and out.skipped == 0 and capped_reason.len == 0) return;
        const reason_owned = self.gpa.dupe(u8, capped_reason) catch return;
        const take = @min(paths.len, max_rewind_paths);
        const paths_owned = self.gpa.alloc([]const u8, take) catch {
            self.gpa.free(reason_owned);
            return;
        };
        var copied: usize = 0;
        for (paths[0..take]) |p| {
            paths_owned[copied] = self.gpa.dupe(u8, p) catch {
                for (paths_owned[0..copied]) |prev| self.gpa.free(prev);
                self.gpa.free(paths_owned);
                self.gpa.free(reason_owned);
                return;
            };
            copied += 1;
        }
        if (self.rewinds.items.len >= max_rewind_entries) {
            const old = self.rewinds.orderedRemove(0);
            self.freeRewindRecord(old);
        }
        self.rewinds.append(self.gpa, .{
            .from_turn = n,
            .restored = out.restored,
            .skipped = out.skipped,
            .paths = paths_owned,
            .reason = reason_owned,
        }) catch {
            for (paths_owned) |p| self.gpa.free(p);
            self.gpa.free(paths_owned);
            self.gpa.free(reason_owned);
        };
    }

    fn freeRewindRecord(self: *Snapshots, rec: RewindRecord) void {
        for (rec.paths) |p| self.gpa.free(p);
        self.gpa.free(rec.paths);
        self.gpa.free(rec.reason);
    }

    /// Format the append-only rewind ledger for compaction handoffs and status
    /// inspection. Empty when no rewinds have occurred in this session.
    pub fn rewindDigest(self: *Snapshots, arena: Allocator) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.rewinds.items.len == 0) return "";
        var aw: Io.Writer.Allocating = .init(arena);
        aw.writer.print("- prior rolled-back attempts in this session ({d} rewind(s); do not repeat a reverted approach without changing strategy):", .{self.rewinds.items.len}) catch return "";
        for (self.rewinds.items) |rec| {
            const joined = std.mem.join(arena, ", ", rec.paths) catch "";
            if (joined.len > 0 and rec.reason.len > 0) {
                aw.writer.print("\n  * turn >={d} rewound (reverted {d} file(s): {s}; prompt: \"{s}\")", .{ rec.from_turn, rec.restored, joined, rec.reason }) catch break;
            } else if (joined.len > 0) {
                aw.writer.print("\n  * turn >={d} rewound (reverted {d} file(s): {s})", .{ rec.from_turn, rec.restored, joined }) catch break;
            } else if (rec.reason.len > 0) {
                aw.writer.print("\n  * turn >={d} rewound (prompt: \"{s}\")", .{ rec.from_turn, rec.reason }) catch break;
            } else {
                aw.writer.print("\n  * turn >={d} rewound (reverted {d} file(s), skipped {d})", .{ rec.from_turn, rec.restored, rec.skipped }) catch break;
            }
        }
        return aw.writer.buffered();
    }

    /// #411: the distinct paths this session has actually modified, in
    /// first-modified order, duped into `arena`. This ledger is the only
    /// EXACT answer the harness has to "what did I change this session" —
    /// which is also its bound: it records write_file/edit_file/imagegen, so
    /// an edit made through bash is not in it, and the note that prints these
    /// says so rather than implying the list is the whole diff. A `/rewind`
    /// has already dropped the snapshots it undid, so a rewound file
    /// correctly stops being listed.
    pub fn modifiedPaths(self: *Snapshots, arena: Allocator) []const []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.ArrayList([]const u8) = .empty;
        for (self.list.items) |snap| {
            var seen = false;
            for (out.items) |p| if (std.mem.eql(u8, p, snap.path)) {
                seen = true;
            };
            if (seen) continue;
            const owned = arena.dupe(u8, snap.path) catch return out.items;
            out.append(arena, owned) catch return out.items;
        }
        return out.items;
    }

    pub fn deinit(self: *Snapshots) void {
        for (self.list.items) |s| {
            self.gpa.free(s.path);
            if (s.before == .content) self.gpa.free(s.before.content);
        }
        self.list.deinit(self.gpa);
        for (self.rewinds.items) |rec| self.freeRewindRecord(rec);
        self.rewinds.deinit(self.gpa);
    }
};
