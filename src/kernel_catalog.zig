//! Name-list half of the ToolCatalog kernel.
//!
//! Freestanding: no process globals, no schema.zig, no I/O. Same function
//! Lean (`lean-proofs/Graff/ToolCatalog.lean`) and `spec/ref/tool_catalog.py`
//! export. The 64-cell flag cube is `{0,1}^6`; `catalog` is the ordered
//! name list at each point. Zig's live catalog (`schema.effectiveRootSpecs`)
//! is checked against the same fixtures in `spec_catalog_conformance.zig`.

const std = @import("std");

pub const Flags = struct {
    no_local: bool = false,
    lean: bool = false,
    imagegen: bool = false,
    clock_sleep: bool = false,
    learn_loaded: bool = false,
    is_sub: bool = false,
};

pub const FLAG_NO_LOCAL: u32 = 1 << 0;
pub const FLAG_LEAN: u32 = 1 << 1;
pub const FLAG_IMAGEGEN: u32 = 1 << 2;
pub const FLAG_CLOCK_SLEEP: u32 = 1 << 3;
pub const FLAG_LEARN_LOADED: u32 = 1 << 4;
pub const FLAG_IS_SUB: u32 = 1 << 5;

pub const cube_cells: usize = 64;
pub const max_names: usize = 32;

pub const local_tools = [_][]const u8{
    "bash",      "bash_output", "bash_kill", "read_file",
    "edit_file", "write_file",  "codedb",    "imagegen",
};
pub const lean_tools = [_][]const u8{
    "bash",               "read_file",         "edit_file",
    "write_file",         "codedb",            "subagent",
    "attempt_completion", "load_tool_schemas",
};
pub const optional_tools = [_][]const u8{"imagegen"};
pub const base_tools = [_][]const u8{
    "bash",      "bash_output", "bash_kill", "read_file",
    "edit_file", "write_file",  "webfetch",  "skill",
    "codedb",
};
pub const meta_tools = [_][]const u8{
    "todo_write", "todo_read",          "eval",              "note_constraint",
    "ask_user",   "attempt_completion", "load_tool_schemas", "clock_sleep",
};
pub const root_extras = [_][]const u8{
    "subagent",     "workflow",  "agent_output", "learn_candidate",
    "peer_message", "workspace",
};

pub fn unpack(bits: u32) Flags {
    return .{
        .no_local = bits & FLAG_NO_LOCAL != 0,
        .lean = bits & FLAG_LEAN != 0,
        .imagegen = bits & FLAG_IMAGEGEN != 0,
        .clock_sleep = bits & FLAG_CLOCK_SLEEP != 0,
        .learn_loaded = bits & FLAG_LEARN_LOADED != 0,
        .is_sub = bits & FLAG_IS_SUB != 0,
    };
}

pub fn pack(f: Flags) u32 {
    var bits: u32 = 0;
    if (f.no_local) bits |= FLAG_NO_LOCAL;
    if (f.lean) bits |= FLAG_LEAN;
    if (f.imagegen) bits |= FLAG_IMAGEGEN;
    if (f.clock_sleep) bits |= FLAG_CLOCK_SLEEP;
    if (f.learn_loaded) bits |= FLAG_LEARN_LOADED;
    if (f.is_sub) bits |= FLAG_IS_SUB;
    return bits;
}

