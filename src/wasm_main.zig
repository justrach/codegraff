//! wasm32-freestanding entry for `graff-kernel.wasm`.
//!
//! Not the agent. fx's `fx-core.wasm` is a host-supplied ACP loop (JSPI
//! fetch, no bash). This artifact is the finite kernels — the 64-cell
//! catalog cube and the lexical path jail — so a JS host can evaluate the
//! same function Lean proves, without spawning `graff`.
//!
//! Build: `zig build wasm`. Do not import this file from the native test
//! root: it overrides `panic` and exports the C ABI.

const abi = @import("wasm_abi.zig");

var scratch: [abi.scratch_len]u8 = undefined;

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}

export fn graff_abi_version() u32 {
    return abi.abi_version;
}

export fn graff_cube_cells() u32 {
    return @intCast(@import("kernel_catalog.zig").cube_cells);
}

export fn graff_scratch_ptr() [*]u8 {
    return &scratch;
}

export fn graff_scratch_len() u32 {
    return scratch.len;
}

/// `catalog(flags)` → JSON array in the scratch buffer. Returns byte count
/// or -1 if the buffer is too small (it is not, for this kernel).
export fn graff_catalog(flags: u32) i32 {
    return abi.writeCatalog(flags, &scratch);
}

/// Reads a UTF-8 name from scratch[0..name_len]. 1 = advertised, 0 = not.
export fn graff_advertised(flags: u32, name_len: u32) i32 {
    if (name_len > scratch.len) return 0;
    return if (abi.advertised(flags, scratch[0..name_len])) 1 else 0;
}

/// Reads a UTF-8 path from scratch[0..path_len]. 1 = confined, 0 = jail-break.
export fn graff_confined(path_len: u32) i32 {
    if (path_len > scratch.len) return 0;
    return if (abi.confined(scratch[0..path_len])) 1 else 0;
}
