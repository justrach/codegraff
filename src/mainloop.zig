//! The root agent's interactive-REPL / --json-protocol event loop, split out
//! of main() (600-line goal). main() does all setup (arg parsing, key/model
//! resolution, trace/telemetry/MCP/hooks init, Agent construction, session
//! resume, the `repl`/oneshot-prompt early-exits) and OWNS every piece of
//! that setup's storage (`root: Agent`, `keys: Keys`, `tracer`, `traj`,
//! `telem`, `history`, `linebuf`, the stdin/stdout writers, ...) on its own
//! stack. This file only holds the loop body itself.
//!
//! Ctx bundles POINTERS into main()'s stack locals — main() builds one
//! `Ctx` value on ITS OWN stack and passes `&ctx` to `run`. Nothing here
//! ever owns or returns the address of `root`/`tracer`/`traj`/`telem`; they
//! keep living in main()'s frame for as long as `run` is on the stack, so
//! there is no dangling-pointer risk once `run` returns and main() resumes
//! its own post-loop cleanup (final session save, worktree autocommit).
//!
//! Back-imports main (as main_mod, since several helpers take a `root`
//! param) for Agent/Keys/the json_mode/plan_mode/max_tool_calls/
//! dedupe_tool_calls/g_force_interrupt/g_cwd_display/g_hooks live globals,
//! isSlashCommandLine, handleCommand, titleTask, and utf8Prefix — all pub
//! (isSlashCommandLine/handleCommand/titleTask newly flipped for this
//! split). Sibling-imports every already-extracted helper module directly
//! (ansi, pricing, prompts, providers, pickers, fleet, jobs, session,
//! repl_glue, scoring, trace, telemetry, vision, messages, anim, hooks,
//! readline, title.zig as title_mod) instead of going back through main's
//! private aliases for them.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const util = @import("util.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");

const ansi = @import("ansi.zig");
const style = &ansi.style;

const pricing = @import("pricing.zig");
const prompts = @import("prompts.zig");
const providers = @import("providers.zig");
const pickers = @import("pickers.zig");
const fleet = @import("fleet.zig");
const jobs = @import("jobs.zig");
const session = @import("session.zig");
const repl_glue = @import("repl_glue.zig");
const scoring = @import("scoring.zig");
const trace = @import("trace.zig");
const telemetry = @import("telemetry.zig");
const vision = @import("vision.zig");
const messages = @import("messages.zig");
const anim = @import("anim.zig");
const hooks = @import("hooks.zig");
const readline = @import("readline.zig");
const title_mod = @import("title.zig");

/// Pointers into main()'s stack locals — main() owns every field's storage
/// and builds this on its own stack right before calling `run`. `sys_normal`/
/// `sys_strict` are plain (arena-owned) slices, not pointers: they're the
/// frozen base system-prompt strings computed once in main() before the
/// loop, read (never mutated) here to reset/derive `root.sys_normal`/
/// `root.sys_strict`.
pub const Ctx = struct {
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,
    out: *Io.Writer,
    in: *Io.Reader,
    history: *std.ArrayList([]const u8),
    linebuf: *std.ArrayList(u8),
    interactive: bool,
    sys_normal: []const u8,
    sys_strict: []const u8,
};

/// Apply the backgrounded AI session title (titleTask) to the redrawable
/// window title + saved session filename. Called from BOTH the happy-path
/// post-turn step and the end-of-iteration `defer`, so an interrupted /
/// stalled / dropped / errored turn — which `continue`s before the post-turn
/// step — still lands the title instead of generating it then throwing it away
/// (ai_title_done is already set, so it would otherwise never regenerate and
/// the window title stays stuck on the prompt-derived fallback). Awaits once.
fn applyAiTitle(ctx: *Ctx, f: *Io.Future(?[]const u8)) void {
    if (f.await(ctx.io)) |t| {
        ctx.root.session_title = ctx.arena.dupe(u8, t) catch null;
        ctx.gpa.free(t);
        if (ctx.root.session_title) |st| {
            title_mod.setTerminalTitle(ctx.out, st, main_mod.g_cwd_display);
            session.renameSession(ctx.root, ctx.arena, session.slugifyTitle(ctx.arena, st));
        }
    }
}

