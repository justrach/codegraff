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

/// Per-session record of file mutations (write_file/edit_file), so `/rewind`
/// can restore the working tree to an earlier turn. Mutex-guarded — tools run
/// on the pool concurrently. Bash edits are NOT tracked.
pub const Snapshots = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    list: std.ArrayList(Snapshot) = .empty,
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
                .absent => Io.Dir.cwd().deleteFile(self.io, snap.path) catch {},
                // Nothing was captured: there is nothing to put back, and
                // deleting would destroy content /rewind never owned.
                .unreadable => {
                    out.skipped += 1;
                    continue;
                },
            }
            out.restored += 1;
        }
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

    pub fn deinit(self: *Snapshots) void {
        for (self.list.items) |s| {
            self.gpa.free(s.path);
            if (s.before == .content) self.gpa.free(s.before.content);
        }
        self.list.deinit(self.gpa);
    }
};
