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
// #380 vision-aware spawn routing + the report-time capability-honesty flag.
const vision_ask = @import("vision_ask.zig");
const vision_ask_tests = @import("vision_ask_tests.zig");
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

// #381/#383: the itemized playbook. playbook.zig is reached in production
// (prompts.zig, subagent_run.zig) and pulls its own tests in, but the glue and
// reflector modules are only ever reached through a call, so their tests need
// the hook.
const playbook_glue = @import("playbook_glue.zig");
const playbook_reflect = @import("playbook_reflect.zig");

// #345: the global-vs-project MCP config merge. mcp.zig does reference its
// decls, but the hook makes the coverage explicit rather than contingent on
// that staying true.
const mcp_config = @import("mcp_config.zig");

// The ultracode escalation ladder and the machinery it decides with. The
// production graph reaches escalation.zig/phase_budget.zig through
// workflow.zig, but only through a CALL — nothing references their decls at
// container level, so without these hooks the whole threshold matrix, the
// reservation ledger, the collapse gate and the #290 fold firewall would
// compile and never run a single test.
const escalation = @import("escalation.zig");
const escalation_tests = @import("escalation_tests.zig");
const edit_contract = @import("edit_contract.zig");
const phase_budget = @import("phase_budget.zig");
const orchestration_policy = @import("orchestration_policy.zig");
const orchestration_policy_tests = @import("orchestration_policy_tests.zig");
const orchestration_rows = @import("orchestration_rows.zig");
const workflow_pipeline = @import("workflow_pipeline.zig");
// #296: the pipeline stage-level fitness capture. Reached in production only
// through workflow_pipeline.run's CALL, so its tests need the hook.
const pipeline_score = @import("pipeline_score.zig");
const retry_hint = @import("retry_hint.zig");
const agent_compact_summary_test = @import("agent_compact_summary_test.zig");

// #364: shutdown-phase timings. Production reaches it from readline.zig,
// session.zig, mcp.zig, telemetry.zig and startup_timing.zig, so its coverage
// is contingent on those call sites staying — pinned here instead.
const shutdown_trace = @import("shutdown_trace.zig");

// `/rewind`'s snapshot store, split off tools.zig (600-line cap). Production
// reaches it only through a type alias, which analyses nothing.
const snapshots = @import("snapshots.zig");
const snapshots_tests = @import("snapshots_tests.zig");

// Atomic + owner-only credential writes. Production reaches it only through
// calls from oauth.zig and the catalog writers, so its own tests need the hook.
const credential_store = @import("credential_store.zig");

// #422: the engine event vocabulary + the sink boundary that dispatches it.
// Production reaches both only through CALLS, so their tests need the hook.
const engine_events = @import("engine_events.zig");
const engine_sink = @import("engine_sink.zig");

// #412: the worktree fingerprint behind the no-progress verify guard.
// agent_eval.zig reaches it through a CALL only, which analyses nothing.
const verify_fingerprint = @import("verify_fingerprint.zig");

// #413: process START identity, the half of a lock owner record a recycled pid
// cannot forge. session_lock.zig and worktree_lease.zig reach it only through
// calls, and it is the kind of module whose tests must never go quiet: every
// cross-process lock in graff decides "stale or held" with it.
const proc_identity = @import("proc_identity.zig");

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
    _ = vision_ask;
    _ = vision_ask_tests;
    _ = pricing_tests;
    _ = fitness_strata;
    _ = serve_events;
    _ = serve_create;
    _ = scoring_slot_test;
    _ = session_tests;
    _ = mcp_config;
    _ = acp;
    _ = agent_eval_control_tests;
    _ = playbook_glue;
    _ = playbook_reflect;
    _ = shutdown_trace;
    _ = credential_store;
    _ = engine_events;
    _ = engine_sink;
    _ = verify_fingerprint;
    _ = proc_identity;
    _ = escalation;
    _ = escalation_tests;
    _ = edit_contract;
    _ = phase_budget;
    _ = orchestration_policy;
    _ = orchestration_policy_tests;
    _ = orchestration_rows;
    _ = workflow_pipeline;
    _ = snapshots;
    _ = snapshots_tests;
    _ = pipeline_score;
    _ = retry_hint;
    _ = agent_compact_summary_test;
}
