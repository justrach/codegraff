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
// Folded native tools (#416's two-phase pattern for the harness's own power
// tools): reached in production via schema.zig/exec.zig/agent_tools.zig.
const native_fold = @import("native_fold.zig");
const edit_batch = @import("edit_batch.zig");
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
const route_report = @import("route_report.zig"); // #471 credential/tier listing
// #380 vision-aware spawn routing + the report-time capability-honesty flag.
const vision_ask = @import("vision_ask.zig");
const vision_ask_tests = @import("vision_ask_tests.zig");
const pricing_tests = @import("pricing_tests.zig");
const zai_wire = @import("zai_wire.zig"); // Z.AI GLM-5.3 thinking + Vercel reasoning.effort
const provider_tests = @import("provider_tests.zig"); // URL overrides + vercel seat
const fitness_strata = @import("fitness_strata.zig");

// `graff serve` resumability (#330): serve.zig imports these, but nothing in
// the production graph references their decls, so Zig never analyses them.
const serve_events = @import("serve_events.zig");
const serve_create = @import("serve_create.zig");

// Moved off main.zig, which is at the 600-line cap.
const scoring_slot_test = @import("scoring_slot_test.zig");

// #273: session.zig's own tests, moved off it for the same reason.
const session_tests = @import("session_tests.zig");
// /help's sectioned render + the catalog-coverage guard.
const help = @import("help.zig");

// #441: and session_transcript.zig's, moved off it for the same reason again.
// The module itself is reached from session.queueSave, but this FILE is not, so
// without the hook its whole suite compiles to nothing and reports green.
// #429 batch 2 + #440: the env-knob guard. Its own module, so a knob that
// stops being parsed fails a test instead of vanishing silently.
const session_settings_tests = @import("session_settings_tests.zig");

const session_transcript_tests = @import("session_transcript_tests.zig");

// #415: /btw's tests. side_question.zig is reached in production from
// commands_misc.tryHandle, but nothing references THIS file, so without the
// hook its whole suite compiles to nothing and reports green.
const side_question_tests = @import("side_question_tests.zig");

// #415: and json_controls.zig's own. It IS imported by mainloop.zig, which is
// not enough - mainloop is reached from main() rather than from the test root's
// analysis, so its imports' test blocks compile to nothing (eval-tier1 --only
// reach caught exactly this).
const json_controls = @import("json_controls.zig");

// #445: moved off commands_session.zig when the transcript-line reset needed
// three lines there and the file was at exactly 600. The tests are unchanged.
const commands_session_test = @import("commands_session_test.zig");

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
const playbook_pick = @import("playbook_pick.zig");
const playbook_reflect = @import("playbook_reflect.zig");

// #391: the pre-compaction note store and its note turn. prompts.zig reaches
// compact_note.zig through a CALL only, and agent_compact.zig reaches the glue
// the same way, so neither pulls its tests in without these.
const compact_note = @import("compact_note.zig");
const compact_note_glue = @import("compact_note_glue.zig");
const peer_context = @import("peer_context.zig"); // ADR 0004 / #563 slice F
const peer_context_compact_test = @import("peer_context_compact_test.zig");
const peer_inbox = @import("peer_inbox.zig"); // Claude-style list/inbox pull
const peer_target = @import("peer_target.zig"); // exact DM / goal targeting
const session_peer = @import("session_peer.zig"); // ADR 0014 room cursor + inbox
const presence_mutate = @import("presence_mutate.zig"); // shared-tree classifiers
const workspace_switch = @import("workspace_switch.zig"); // ADR 0006 mid-session worktree switch
const result_read = @import("result_read.zig"); // overflow handle pager
const handle_preview = @import("handle_preview.zig"); // notable lines on first spill
const context_limits = @import("context_limits.zig"); // named prefix caps
const workspace_roots = @import("workspace_roots.zig"); // --add-dir extra roots
const list_dir = @import("list_dir.zig"); // codedb list_dir (BFS + gitignore)
const gitignore = @import("gitignore.zig"); // ignore matcher for list_dir
const mcp_select = @import("mcp_select.zig"); // search-then-select MCP
const plugins = @import("plugins.zig"); // ADR 0007 in-place plugin / foreign MCP discovery
const plugin_layout = @import("plugin_layout.zig"); // Claude commands/ + inline MCP + ${CLAUDE_PLUGIN_ROOT}
const plugin_scan = @import("plugin_scan.zig"); // timed discover + production cache
const plugin_index = @import("plugin_index.zig"); // Claude/Cursor installed_plugins.json
const plugin_codex = @import("plugin_codex.zig"); // Codex config.toml → PluginStore