fn mem(name: []const u8, list: []const []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn isLocal(name: []const u8) bool {
    return mem(name, &local_tools);
}

pub fn isOptional(name: []const u8) bool {
    return mem(name, &optional_tools);
}

pub fn isLeanKeep(name: []const u8) bool {
    return mem(name, &lean_tools);
}

fn keepRoot(f: Flags, name: []const u8) bool {
    if (!f.clock_sleep and std.mem.eql(u8, name, "clock_sleep")) return false;
    if (!f.learn_loaded and std.mem.eql(u8, name, "learn_candidate")) return false;
    return true;
}

/// Writes the advertised names into `out` (must hold `max_names`) and
/// returns how many were written. Order matches the Lean/Python kernel.
pub fn catalog(f: Flags, out: [][]const u8) usize {
    var n: usize = 0;
    const append = struct {
        fn go(dest: [][]const u8, i: *usize, name: []const u8, flags: Flags) void {
            // chosenSub is base only; imagegen still appends when flagged.
            if (!flags.is_sub and !keepRoot(flags, name)) return;
            if (flags.no_local and isLocal(name)) return;
            if (flags.lean and !flags.is_sub and !isLeanKeep(name)) return;
            dest[i.*] = name;
            i.* += 1;
        }
    }.go;

    if (f.is_sub) {
        for (base_tools) |name| append(out, &n, name, f);
    } else {
        for (base_tools) |name| append(out, &n, name, f);
        for (meta_tools) |name| append(out, &n, name, f);
        for (root_extras) |name| append(out, &n, name, f);
    }
    if (f.imagegen) append(out, &n, "imagegen", f);
    return n;
}

pub fn advertised(f: Flags, name: []const u8) bool {
    var buf: [max_names][]const u8 = undefined;
    const names = buf[0..catalog(f, &buf)];
    return mem(name, names);
}

pub fn blocked(f: Flags, name: []const u8) bool {
    return (f.no_local and isLocal(name)) or (isOptional(name) and !f.imagegen);
}

pub fn unique(names: []const []const u8) bool {
    for (names, 0..) |n, i| {
        if (mem(n, names[i + 1 ..])) return false;
    }
    return true;
}

/// Compact JSON array of advertised names into `out`. Returns bytes written,
/// or error.NoSpace when the buffer is too small.
pub fn catalogJson(f: Flags, out: []u8) error{NoSpace}!usize {
    var names: [max_names][]const u8 = undefined;
    const n = catalog(f, &names);
    var i: usize = 0;
    if (out.len == 0) return error.NoSpace;
    out[0] = '[';
    i = 1;
    for (names[0..n], 0..) |name, k| {
        if (k > 0) {
            if (i >= out.len) return error.NoSpace;
            out[i] = ',';
            i += 1;
        }
        if (i + 2 + name.len > out.len) return error.NoSpace;
        out[i] = '"';
        i += 1;
        @memcpy(out[i .. i + name.len], name);
        i += name.len;
        out[i] = '"';
        i += 1;
    }
    if (i >= out.len) return error.NoSpace;
    out[i] = ']';
    return i + 1;
}

fn allFlags() [cube_cells]Flags {
    var acc: [cube_cells]Flags = undefined;
    var i: usize = 0;
    var bits: u32 = 0;
    while (bits < cube_cells) : (bits += 1) {
        acc[i] = unpack(bits);
        i += 1;
    }
    return acc;
}

test "catalog cube is 64 cells" {
    try std.testing.expectEqual(cube_cells, allFlags().len);
}

test "cube: imagegen stays off when the flag is off" {
    for (allFlags()) |f| {
        if (!f.imagegen) try std.testing.expect(!advertised(f, "imagegen"));
    }
}

test "cube: no_local drops bash" {
    for (allFlags()) |f| {
        if (f.no_local) try std.testing.expect(!advertised(f, "bash"));
    }
}

test "cube: a child never sees subagent" {
    for (allFlags()) |f| {
        if (f.is_sub) try std.testing.expect(!advertised(f, "subagent"));
    }
}

test "cube: webfetch survives no_local unless lean-on-root" {
    for (allFlags()) |f| {
        if (f.no_local and !(f.lean and !f.is_sub)) {
            try std.testing.expect(advertised(f, "webfetch"));
        }
    }
}

test "cube: every cell's name list is unique" {
    for (allFlags()) |f| {
        var buf: [max_names][]const u8 = undefined;
        try std.testing.expect(unique(buf[0..catalog(f, &buf)]));
    }
}
