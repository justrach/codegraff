//! Declarative restrictions from the operator-owned settings file. An allow
//! means only "this gate has no objection"; it never grants approval elsewhere.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const settings_path = @import("harness_policy.zig").settings_path;
const invalid = "hard policy: invalid .harness/settings.json; fix its policies array of {action, resource, effect} statements before retrying";
const unavailable = "hard policy: cannot read .harness/settings.json; check its permissions and size (maximum 1 MiB) before retrying";

pub const Statement = struct {
    action: []const u8,
    resource: []const u8,
    effect: enum { allow, deny },
};

pub const Document = struct {
    statements: []const Statement = &.{},
    problem: ?[]const u8 = null,
    /// Immutable restrictions inherited from the spawning agent. Local allow
    /// statements never clear a denial in this separately evaluated ceiling.
    ceiling: ?*const Document = null,

    pub fn denial(self: Document, arena: Allocator, action: []const u8, resource: []const u8) ?[]const u8 {
        if (self.ceiling) |parent| if (parent.denial(arena, action, resource)) |reason| return reason;
        if (self.problem) |text| return text;
        var denied: ?usize = null;
        for (self.statements, 0..) |s, i| {
            if (!std.mem.eql(u8, s.action, action) or !matches(s.resource, resource)) continue;
            denied = if (s.effect == .deny) i else null;
        }
        const index = denied orelse return null;
        return std.fmt.allocPrint(arena, "hard policy denied {s} resource '{s}' (policies[{d}] in .harness/settings.json); ask the operator to change policy", .{ action, resource, index }) catch "hard policy denied operation (unable to allocate details)";
    }

    pub fn allows(self: Document, action: []const u8, resource: []const u8) bool {
        if (self.ceiling) |parent| if (!parent.allows(action, resource)) return false;
        if (self.problem != null) return false;
        var allowed = true;
        for (self.statements) |s| {
            if (std.mem.eql(u8, s.action, action) and matches(s.resource, resource)) allowed = s.effect == .allow;
        }
        return allowed;
    }
};

pub fn knownAction(action: []const u8) bool {
    for ([_][]const u8{ "provider.use", "tool.use", "mcp.use", "skill.use", "plugin.use", "websearch.use" }) |a| {
        if (std.mem.eql(u8, a, action)) return true;
    }
    return false;
}

/// Case-sensitive full-resource glob. Only '*' is special (zero or more bytes).
/// Iterative matching: no recursion or allocation even for hostile patterns.
pub fn matches(pattern: []const u8, resource: []const u8) bool {
    var p: usize = 0;
    var r: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (r < resource.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = r;
        } else if (p < pattern.len and pattern[p] == resource[r]) {
            p += 1;
            r += 1;
        } else if (star) |s| {
            retry += 1;
            r = retry;
            p = s + 1;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

fn bad(arena: Allocator, index: usize, why: []const u8) Document {
    return .{ .problem = std.fmt.allocPrint(arena, "hard policy: invalid policies[{d}] in .harness/settings.json: {s}; fix the statement before retrying", .{ index, why }) catch invalid };
}

/// Validate the ENTIRE configured list before evaluating any statement. A typo
/// in a later/nonmatching rule cannot silently remove a restriction.
pub fn parse(arena: Allocator, data: []const u8) Document {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{ .allocate = .alloc_always }) catch return .{ .problem = invalid };
    if (root != .object) return .{ .problem = invalid };
    const policies = root.object.get("policies") orelse return .{};
    if (policies != .array or policies.array.items.len > 1024) return .{ .problem = invalid };
    const statements = arena.alloc(Statement, policies.array.items.len) catch return .{ .problem = invalid };
    for (policies.array.items, 0..) |v, i| {
        if (v != .object or v.object.count() != 3) return bad(arena, i, "expected exactly action, resource, effect");
        const action = v.object.get("action") orelse return bad(arena, i, "missing action");
        const resource = v.object.get("resource") orelse return bad(arena, i, "missing resource");
        const effect = v.object.get("effect") orelse return bad(arena, i, "missing effect");
        if (action != .string or !knownAction(action.string)) return bad(arena, i, "unknown action (use provider.use, tool.use, mcp.use, skill.use, plugin.use, or websearch.use)");
        if (resource != .string or resource.string.len == 0 or resource.string.len > 512) return bad(arena, i, "resource must be a nonempty string of at most 512 bytes");
        for (resource.string) |ch| if (ch < 0x20 or ch == 0x7f) return bad(arena, i, "resource must not contain control characters");
        if (effect != .string) return bad(arena, i, "effect must be allow or deny");
        const e: @FieldType(Statement, "effect") = if (std.mem.eql(u8, effect.string, "allow")) .allow else if (std.mem.eql(u8, effect.string, "deny")) .deny else return bad(arena, i, "effect must be allow or deny");
        statements[i] = .{ .action = action.string, .resource = resource.string, .effect = e };
    }
    return .{ .statements = statements };
}

/// No permanent cache: reads use the supplied directory handle on every check,
/// so workspace switches, replacements, edits and trust revocation are visible
/// immediately. Missing configuration is one failed open and no allocations.
pub fn loadAt(io: Io, arena: Allocator, dir: Io.Dir) Document {
    const data = dir.readFileAlloc(io, settings_path, arena, .limited(1 << 20)) catch |err| return switch (err) {
        error.FileNotFound => .{},
        else => .{ .problem = unavailable },
    };
    return parse(arena, data);
}

pub fn check(io: Io, arena: Allocator, action: []const u8, resource: []const u8) ?[]const u8 {
    return checkAt(io, arena, Io.Dir.cwd(), action, resource);
}

pub fn checkAt(io: Io, arena: Allocator, dir: Io.Dir, action: []const u8, resource: []const u8) ?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const doc = loadAt(io, scratch.allocator(), dir);
    const reason = doc.denial(scratch.allocator(), action, resource) orelse return null;
    return arena.dupe(u8, reason) catch "hard policy denied operation (unable to allocate details)";
}
