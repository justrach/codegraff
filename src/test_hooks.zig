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
// #292 per-persona / per-spawn model pins: the module is reached in
// production (subagent.zig), but its split-out test files are not.
const subagent_pin_tests = @import("subagent_pin_tests.zig");
// Moved off subagent.zig, which is at the 600-line cap.
const subagent_tests = @import("subagent_tests.zig");
// Bench score/cost priors → derived tier ladders (.harness/bench.json).
const bench_priors = @import("bench_priors.zig");
const bench_priors_tests = @import("bench_priors_tests.zig");
// #372 learned orchestration policy + the per-worker routing trace.
const route_policy = @import("route_policy.zig");
const route_policy_tests = @import("route_policy_tests.zig");
const route_trace = @import("route_trace.zig");
// #376 phase-uniform learned routing + the rung-stratified fitness fold.
const route_phase = @import("route_phase.zig");
const route_check = @import("route_check.zig");
const pricing_tests = @import("pricing_tests.zig");
const fitness_strata = @import("fitness_strata.zig");

// `graff serve` resumability (#330): serve.zig imports these, but nothing in
// the production graph references their decls, so Zig never analyses them.
const serve_events = @import("serve_events.zig");
const serve_create = @import("serve_create.zig");

// Moved off main.zig, which is at the 600-line cap.
const scoring_slot_test = @import("scoring_slot_test.zig");

// #273: session.zig's own tests, moved off it for the same reason.
const session_tests = @import("session_tests.zig");

// #375: `graff acp` (Zed's Agent Client Protocol over stdio). args.zig calls
// one predicate from it, which analyses the file but does not run its tests.
const acp = @import("acp.zig");

// #382: moved off agent_tools.zig when the sibling-spawn diversity check
// needed two lines there and the file was at exactly 600. The tests are
// unchanged and still reachable — this is the file that exists for that.
const agent_eval_control_tests = @import("agent_eval_control_tests.zig");

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
    _ = subagent_pin_tests;
    _ = subagent_tests;
    _ = bench_priors;
    _ = bench_priors_tests;
    _ = route_policy;
    _ = route_policy_tests;
    _ = route_trace;
    _ = route_phase;
    _ = route_check;
    _ = pricing_tests;
    _ = fitness_strata;
    _ = serve_events;
    _ = serve_create;
    _ = scoring_slot_test;
    _ = session_tests;
    _ = mcp_config;
    _ = acp;
    _ = agent_eval_control_tests;
}
