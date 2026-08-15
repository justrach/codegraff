//! Pure transport predicate. `agent_ws.wsEligible` is the Agent wrapper;
//! Lean `Graff.Transport.eligible` is the spec. This file is the shared
//! boolean so the 96-cell fixture test does not construct an Agent.

const Provider = @import("provider.zig").Provider;

pub const Flags = struct {
    kind: Provider.Kind,
    is_sub: bool,
    codex_ws: bool,
    ws_off: bool,
    has_out: bool,
    quiet: bool,
};

pub fn eligible(f: Flags) bool {
    if (f.kind != .responses) return false;
    if (f.is_sub) return false;
    if (!f.codex_ws) return false;
    if (f.ws_off) return false;
    if (!f.has_out) return false;
    if (f.quiet) return false;
    return true;
}

pub fn kindFromName(name: []const u8) ?Provider.Kind {
    if (std_mem.eql(u8, name, "anthropic")) return .anthropic;
    if (std_mem.eql(u8, name, "openai")) return .openai;
    if (std_mem.eql(u8, name, "responses")) return .responses;
    return null;
}

const std_mem = @import("std").mem;
