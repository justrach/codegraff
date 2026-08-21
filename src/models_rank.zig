//! Shared election rank for the model picker and the `/models` listing.
//!
//! Line REPL `/model`, line REPL `/models`, and the TUI `/model` overlay
//! (`/models` is an alias there) all rank seats through this module so a
//! signed-in plan (Codex, SuperGrok, Kimi) cannot sit below a paid seat
//! (Codegraff credits, a metered vendor key) on one surface and above it
//! on the other. Wired as the `models_rank` build import — a file import
//! from both the harness and TUI modules is illegal in Zig 0.17. The
//! class itself is `billing.CostClass`; this module is only the order.

/// Higher wins. A credential is the first cut — a signed-in Codegraff
/// seat is usable and an unsigned Codex seat is not — then the bill:
/// plan, then a machine-local server, then gateway credits, then a
/// metered API key. Catalog index is the tie-break, applied by the
/// caller so a stable empty-query list does not reshuffle every render.
pub fn electionRank(has_key: bool, cost: anytype) i32 {
    const keyed: i32 = if (has_key) 1_000_000 else 0;
    const seat: i32 = switch (cost) {
        .plan => 400_000,
        .local => 300_000,
        .credits => 200_000,
        .api => 0,
    };
    return keyed + seat;
}

pub const Scored = struct { idx: usize, score: i32 };

pub fn scoredLess(_: void, a: Scored, b: Scored) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.idx < b.idx;
}