// #345: the global-vs-project MCP config merge. mcp.zig does reference its
// decls, but the hook makes the coverage explicit rather than contingent on
// that staying true.
const mcp_config = @import("mcp_config.zig");
const turn_chrome = @import("turn_chrome.zig"); // #624 pulse + retry chrome
const tool_surface = @import("tool_surface.zig");
const agent_catalog = @import("agent_catalog.zig");
const session_connect_tests = @import("session_connect_tests.zig");
const effort_route = @import("effort_route.zig");

// #416: two-phase MCP tool exposure. schema.zig/exec.zig reach the gate, but
// its tests live in a sibling file that nothing in production imports.
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const mcp_schema_gate_tests = @import("mcp_schema_gate_tests.zig");

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
// #429 batch 3: the terminal halves the status line and the `/skills` command
// surface moved into, plus the policy leaf approvals.zig split its pure half
// out to. Production reaches all three through calls or aliases only.
const agent_prompt_render = @import("agent_prompt_render.zig");
const agent_working = @import("agent_working.zig");
const skill_docs_render = @import("skill_docs_render.zig");
const harness_policy = @import("harness_policy.zig");

// #412: the worktree fingerprint behind the no-progress verify guard.
// agent_eval.zig reaches it through a CALL only, which analyses nothing.
const verify_fingerprint = @import("verify_fingerprint.zig");

// #413: process START identity, the half of a lock owner record a recycled pid
// cannot forge. session_lock.zig and worktree_lease.zig reach it only through
// calls, and it is the kind of module whose tests must never go quiet: every
// cross-process lock in graff decides "stale or held" with it.
const proc_identity = @import("proc_identity.zig");

// #418: the billable-vs-context firewall between a completed child and its
// parent. Its own module because both files it pins the seam between
// (agent_context.zig, subagent.zig) sit at the 600-line cap.
const usage_attribution_tests = @import("usage_attribution_tests.zig");

// #554: the sandbox seam, its Docker backend, /snapshot + /rewind <id> + /teleport + gc
// commands, and the fake-docker orchestration suite. Production reaches
// commands_sandbox.zig from commands_misc.tryHandle and the rest only through
// calls, so without these hooks the whole subsystem's tests compile to nothing.
const sandbox = @import("sandbox.zig");
const sandbox_docker = @import("sandbox_docker.zig");
const commands_sandbox = @import("commands_sandbox.zig");
const sandbox_tests = @import("sandbox_tests.zig");

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
    _ = native_fold;
    _ = edit_batch;
    _ = subagent_tests;
    _ = bench_priors;
    _ = bench_priors_tests;
    _ = route_policy;
    _ = route_policy_tests;
    _ = route_trace;
    _ = route_phase;
    _ = route_check;
    _ = route_report;
    _ = vision_ask;
    _ = vision_ask_tests;
    _ = pricing_tests;
    _ = fitness_strata;
    _ = serve_events;
    _ = serve_create;
    _ = scoring_slot_test;
    _ = session_tests;
    _ = help;
    _ = session_transcript_tests;
    _ = session_settings_tests;
    _ = commands_session_test;
    _ = mcp_config;
    _ = mcp_schema_gate;
    _ = mcp_schema_gate_tests;
    _ = acp;
    _ = agent_eval_control_tests;
    _ = playbook_glue;
    _ = playbook_pick;
    _ = playbook_reflect;
    _ = compact_note;
    _ = compact_note_glue;
    _ = peer_context;
    _ = peer_context_compact_test;
    _ = peer_inbox;
    _ = peer_target;
    _ = session_peer;
    _ = presence_mutate;
    _ = workspace_switch;
    _ = result_read;
    _ = context_limits;
    _ = workspace_roots;
    _ = list_dir;
    _ = gitignore;
    _ = mcp_select;
    _ = plugins;
    _ = plugin_layout;
    _ = plugin_scan;
    _ = plugin_index;
    _ = shutdown_trace;
    _ = credential_store;
    _ = engine_events;
    _ = engine_sink;
    _ = agent_prompt_render;
    _ = agent_working;
    _ = skill_docs_render;
    _ = harness_policy;
    _ = verify_fingerprint;
    _ = proc_identity;
    _ = usage_attribution_tests;
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
    _ = side_question_tests;
    _ = json_controls;
    _ = effort_route;
    _ = sandbox;
    _ = sandbox_docker;
    _ = commands_sandbox;
    _ = sandbox_tests;
    _ = provider_tests;
    _ = turn_chrome;
    _ = tool_surface;
    _ = agent_catalog;
    _ = session_connect_tests;
    _ = @import("experiment_pool.zig");
    _ = @import("commands_experiment.zig");
    _ = @import("acp_engine.zig");
    _ = @import("libgraff.zig");
    _ = @import("tui_peer.zig");
    _ = @import("acp_auth.zig");
    _ = @import("local_tools.zig");
    _ = @import("schedule.zig");
    _ = @import("channel_worker.zig");
    _ = @import("session_wake.zig");
    _ = @import("tui_acp.zig");
}
