//! Content fingerprint shared by the session serializer and writer.
const std = @import("std");
const Value = std.json.Value;

/// A digest of everything the session file records about the conversation.
/// Content-derived, so a skip can never be wrong about "nothing changed" the
/// way a hand-maintained dirty flag can: the history has ~25 production
/// mutation sites (appends, compaction rewrites, in-place repairs), and one
/// missed site would silently drop a turn from disk.
pub const Fingerprint = struct {
    h: std.hash.Wyhash,

    pub fn init() Fingerprint {
        return .{ .h = std.hash.Wyhash.init(0x2735e5510) };
    }

    pub fn num(self: *Fingerprint, v: u64) void {
        var le: [8]u8 = undefined;
        std.mem.writeInt(u64, &le, v, .little);
        self.h.update(&le);
    }

    pub fn signed(self: *Fingerprint, v: i64) void {
        self.num(@bitCast(v));
    }

    pub fn flag(self: *Fingerprint, v: bool) void {
        self.h.update(&[_]u8{@intFromBool(v)});
    }

    /// Length-prefixed: "ab"+"c" must not collide with "a"+"bc".
    pub fn text(self: *Fingerprint, s: []const u8) void {
        self.num(s.len);
        self.h.update(s);
    }

    /// The same tree std.json.Stringify would walk, digested instead of
    /// formatted. Object fields are hashed in insertion order, which is the
    /// order they are serialized in.
    pub fn json(self: *Fingerprint, v: Value) void {
        self.h.update(&[_]u8{@intFromEnum(std.meta.activeTag(v))});
        switch (v) {
            .null => {},
            .bool => |b| self.flag(b),
            .integer => |i| self.signed(i),
            .float => |f| self.num(@bitCast(f)),
            .number_string, .string => |s| self.text(s),
            .array => |a| {
                self.num(a.items.len);
                for (a.items) |item| self.json(item);
            },
            .object => |o| {
                self.num(o.count());
                var it = o.iterator();
                while (it.next()) |e| {
                    self.text(e.key_ptr.*);
                    self.json(e.value_ptr.*);
                }
            },
        }
    }

    pub fn final(self: *Fingerprint) u64 {
        return self.h.final();
    }
};
