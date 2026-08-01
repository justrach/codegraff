//! Test-root references for modules the production import graph does not reach
//! from main.zig.
//!
//! Zig only compiles a `test` block if its file is reachable from the test
//! root. A module that nothing imports has its tests SILENTLY SKIPPED - they
//! still appear in the source, still read as coverage, and never run. That is
//! not hypothetical here: 12 files (37 tests) were in exactly that state,
//! including the whole of learn_tournament.zig - the ranking ladder that
//! decides which learned genome is promoted into the ROOT system prompt, with
//! cases like "critical child safety outranks higher pass rate" and "holdout
//! cannot rescue a primary rejection". Every one could have been broken with
//! the suite, the tier-1 gate and CI all green.
//!
//! Hooks live here rather than in main.zig's `test {}` block because that file
//! sits at the 600-line cap, so the natural home for a one-line fix has no room
//! for one - which is part of how the gap opened.
//!
//! scripts/eval/test_reachability.py is the guard: it diffs declared test names
//! against the names actually present in the compiled test binary, so a file
//! that drops out of the graph fails the build instead of going quiet. Adding a
//! module here is what makes that guard pass; do not delete a line without
//! checking the guard still does.

// Learning / DGM promotion pipeline.
const learn_holdout = @import("learn_holdout.zig");
const learn_receipt = @import("learn_receipt.zig");
const learn_report = @import("learn_report.zig");
const learn_run = @import("learn_run.zig");
const learn_submit = @import("learn_submit.zig");
const learn_tournament = @import("learn_tournament.zig");
const recipe = @import("recipe.zig");

// `graff repl` (zigzag TUI chat).
const repl = @import("repl.zig");
const repl_markdown = @import("repl_markdown.zig");
const repl_parser = @import("repl_parser.zig");

// Routing + worker selection.
const router_config = @import("router_config.zig");
const subagent_selection = @import("subagent_selection.zig");

// `graff serve` resumability (#330): serve.zig imports these, but nothing in
// the production graph references their decls, so Zig never analyses them.
const serve_events = @import("serve_events.zig");
const serve_create = @import("serve_create.zig");

// Moved off main.zig, which is at the 600-line cap.
const scoring_slot_test = @import("scoring_slot_test.zig");

// #345: the global-vs-project MCP config merge. mcp.zig does reference its
// decls, but the hook makes the coverage explicit rather than contingent on
// that staying true.
const mcp_config = @import("mcp_config.zig");

test {
    _ = learn_holdout;
    _ = learn_receipt;
    _ = learn_report;
    _ = learn_run;
    _ = learn_submit;
    _ = learn_tournament;
    _ = recipe;
    _ = repl;
    _ = repl_markdown;
    _ = repl_parser;
    _ = router_config;
    _ = subagent_selection;
    _ = serve_events;
    _ = serve_create;
    _ = scoring_slot_test;
    _ = mcp_config;
}
