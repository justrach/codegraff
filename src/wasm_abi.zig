//! C ABI shared by `graff-kernel.wasm` and the native tests.
//!
//! The wasm surface is the kernel cube, not the agent: `catalog` / `advertised`
//! / `confined`. A JS host writes a UTF-8 string into the scratch buffer, then
//! calls the matching export. No JSPI — these functions are total and sync.

const std = @import("std");
const catalog = @import("kernel_catalog.zig");
const path = @import("kernel_path.zig");

pub const abi_version: u32 = 1;
pub const scratch_len: usize = 4096;

pub const FLAG_NO_LOCAL = catalog.FLAG_NO_LOCAL;
pub const FLAG_LEAN = catalog.FLAG_LEAN;
pub const FLAG_IMAGEGEN = catalog.FLAG_IMAGEGEN;
pub const FLAG_CLOCK_SLEEP = catalog.FLAG_CLOCK_SLEEP;
pub const FLAG_LEARN_LOADED = catalog.FLAG_LEARN_LOADED;
pub const FLAG_IS_SUB = catalog.FLAG_IS_SUB;

/// Writes `catalog(flags)` as a compact JSON string array into `out`.
/// Returns the byte count, or `-1` if `out` is too small.
pub fn writeCatalog(flags: u32, out: []u8) i32 {
    const n = catalog.catalogJson(catalog.unpack(flags), out) catch return -1;
    return @intCast(n);
}

pub fn advertised(flags: u32, name: []const u8) bool {
    return catalog.advertised(catalog.unpack(flags), name);
}

pub fn confined(p: []const u8) bool {
    return path.confined(p);
}

test "abi version is 1 and the cube is 64" {
    try std.testing.expectEqual(@as(u32, 1), abi_version);
    try std.testing.expectEqual(@as(usize, 64), catalog.cube_cells);
}

test "writeCatalog: default root is a JSON array that starts with bash" {
    var buf: [scratch_len]u8 = undefined;
    const n = writeCatalog(0, &buf);
    try std.testing.expect(n > 0);
    const json = buf[0..@intCast(n)];
    try std.testing.expect(std.mem.startsWith(u8, json, "[\"bash\""));
    try std.testing.expect(std.mem.endsWith(u8, json, "]"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"subagent\"") != null);
}

test "writeCatalog: lean root drops webfetch and keeps load_tool_schemas" {
    var buf: [scratch_len]u8 = undefined;
    const n = writeCatalog(FLAG_LEAN, &buf);
    try std.testing.expect(n > 0);
    const json = buf[0..@intCast(n)];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"webfetch\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"load_tool_schemas\"") != null);
}

test "advertised and confined are the same predicates as the kernels" {
    try std.testing.expect(advertised(0, "bash"));
    try std.testing.expect(!advertised(FLAG_NO_LOCAL, "bash"));
    try std.testing.expect(!advertised(FLAG_IS_SUB, "subagent"));
    try std.testing.expect(confined("src/main.zig"));
    try std.testing.expect(!confined("/etc/passwd"));
}

test "writeCatalog returns -1 when the buffer cannot hold the array" {
    var tiny: [2]u8 = undefined;
    try std.testing.expectEqual(@as(i32, -1), writeCatalog(0, &tiny));
}