/// The interactive-REPL / --json-protocol turn loop itself. Runs until EOF,
/// `exit`/`quit`/`q`, or a plain `break` out of the raw-line read. main()
/// resumes right after this returns and does its own final-save/worktree
/// cleanup (unchanged, still in main.zig).
pub fn run(ctx: *Ctx) !void {
    // Trajectory spine state: each turn's parent is the previous turn, and a
    // changed prompt fingerprint marks a set_system_prompt mutation edge.
    var prev_turn_id: u64 = 0;
    var prev_prompt_fp: [16]u8 = scoring.promptFingerprint(ctx.root.systemPrompt());

    while (true) {
        // Steering drain: prompts typed while the previous turn streamed
        // were captured into g_steer_queue. Run them now, one after
        // another, in place of reading a fresh line — Codex-style
        // follow-up queueing. (Empty in --json/GUI mode: no capture.)
        repl_glue.resetSteerPartial();
        const steer_entry: ?repl_glue.SteerEntry = repl_glue.popSteer();
        defer if (steer_entry) |e| std.heap.page_allocator.free(e.text);
        const raw_line: []const u8 = if (steer_entry) |e| blk: {
            if (e.force) {
                try ctx.out.print("{s}↳ force ›{s} {s}\n", .{ style.yellow, style.reset, e.text });
            } else {
                try ctx.out.print("{s}↳ steer ›{s} {s}\n", .{ style.cyan, style.reset, e.text });
            }
            try ctx.out.flush();
            break :blk e.text;
        } else if (ctx.interactive) blk: {
            try ctx.root.prompt();
            break :blk (try readline.readLine(ctx.root, ctx.in, ctx.out, ctx.gpa, ctx.history, ctx.linebuf)) orelse break;
        } else (try ctx.in.takeDelimiter('\n')) orelse break;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const loop_prompt: ?[]const u8 = if (!main_mod.json_mode and std.mem.startsWith(u8, line, "/loop "))
            std.mem.trim(u8, line["/loop".len..], " \t")
        else
            null;
        // /goal <objective>: set the standing goal AND run it as the first turn
        // right away — codex/opencode both start the loop on a goal instead of
        // just recording it. Bare /goal (show) and /goal clear/off stay commands.
        const goal_prompt: ?[]const u8 = if (!main_mod.json_mode and std.mem.startsWith(u8, line, "/goal ")) gblk: {
            const g = std.mem.trim(u8, line["/goal".len..], " \t");
            if (g.len == 0 or std.ascii.eqlIgnoreCase(g, "clear") or std.ascii.eqlIgnoreCase(g, "off")) break :gblk null;
            break :gblk g;
        } else null;
        if (!main_mod.json_mode) {
            const l = if (line.len > 0 and line[0] == '/') line[1..] else line;
            if (std.mem.eql(u8, l, "exit") or std.mem.eql(u8, l, "quit") or std.mem.eql(u8, l, "q")) break;
        }

        if (!main_mod.json_mode and repl_glue.isSlashCommandLine(line) and loop_prompt == null and goal_prompt == null) {
            // Bare "/" on a TTY: open the filterable command menu.
            if (ctx.interactive and line.len == 1) {
                if (pickers.listPicker(ctx.root, ctx.arena, ctx.out, "Command ›", &pickers.command_menu)) |idx| {
                    try main_mod.handleCommand(ctx.root, ctx.keys, ctx.arena, pickers.command_menu[idx].name, ctx.out);
                }
                continue;
            }
            try main_mod.handleCommand(ctx.root, ctx.keys, ctx.arena, line, ctx.out);
            continue;
        }

        // /goal <objective>: apply the goal (handleCommand sets root.goal, saves,
        // and prints), then fall through to run a turn on it immediately.
        if (goal_prompt != null) try main_mod.handleCommand(ctx.root, ctx.keys, ctx.arena, line, ctx.out);

        // The user message for this turn. In --json mode each input line is a
        // {"type":"user","text":"..."} request; {"type":"set_system_prompt",
        // "text":"...","append":bool} mutates the root system prompt between
        // turns (append=true tacks onto the current prompt instead of
        // replacing it) and acks with a system_prompt event — no turn runs;
        // {"type":"score","prompt_sha":"...","score":0.7,"notes":"..."}
        // appends an evaluation record for an agent variant to the
        // trajectory archive (the DGM evaluation phase writing back).
        const base_msg: []const u8 = if (loop_prompt) |lp| lp else if (goal_prompt) |gp| gp else if (main_mod.json_mode) blk: {
            const parsed = std.json.parseFromSliceLeaky(Value, ctx.arena, line, .{ .allocate = .alloc_always }) catch {
                ctx.root.emit(.{ .type = "error", .message = "invalid JSON (expect {\"type\":\"user\",\"text\":\"...\"})" });
                continue;
            };
            const rtype = if (parsed == .object)
                (if (parsed.object.get("type")) |v| (if (v == .string) v.string else "") else "")
            else
                "";
            if (std.mem.eql(u8, rtype, "set_model")) {
                const provider_field = if (parsed.object.get("provider")) |v| (if (v == .string) v.string else "") else "";
                const model_field = if (parsed.object.get("model")) |v| (if (v == .string) v.string else "") else "";
                const legacy_name = if (parsed.object.get("name")) |v| (if (v == .string) v.string else "") else "";
                const provider = providers.resolveProviderControlRequest(ctx.keys, ctx.arena, provider_field, model_field, legacy_name) catch |err| {
                    const label = providers.setModelRequestLabel(ctx.arena, provider_field, model_field, legacy_name) catch "<requested model>";
                    const message = switch (err) {
                        error.MissingKey => try std.fmt.allocPrint(ctx.arena, "no key/login for requested model '{s}'", .{label}),
                        error.InvalidModel => try std.fmt.allocPrint(ctx.arena, "unknown model '{s}'; refresh/list models before switching", .{label}),
                        error.InvalidModelRequest => "set_model needs a non-empty provider/model or legacy name",
                        else => try std.fmt.allocPrint(ctx.arena, "failed to switch model '{s}': {s}", .{ label, @errorName(err) }),
                    };
                    ctx.root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                const note = providers.applyProvider(ctx.root, ctx.arena, provider);
                ctx.root.emit(.{ .type = "model", .ok = true, .provider = provider.id, .model = provider.model, .context = provider.context, .note = note });
                continue;
            }
            if (std.mem.eql(u8, rtype, "compact")) {
                const chars = ctx.root.compact() catch |err| {
                    const message = switch (err) {
                        error.EmptySummary => "compaction failed: empty summary, history unchanged",
                        else => try std.fmt.allocPrint(ctx.arena, "compaction failed: {s}", .{@errorName(err)}),
                    };
                    ctx.root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                ctx.root.emit(.{ .type = "compact", .ok = true, .chars = chars });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_mode")) {
                const mode = if (parsed.object.get("mode")) |v| (if (v == .string) v.string else "") else "";
                if (std.mem.eql(u8, mode, "plan")) {
                    main_mod.plan_mode = true;
                } else if (std.mem.eql(u8, mode, "normal")) {
                    main_mod.plan_mode = false;
                } else {
                    ctx.root.emit(.{ .type = "error", .message = "set_mode needs mode 'plan' or 'normal'" });
                    continue;
                }
                ctx.root.emit(.{ .type = "mode", .ok = true, .mode = mode });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_agent")) {
                const id = if (parsed.object.get("id")) |v| (if (v == .string) v.string else "") else "";
                if (id.len == 0) {
                    ctx.root.sys_normal = ctx.sys_normal;
                    ctx.root.sys_strict = ctx.sys_strict;
                    ctx.root.emit(.{ .type = "agent", .ok = true, .id = id, .chars = ctx.root.sys_normal.len });
                    continue;
                }
                const prompt = fleet.agentTypePrompt(id) orelse {
                    const message = try std.fmt.allocPrint(ctx.arena, "unknown agent '{s}' (see /agents)", .{id});
                    ctx.root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                ctx.root.sys_normal = try std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}", .{ ctx.sys_normal, prompt });
                ctx.root.sys_strict = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ ctx.root.sys_normal, prompts.strict_note });
                ctx.root.emit(.{ .type = "agent", .ok = true, .id = id, .chars = ctx.root.sys_normal.len });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_effort")) {
                const level = if (parsed.object.get("level")) |v| (if (v == .string) v.string else "") else "";
                ctx.root.reasoning = std.meta.stringToEnum(main_mod.ReasoningEffort, level) orelse {
                    ctx.root.emit(.{ .type = "error", .message = "set_effort needs level low|medium|high|xhigh|max|ultra" });
                    continue;
                };
                _ = repl_glue.saveThinkingSettings(ctx.root.io, ctx.root.gpa, ctx.root.reasoning, ctx.root.fast, ctx.root.ultracode_mode, ctx.root.show_thinking, ctx.root.ai_title);
                ctx.root.emit(.{ .type = "effort", .ok = true, .level = level, .applies = ctx.root.effortApplies() });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_fast")) {
                const on = if (parsed.object.get("on")) |v| (if (v == .bool) v.bool else false) else false;
                ctx.root.fast = on;
                _ = repl_glue.saveThinkingSettings(ctx.root.io, ctx.root.gpa, ctx.root.reasoning, ctx.root.fast, ctx.root.ultracode_mode, ctx.root.show_thinking, ctx.root.ai_title);
                ctx.root.emit(.{ .type = "fast", .ok = true, .on = on, .applies = ctx.root.provider.kind == .responses });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_ultracode")) {
                const on = if (parsed.object.get("on")) |v| (if (v == .bool) v.bool else false) else false;
                ctx.root.ultracode_mode = on;
                _ = repl_glue.saveThinkingSettings(ctx.root.io, ctx.root.gpa, ctx.root.reasoning, ctx.root.fast, ctx.root.ultracode_mode, ctx.root.show_thinking, ctx.root.ai_title);
                ctx.root.emit(.{ .type = "ultracode", .ok = true, .on = on });
                continue;
            }
            if (std.mem.eql(u8, rtype, "score")) {
                // Fingerprint fields must be exactly 16 hex chars — a
                // length-only check would let an embedded newline through into
                // the signed v2 envelope (field-shift ambiguity).
                const hex16 = struct {
                    fn ok(s: []const u8) bool {
                        if (s.len != 16) return false;
                        for (s) |c| if (!std.ascii.isHex(c)) return false;
                        return true;
                    }
                };
                const sha = if (parsed.object.get("prompt_sha")) |v| (if (v == .string) v.string else "") else "";
                const sc: f64 = if (parsed.object.get("score")) |v| switch (v) {
                    .float => |x| x,
                    .integer => |x| @floatFromInt(x),
                    else => std.math.nan(f64),
                } else std.math.nan(f64);
                if (!hex16.ok(sha) or std.math.isNan(sc)) {
                    ctx.root.emit(.{ .type = "error", .message = "score needs prompt_sha (16 hex chars) and a numeric score" });
                    continue;
                }
                const reqStr = struct {
                    fn s(o: std.json.ObjectMap, k: []const u8) []const u8 {
                        return if (o.get(k)) |v| (if (v == .string) v.string else "") else "";
                    }
                };
                // SCORE SCALE CONTRACT (issue #168 Gap 4): the canonical wire
                // scale is [0,1]. An explicit "scale" field overrides the
                // heuristic (review F9): "percent" always divides by 100 and
                // accepts values up to 100 (so a percent-scale 0.5 means
                // 0.005, not 0.5); "unit" requires [0,1] as-is. Absent, the
                // heuristic applies: [0,1] passes, (1,100] is read as a
                // percentage and divides by 100, and anything else is rejected
                // here so the backend never has to clamp a 43 into a fake 1.0.
                const scale = reqStr.s(parsed.object, "scale");
                // An unrecognized scale must fail loudly, not fall through to
                // the heuristic — a typo like "Percent" silently reinterpreting
                // 0.7-of-100 as unit-scale 0.7 is a 100x corruption.
                if (scale.len > 0 and !std.mem.eql(u8, scale, "percent") and !std.mem.eql(u8, scale, "unit")) {
                    ctx.root.emit(.{ .type = "error", .message = "unknown scale: use \"unit\" or \"percent\" (or omit it for the [0,1]/(1,100] heuristic)" });
                    continue;
                }
                const normalized: ?f64 = if (std.mem.eql(u8, scale, "percent"))
                    (if (sc < 0 or sc > 100) null else sc / 100.0)
                else if (std.mem.eql(u8, scale, "unit"))
                    (if (sc < 0 or sc > 1) null else sc)
                else
                    scoring.normalizeOutboundScore(sc);
                const sc01 = normalized orelse {
                    ctx.root.emit(.{ .type = "error", .message = "score out of range: scale=\"unit\" requires [0,1], scale=\"percent\" requires [0,100] (sent as value/100); without scale, [0,1] passes, (1,100] is normalized to /100, and values outside [0,100] are rejected" });
                    continue;
                };
                const notes = if (parsed.object.get("notes")) |v| (if (v == .string) v.string else "") else "";
                // Optional genome lineage: which prompt this variant was
                // mutated from — the children-count input for DGM parent
                // selection.
                const parent = if (parsed.object.get("parent_sha")) |v| (if (v == .string and hex16.ok(v.string)) v.string else "") else "";
                // Provenance (Step 0): the driver names which judge produced
                // the score, the artifact it judged, and the eval-set hash;
                // run_id defaults to this session's. All are HMAC-signed so a
                // forged trajectory row is detectable. User-controlled fields
                // are sanitized (tab/newline/CR → ' ', review F7) BEFORE
                // signing so the signed bytes equal the transported bytes —
                // an embedded tab would otherwise split the prov transport.
                var jid_buf: [64]u8 = undefined;
                var art_buf: [64]u8 = undefined;
                const judge_id = scoring.sanitizeMetaField(&jid_buf, util.utf8Prefix(reqStr.s(parsed.object, "judge_id"), 64));
                const artifact_sha = scoring.sanitizeMetaField(&art_buf, util.utf8Prefix(reqStr.s(parsed.object, "artifact_sha"), 64));
                // DGM lever: when the score omits eval_set_hash but an --eval suite is
                // configured, stamp the suite's stable fingerprint so scores group into a
                // promotable (niche × tier × suite) cell. Same --eval cmd → same hash
                // across installs → the fleet can rank + promote a champion.
                var esh_buf: [16]u8 = undefined;
                var eshp_buf: [64]u8 = undefined;
                const eval_set_hash = eshblk: {
                    const provided = scoring.sanitizeMetaField(&eshp_buf, util.utf8Prefix(reqStr.s(parsed.object, "eval_set_hash"), 64));
                    if (provided.len > 0) break :eshblk provided;
                    if (ctx.root.eval_cmd) |c| {
                        esh_buf = scoring.promptFingerprint(c);
                        break :eshblk @as([]const u8, &esh_buf);
                    }
                    break :eshblk "";
                };
                // run_id is signed too — sanitize it like the other meta
                // fields so an embedded newline can't shift the v2 envelope
                // (one signature verifying two different field bindings).
                var run_buf: [64]u8 = undefined;
                const req_run = scoring.sanitizeMetaField(&run_buf, util.utf8Prefix(reqStr.s(parsed.object, "run_id"), 64));
                const run_id: []const u8 = if (req_run.len > 0) req_run else &scoring.g_run_id;
                // v2 envelope (issue #168 Gap 2): niche + provider_class are
                // signed, so a score for one cell can't be replayed into
                // another by mutating transport fields. The niche is truncated
                // to 64 (fleetEvent's own cap) and sanitized BEFORE signing so
                // the signed bytes match what the backend ingests.
                var niche_buf: [64]u8 = undefined;
                const req_niche = scoring.sanitizeMetaField(&niche_buf, util.utf8Prefix(reqStr.s(parsed.object, "niche"), 64));
                const pclass = scoring.providerClass(ctx.root.provider.model);
                const sig = scoring.signScore(sha, parent, sc01, run_id, judge_id, artifact_sha, eval_set_hash, req_niche, pclass);
                const signed = scoring.g_score_key != null;
                if (trace.g_traj) |tj| tj.node(.{
                    .kind = "score",
                    .prompt_sha = sha,
                    .parent_sha = parent,
                    .score = sc01,
                    .notes = util.utf8Prefix(notes, 200),
                    .run_id = run_id,
                    .judge_id = judge_id,
                    .artifact_sha = artifact_sha,
                    .eval_set_hash = eval_set_hash,
                    .niche = req_niche,
                    .provider_class = pclass,
                    .sig = if (signed) @as([]const u8, &sig) else "",
                    .t = tj.elapsedMs(),
                });
                var provbuf: [512]u8 = undefined;
                // prov = judge_id, artifact_sha, eval_set_hash + provider_class, niche —
                // all five folded into the v2 HMAC — so harness_scores can form
                // (niche x provider_class x eval_set_hash) cells the fleet ranks over.
                const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ judge_id, artifact_sha, eval_set_hash, pclass, req_niche }) catch "";
                if (telemetry.g_telem) |t| t.scoreEvent(sha, parent, sc01, run_id, if (signed) @as([]const u8, &sig) else "", prov);
                // fleet:submit (docs §9.B) — a scored, pinned-eval variant entered the fleet grid.
                if (eval_set_hash.len > 0) if (telemetry.g_telem) |t| t.fleetEvent("submit", req_niche, sha, "", pclass, eval_set_hash, 0, "");
                ctx.root.emit(.{ .type = "score", .ok = true, .prompt_sha = sha, .signed = signed });
                continue;
            }
            if (std.mem.eql(u8, rtype, "answer")) {
                ctx.root.emit(.{ .type = "error", .message = "answer received with no active ask_user prompt" });
                continue;
            }
            const t = if (parsed == .object) parsed.object.get("text") else null;
            const text = if (t) |v| (if (v == .string) v.string else "") else "";
            if (text.len == 0) {
                ctx.root.emit(.{ .type = "error", .message = "request needs a non-empty \"text\" field" });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_system_prompt")) {
                const append = if (parsed.object.get("append")) |v| v == .bool and v.bool else false;
                ctx.root.sys_normal = if (append)
                    try std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}", .{ ctx.root.sys_normal, text })
                else
                    try ctx.arena.dupe(u8, text);
                ctx.root.sys_strict = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ ctx.root.sys_normal, prompts.strict_note });
                ctx.root.emit(.{ .type = "system_prompt", .ok = true, .append = append, .chars = ctx.root.sys_normal.len });
                continue;
            }
            if (parsed.object.get("maxToolCalls") orelse parsed.object.get("max_tool_calls")) |v| switch (v) {
                .integer => |n| main_mod.max_tool_calls = if (n >= 0) @intCast(n) else null,
                .null => main_mod.max_tool_calls = null,
                else => {},
            };
            if (parsed.object.get("dedupeToolCalls") orelse parsed.object.get("dedupe_tool_calls")) |v| {
                if (v == .bool) main_mod.dedupe_tool_calls = v.bool;
            }
            break :blk text;
        } else line;

        if (ctx.root.fallback_blocked) {
            const message = try std.fmt.allocPrint(ctx.arena, "saved model unavailable; sending to {s} requires explicit consent — run /fallback allow {s} or choose /model", .{ ctx.root.provider.id, ctx.root.provider.id });
            if (main_mod.json_mode) ctx.root.emit(.{ .type = "error", .message = message }) else {
                try ctx.out.print("{s}⚠ {s}{s}\n", .{ style.yellow, message, style.reset });
                try ctx.out.flush();
            }
            continue;
        }

        // Persistent goal steering: the objective plus a nudge to track it as a
        // live todo_write checklist, with the current list appended so the model
        // resumes the plan instead of re-deriving it (assembled by goalSteeringNote).
        const todos_render: []const u8 = if (ctx.root.todos.items.len > 0) ctx.root.renderTodos() else "";
        const goal_note = try repl_glue.goalSteeringNote(ctx.arena, ctx.root.goal, todos_render);
        const eval_note = try repl_glue.evalSteeringNote(ctx.arena, ctx.root.eval_cmd, ctx.root.eval_target, ctx.root.eval_judge != null);
        var goal_msg: []const u8 = base_msg;
        if (goal_note.len > 0) goal_msg = try std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}", .{ goal_msg, goal_note });
        if (eval_note.len > 0) goal_msg = try std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}", .{ goal_msg, eval_note });

        // /loop asks the model to work autonomously through plan→act→verify.
        const loop_msg: []const u8 = if (loop_prompt != null) try std.fmt.allocPrint(ctx.arena,
            \\{s}
            \\
            \\[harness note: /loop was used. Work autonomously until the prompt is satisfied: make a brief plan, execute it with tools, verify the result, and only stop when you can report completion or you need a required human decision. Keep iterations tight and avoid asking for confirmation between routine steps.]
        , .{goal_msg}) else goal_msg;

        // Plan mode: steer the model to explore read-only and present a plan
        // (the gate enforces the read-only part regardless).
        const msg: []const u8 = if (!main_mod.plan_mode) loop_msg else try std.fmt.allocPrint(ctx.arena,
            \\{s}
            \\
            \\[harness note: plan mode is ON — read-only. Explore with read-only
            \\tools as needed, then present a concrete plan (files to change,
            \\the changes themselves, sequence, risks) and ask the user to
            \\approve it. Do not write files or run mutating commands — the
            \\gate will deny them. The user toggles execution back on with /plan.]
        , .{loop_msg});

        // Promote a GUI `@[image]` attachment to a native vision block when the
        // model can see (otherwise it only gets the path and resorts to OCR).
        vision.stageGuiImageAttachment(ctx.root, msg);

        // Generate the AI tab-title concurrently (io.async), spawned BEFORE the
        // header so the first-turn header can wait for the summary title. Applied
        // after the turn on the happy path (below); the defer is the fallback for
        // an interrupted/stalled/dropped/errored turn (those `continue` before the
        // apply step) so the generated title is never silently discarded.
        var title_fut: ?Io.Future(?[]const u8) = null;
        if (!main_mod.json_mode and ctx.root.ai_title and !ctx.root.ai_title_done) {
            ctx.root.ai_title_done = true;
            title_fut = ctx.io.async(title_mod.titleTask, .{ ctx.gpa, ctx.io, ctx.root.client, ctx.root.provider, base_msg });
        }
        defer if (title_fut) |*f| {
            applyAiTitle(ctx, f);
        };

        // TUI/session header: once the first real prompt materializes the chat,
        // show what this terminal tab is working on and the exact folder, and
        // keep the window title in sync each turn.
        if (!main_mod.json_mode) {
            if (!ctx.root.tui_header_shown) {
                // Print the header IMMEDIATELY with the fast prompt-derived title so
                // the AI summary call (titleTask, spawned just above with io.async)
                // never blocks the response. The printed header scrolls into
                // scrollback and can't be redrawn, so it keeps the prompt title; the
                // AI summary runs in the background overlapping the turn and lands on
                // the redrawable window title + the session filename in the post-turn
                // handler below. (#91 made the reverse trade — blocking the turn so the
                // *printed* card read as a summary — but an extra round-trip in front
                // of every first response isn't worth it.)
                const turn_title = title_mod.titleFromPrompt(base_msg);
                title_mod.setTerminalTitle(ctx.out, turn_title, main_mod.g_cwd_display);
                try title_mod.printSessionHeader(ctx.out, turn_title, main_mod.g_cwd_display);
                ctx.root.tui_header_shown = true;
            } else {
                // Later turns: keep the OSC tab/window title synced; header shown.
                const turn_title = ctx.root.session_title orelse title_mod.titleFromPrompt(base_msg);
                title_mod.setTerminalTitle(ctx.out, turn_title, main_mod.g_cwd_display);
            }
        }

        // "ultracode" codeword or persistent /ultracode mode: opt turns into multi-agent workflow mode.
        const ultracode_msg = try pickers.applyUltracodeSteering(ctx.arena, msg, base_msg, ctx.root.ultracode_mode or ctx.root.reasoning == .ultra);
        if (ultracode_msg.explicit) {
            if (!main_mod.json_mode) {
                if (ctx.interactive) {
                    anim.ultracodeShine(ctx.out, ctx.io);
                    try ctx.out.writeAll("⚡ multi-agent workflow mode engaged\n");
                } else {
                    try ctx.out.writeAll("⚡ ultracode — multi-agent workflow mode engaged\n");
                }
                try ctx.out.flush();
            }
            ctx.root.tracer.?.note("ultracode", msg[0..@min(msg.len, 120)]);
            if (telemetry.g_telem) |t| t.ultracode();
        }
        if (ctx.root.pending_image) |img| {
            try ctx.root.messages.append(try vision.imageMessage(ctx.arena, ctx.root.provider.kind, ultracode_msg.text, img));
            ctx.root.pending_image = null;
        } else try ctx.root.messages.append(try messages.textMessage(ctx.arena, "user", ultracode_msg.text));
        ctx.root.snapshots.?.turn += 1; // tag file edits in this turn (matches /rewind numbering)
        if (telemetry.g_telem) |t| t.countTurn();
        // Trajectory: claim this turn's node id up front so subagents spawned
        // during the turn can attach to it as their parent.
        const turn_id: u64 = if (trace.g_traj) |tj| blk: {
            const id = tj.nextId();
            tj.setTurn(id);
            break :blk id;
        } else 0;
        ctx.root.tools_used.clear(ctx.io); // per-turn tool log for the turn's node
        ctx.root.tool_calls_this_turn = 0;
        ctx.root.seen_tool_keys.clearRetainingCapacity();
        if (main_mod.json_mode) ctx.root.emit(.{ .type = "started", .provider = ctx.root.provider.id, .model = ctx.root.provider.model });
        // Breathing room between the submitted input and the turn's first
        // output — without it the reply starts on the very next line and
        // reads as a continuation of what the user typed.
        if (ctx.interactive and !main_mod.json_mode) {
            try ctx.out.writeAll("\n");
            try ctx.out.flush();
        }
        const turn_started = Io.Timestamp.now(ctx.io, .awake);
        // A failed turn must never kill the session: ApiError is already
        // reported inside request(); anything else is surfaced here. Either
        // way we drop back to the prompt (or emit a JSON error/turn event).
        const turn_result = providers.runTurnWithFallback(ctx.root, ctx.keys.*, ctx.arena, ctx.out);
        if (trace.g_traj) |tj| {
            const fp = scoring.promptFingerprint(ctx.root.systemPrompt());
            const turn_ms: i64 = @intCast(@max(0, turn_started.untilNow(ctx.io, .awake).toMilliseconds()));
            const turn_ok = if (turn_result) |_| true else |_| false;
            const turn_tools = ctx.root.tools_used.render(ctx.arena);
            tj.capturePrompt(fp, ctx.root.systemPrompt());
            tj.node(.{
                .id = turn_id,
                .parent = prev_turn_id,
                .kind = "turn",
                .label = ctx.root.provider.model,
                .t = tj.elapsedMs(),
                .ms = turn_ms,
                .prompt_sha = &fp,
                .prompt_mutated = !std.mem.eql(u8, &fp, &prev_prompt_fp),
                .task = util.utf8Prefix(base_msg, 160),
                .tools = turn_tools,
                .ok = turn_ok,
                .context_tokens = ctx.root.last_context_tokens,
            });
            // Preserve the failure reason in the archive: the turn node only
            // records ok:false, so an adjacent error record keeps the
            // user-visible detail (network give-up, api error) joinable to it (#86).
            if (!turn_ok) {
                const fail_detail: []const u8 = if (turn_result) |_| "" else |e| switch (e) {
                    error.ApiError => ctx.root.last_api_error orelse "api error",
                    error.StreamStalled => ctx.root.last_api_error orelse "stream stalled — ended turn",
                    error.StreamDropped => ctx.root.last_api_error orelse "stream dropped — ended turn",
                    else => @errorName(e),
                };
                tj.node(.{ .kind = "turn_error", .parent = turn_id, .t = tj.elapsedMs(), .detail = fail_detail });
            }
            if (telemetry.g_telem) |t| t.runEvent(&fp, !std.mem.eql(u8, &fp, &prev_prompt_fp), turn_ok, turn_ms, turn_tools);
            prev_turn_id = turn_id;
            prev_prompt_fp = fp;
        }
        const final_text = turn_result catch |err| switch (err) {
            error.Interrupted => {
                // Esc: keep what streamed so far in history (as an assistant
                // turn with an explicit marker) so the conversation stays
                // coherent, then drop back to the prompt.
                const partial = std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n");
                const marker: []const u8 = if (partial.len > 0)
                    try std.fmt.allocPrint(ctx.arena, "{s}\n\n[response interrupted by user]", .{partial})
                else
                    "[response interrupted by user]";
                try ctx.root.messages.append(try messages.textMessage(ctx.arena, "assistant", marker));
                const int_msg: []const u8 = if (main_mod.g_force_interrupt) "✗ interrupted (force)" else "✗ interrupted (esc)";
                main_mod.g_force_interrupt = false;
                try ctx.out.print("{s}{s}{s}\n", .{ style.yellow, int_msg, style.reset });
                try ctx.out.flush();
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
            error.StreamStalled => {
                // A dead/idle stream (no SSE bytes for stream_stall_ms): the
                // harness gave up, NOT the user (#134) — keep the partial but
                // tag it a stall, and emit the structured error for --json.
                const partial = std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n");
                const marker: []const u8 = if (partial.len > 0)
                    try std.fmt.allocPrint(ctx.arena, "{s}\n\n[response ended early: stream stalled]", .{partial})
                else
                    "[response ended early: stream stalled]";
                try ctx.root.messages.append(try messages.textMessage(ctx.arena, "assistant", marker));
                if (main_mod.json_mode) {
                    ctx.root.emit(.{ .type = "error", .message = ctx.root.last_api_error orelse "stream stalled — ending turn" });
                    if (partial.len > 0) {
                        ctx.root.emit(.{ .type = "finalizing" });
                        ctx.root.emit(.{ .type = "turn", .text = partial, .context_tokens = ctx.root.last_context_tokens, .cost_usd = pricing.g_cost.snap(ctx.io).usd, .complete = false, .metadata_complete = ctx.root.last_context_tokens > 0 });
                    }
                }
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
            error.StreamDropped => {
                // The provider closed/reset the connection before its terminal
                // event ([DONE]/finish_reason) — the harness ended the turn, NOT
                // the user (#133). Keep the partial, tag it a drop (never
                // "[response interrupted by user]"), and emit the --json error.
                const partial = std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n");
                const marker: []const u8 = if (partial.len > 0)
                    try std.fmt.allocPrint(ctx.arena, "{s}\n\n[response ended early: connection dropped]", .{partial})
                else
                    "[response ended early: connection dropped]";
                try ctx.root.messages.append(try messages.textMessage(ctx.arena, "assistant", marker));
                if (main_mod.json_mode) {
                    ctx.root.emit(.{ .type = "error", .message = ctx.root.last_api_error orelse "stream dropped — ending turn" });
                    if (partial.len > 0) {
                        ctx.root.emit(.{ .type = "finalizing" });
                        ctx.root.emit(.{ .type = "turn", .text = partial, .context_tokens = ctx.root.last_context_tokens, .cost_usd = pricing.g_cost.snap(ctx.io).usd, .complete = false, .metadata_complete = ctx.root.last_context_tokens > 0 });
                    }
                }
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
            error.ApiError => {
                if (telemetry.g_telem) |t| t.errorEvent("api", ctx.root.last_api_error orelse "api error");
                if (main_mod.json_mode) {
                    ctx.root.emit(.{ .type = "error", .message = ctx.root.last_api_error orelse "api error" });
                    const partial = std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n");
                    if (partial.len > 0) {
                        ctx.root.emit(.{ .type = "finalizing" });
                        ctx.root.emit(.{ .type = "turn", .text = partial, .context_tokens = ctx.root.last_context_tokens, .cost_usd = pricing.g_cost.snap(ctx.io).usd, .complete = false, .metadata_complete = ctx.root.last_context_tokens > 0 });
                    }
                }
                // A turn can fail because the context window overflowed; if we're
                // over the compaction threshold, compact (or emergency-trim) now
                // so the next turn isn't doomed to fail at the same size (#88).
                if (ctx.root.last_context_tokens >= ctx.root.provider.compactAt()) ctx.root.compactOrRecover(true);
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
            else => |e| {
                if (telemetry.g_telem) |t| t.errorEvent("turn", @errorName(e));
                if (main_mod.json_mode) {
                    ctx.root.emit(.{ .type = "error", .message = @errorName(e) });
                } else {
                    ctx.root.say("[turn aborted: {t}]\n", .{e}) catch {};
                }
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
        };
        if (main_mod.json_mode) {
            const emitted_text = if (final_text.len == 0 and ctx.root.partial_text.items.len > 0)
                std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n")
            else
                final_text;
            ctx.root.emit(.{ .type = "finalizing" });
            ctx.root.emit(.{ .type = "turn", .text = emitted_text, .context_tokens = ctx.root.last_context_tokens, .cost_usd = pricing.g_cost.snap(ctx.io).usd, .complete = true, .metadata_complete = ctx.root.last_context_tokens > 0 });
            // #124: allocator-level leak telemetry (GRAFF_MEM_DEBUG=1) — arena
            // capacity per turn separates a session-arena leak from gpa-side
            // growth, which OS-level RSS sampling can't tell apart.
            if (main_mod.g_mem_debug) ctx.root.emit(.{
                .type = "mem",
                .session_arena_kb = if (main_mod.g_session_arena) |a| a.queryCapacity() / 1024 else 0,
                .scratch_arena_kb = if (ctx.root.scratch_arena) |a| a.queryCapacity() / 1024 else 0,
            });
        }

        // Apply the AI summary title + fleet champions that ran in the background
        // overlapping the turn — both off the critical path. The printed header kept
        // the fast prompt title; the summary now lands on the redrawable window title
        // and the saved session filename. Usually already resolved by here.
        if (title_fut) |*f| {
            applyAiTitle(ctx, f);
            title_fut = null;
        }
        fleet.joinElites(ctx.io); // publish backgrounded fleet champions for the next turn (no-op once joined)

        // turn_end lifecycle hooks (best-effort; interrupted/errored turns
        // `continue` above and never reach here, so ok is always true).
        if (main_mod.g_hooks.turn_end.len > 0) {
            for (main_mod.g_hooks.turn_end) |h| {
                const res = hooks.runHookCmd(ctx.gpa, ctx.io, h.command, "{\"event\":\"turn_end\",\"ok\":true}", h.timeout_ms);
                if (res.stderr.len > 0) ctx.gpa.free(res.stderr);
            }
        }

        if (ctx.root.last_context_tokens >= ctx.root.provider.compactAt()) {
            // Trim on failure only when we're genuinely against the window — at
            // 80–95% a transient compaction failure can recover next turn.
            const near_cap = ctx.root.provider.context > 0 and ctx.root.last_context_tokens * 100 >= ctx.root.provider.context * 95;
            ctx.root.compactOrRecover(near_cap);
        }
        // opencode-style continuous autosave: persist after every turn so a
        // crash or quit never loses the thread — last.session.json, the same
        // file /resume reads. Best-effort; a write failure never breaks the loop.
        session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};

        // --worktree checkpoint: commit this turn's edits to the scratch branch
        // so the work is durable + rewindable across restarts. No-op when not in
        // a worktree or when --no-autocommit is set.
        jobs.worktreeAutoCommit(ctx.gpa, ctx.io, std.fmt.allocPrint(ctx.arena, "wip: {s}", .{title_mod.titleFromPrompt(base_msg)}) catch "wip: graff checkpoint");
    }
}
