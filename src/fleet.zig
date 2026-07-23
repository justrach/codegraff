//! The MAP-Elites agent-type / fleet subsystem (docs/hyperagents.md): the
//! AgentType niche registry (builtins + .harness/agents/*.md tiers), the
//! backgrounded elite pull from the fleet worker, /agents promote, and the
//! niche/override resolvers for subagent + workflow spawns. Split out of
//! main.zig (#123). Owns the session agent-type globals; back-imports main for
//! the Telemetry sink (fleet signals), trajectory archive, and the live g_fleet toggle.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const learn_store = @import("learn_store.zig");

const root = @import("main.zig");
const trace = @import("trace.zig");
const telemetry_mod = @import("telemetry.zig");
const learning_privacy = @import("learning_privacy.zig");
const Telemetry = telemetry_mod.Telemetry;
const http = @import("http.zig");

// ── Agent types (the MAP-Elites niches) ─────────────────────────────────────

/// A named, reusable subagent persona: the unit the MAP-Elites archive is
/// organized around (docs/hyperagents.md §MAP-Elites). Each niche keeps one
/// elite prompt; builtins ship compiled in, and `.harness/agents/<name>.md`
/// files (frontmatter: name/description/score, body: the system prompt)
/// override or extend them — that's where an evolution driver promotes
/// archive winners. Spawn one with subagent/workflow `agent: "<name>"`.
pub const AgentType = struct {
    name: []const u8,
    desc: []const u8,
    prompt: []const u8,
    score: ?f64 = null, // written by the evolution driver, shown in /agents
    builtin: bool = false,
    learned: bool = false,
};

/// Preloaded niches: deliberately orthogonal *behavioral* dimensions (what
/// MAP-Elites calls the feature space), not job titles — each elicits a
/// different failure mode to cover.
const builtin_agent_types = [_]AgentType{
    .{
        .name = "reviewer",
        .desc = "adversarial code reviewer — hunts defects, assumes guilt",
        .prompt = "You are an adversarial code reviewer. Read the code you are pointed at and hunt for genuine defects: logic errors, unhandled edge cases, races, leaks, security holes. Assume the code is guilty until proven correct. Report only findings you can defend with a concrete failure scenario, each with file:line and the exact sequence that breaks. No style nits. End with a verdict: the single most dangerous defect, or 'no defensible defects found'.",
        .builtin = true,
    },
    .{
        .name = "researcher",
        .desc = "evidence gatherer — reads widely, cites precisely, never edits",
        .prompt = "You are a research agent. Your job is to READ and REPORT, never to modify anything. Explore the files or sources you are pointed at, follow the references that matter, and produce a tight evidence-backed summary: every claim cites its file:line or source. Separate what you verified from what you infer. End with the 3 facts most load-bearing for the task and 1 open question.",
        .builtin = true,
    },
    .{
        .name = "implementer",
        .desc = "surgical patch writer — smallest correct change, verified",
        .prompt = "You are a surgical implementer. Make the smallest correct change that satisfies the task: read the surrounding code first, match its idiom exactly, touch nothing beyond the requirement. After editing, verify your change compiles/passes whatever check the project offers and report the command and its result. End with a diff-shaped summary of exactly what changed and why it is sufficient.",
        .builtin = true,
    },
    .{
        .name = "skeptic",
        .desc = "claim refuter — tries to prove the premise wrong",
        .prompt = "You are a skeptic. You receive a claim or finding; your only goal is to REFUTE it. Search for counterexamples, missing context, and alternative explanations. Default to 'refuted' unless the claim survives your strongest attack. Report the attack you ran, what you found, and a final verdict: refuted (with the counterexample) or survives (with what would have broken it).",
        .builtin = true,
    },
};

/// Resolved agent types for this session, in precedence order:
/// builtin < personal (~/.harness/agents) < private (./.harness/agents). A later
/// tier's <name>.md shadows the same niche from an earlier one. Set by main();
/// arena-owned strings.
pub var g_agent_types: []const AgentType = &builtin_agent_types;
pub var g_elites_future: ?Io.Future([]const AgentType) = null; // backgrounded pullElites; joined on the main thread before the first turn
pub var g_home: ?[]const u8 = null; // resolved HOME (set in main); used by /agents promote's personal tier

pub const agents_dir = ".harness/agents";

/// Build the session's agent types: the compiled builtins, then the personal
/// tier (~/.harness/agents — your champions, loaded in every project), then the
/// private tier (./.harness/agents — this project only). Each tier shadows the
/// previous by niche name, so a project persona beats a personal one beats a
/// builtin.
pub fn loadAgentTypes(io: Io, arena: Allocator, home: ?[]const u8) []const AgentType {
    var list: std.ArrayList(AgentType) = .empty;
    list.appendSlice(arena, &builtin_agent_types) catch return &builtin_agent_types;
    if (home) |h| {
        const personal = std.fmt.allocPrint(arena, "{s}/{s}", .{ h, agents_dir }) catch "";
        if (personal.len > 0) loadAgentDir(io, arena, &list, personal);
    }
    loadAgentDir(io, arena, &list, agents_dir);
    // A verified learning ref is the highest-precedence project policy. The
    // loader fails closed: incomplete/corrupt learning state contributes no
    // agent and can be diagnosed with `graff learn verify`.
    if (learn_store.loadActiveAgent(io, arena)) |learned| {
        const at: AgentType = .{
            .name = learned.name,
            .desc = learned.description,
            .prompt = learned.prompt,
            .learned = true,
        };
        var replaced = false;
        for (list.items) |*existing| {
            if (std.mem.eql(u8, existing.name, at.name)) {
                existing.* = at;
                replaced = true;
                break;
            }
        }
        if (!replaced) list.append(arena, at) catch {};
    }
    return list.items;
}

/// Merge `<dir>/*.md` personas into `list`: YAML-ish frontmatter
/// (name/description/score) + body as the prompt. A file shadows any existing
/// type (builtin or earlier tier) of the same name — the elite for a niche is
/// whatever the highest tier last promoted.
fn loadAgentDir(io: Io, arena: Allocator, list: *std.ArrayList(AgentType), dir_path: []const u8) void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch continue;
        var at: AgentType = .{
            .name = arena.dupe(u8, entry.name[0 .. entry.name.len - ".md".len]) catch continue,
            .desc = "",
            .prompt = std.mem.trim(u8, data, " \t\r\n"),
        };
        // Frontmatter: leading "---\n…\n---\n" with name:/description:/score:.
        if (std.mem.startsWith(u8, data, "---\n")) {
            if (std.mem.indexOfPos(u8, data, 4, "\n---")) |fm_end| {
                var lines = std.mem.tokenizeScalar(u8, data[4..fm_end], '\n');
                while (lines.next()) |ln| {
                    const sep = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
                    const key = std.mem.trim(u8, ln[0..sep], " \t");
                    const val = std.mem.trim(u8, ln[sep + 1 ..], " \t\"");
                    if (std.mem.eql(u8, key, "name") and val.len > 0) at.name = val;
                    if (std.mem.eql(u8, key, "description")) at.desc = val;
                    if (std.mem.eql(u8, key, "score")) at.score = std.fmt.parseFloat(f64, val) catch null;
                }
                const body_start = fm_end + "\n---".len;
                at.prompt = std.mem.trim(u8, data[@min(body_start + 1, data.len)..], " \t\r\n");
            }
        }
        if (at.prompt.len == 0) continue;
        // A file shadows an existing type (builtin or earlier tier) of the same name.
        var replaced = false;
        for (list.items) |*existing| {
            if (std.mem.eql(u8, existing.name, at.name)) {
                existing.* = at;
                replaced = true;
                break;
            }
        }
        if (!replaced) list.append(arena, at) catch continue;
    }
}

/// Local single-tenant promote — the "grow for me" loop. Mine
/// the run-scoped trajectory archive (prompt records → genome text, subagent records →
/// niche, score records → fitness), and for each MAP-Elites niche write the
/// highest-mean-scoring genome that has captured text into the chosen tier
/// (personal ~/.harness/agents or private ./.harness/agents) as <niche>.md. No
/// backend: your own scored runs become your built-in personas. Returns the
/// number of niches promoted.
pub fn promoteAgents(io: Io, gpa: Allocator, out: *Io.Writer, home: ?[]const u8, personal: bool) usize {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data = trace.readTrajectoryArchive(io, arena, 64 << 20);
    if (data.len == 0) {
        out.print("  {s}no {s} yet — run some scored agents first{s}\n", .{ style.dim, trace.trajectories_dir, style.reset }) catch {};
        return 0;
    }

    const Cell = struct { sha: []const u8, text: []const u8, niche: []const u8, sum: f64, n: u32 };
    var cells: std.ArrayList(Cell) = .empty;
    const cell = struct {
        fn at(a: Allocator, list: *std.ArrayList(Cell), sha: []const u8) *Cell {
            for (list.items) |*c| if (std.mem.eql(u8, c.sha, sha)) return c;
            list.append(a, .{ .sha = a.dupe(u8, sha) catch sha, .text = "", .niche = "", .sum = 0, .n = 0 }) catch {};
            return &list.items[list.items.len - 1];
        }
    }.at;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(Value, arena, t, .{ .allocate = .alloc_always }) catch continue;
        if (v != .object) continue;
        const o = v.object;
        const kind = strFieldObj(o, "kind") orelse continue;
        const sha = strFieldObj(o, "prompt_sha") orelse "";
        if (sha.len == 0) continue;
        if (std.mem.eql(u8, kind, "prompt")) {
            if (strFieldObj(o, "text")) |txt| cell(arena, &cells, sha).text = arena.dupe(u8, txt) catch "";
        } else if (std.mem.eql(u8, kind, "score")) {
            const sv = o.get("score") orelse continue;
            const val: f64 = switch (sv) {
                .float => sv.float,
                .integer => @floatFromInt(sv.integer),
                else => continue,
            };
            const c = cell(arena, &cells, sha);
            c.sum += val;
            c.n += 1;
        } else if (strFieldObj(o, "niche")) |nz| {
            if (nz.len > 0) cell(arena, &cells, sha).niche = arena.dupe(u8, nz) catch "";
        }
    }

    // Resolve + create the target tier dir (createDir is one level).
    const dir = if (personal) blk: {
        const h = home orelse {
            out.print("  {s}no HOME for the personal tier{s}\n", .{ style.yellow, style.reset }) catch {};
            return 0;
        };
        Io.Dir.cwd().createDir(io, std.fmt.allocPrint(arena, "{s}/.harness", .{h}) catch return 0, .default_dir) catch {};
        break :blk std.fmt.allocPrint(arena, "{s}/{s}", .{ h, agents_dir }) catch return 0;
    } else pblk: {
        Io.Dir.cwd().createDir(io, ".harness", .default_dir) catch {};
        break :pblk agents_dir;
    };
    Io.Dir.cwd().createDir(io, dir, .default_dir) catch {};

    // For each niche, write the genome with the best mean score (text required).
    var done: std.ArrayList([]const u8) = .empty;
    var promoted: usize = 0;
    for (cells.items) |*seed| {
        if (seed.niche.len == 0 or seed.text.len == 0 or seed.n == 0) continue;
        var already = false;
        for (done.items) |d| if (std.mem.eql(u8, d, seed.niche)) {
            already = true;
            break;
        };
        if (already) continue;
        var champ = seed;
        var champ_mean = seed.sum / @as(f64, @floatFromInt(seed.n));
        for (cells.items) |*other| {
            if (other.text.len == 0 or other.n == 0) continue;
            if (!std.mem.eql(u8, other.niche, seed.niche)) continue;
            const m = other.sum / @as(f64, @floatFromInt(other.n));
            if (m > champ_mean) {
                champ = other;
                champ_mean = m;
            }
        }
        const path = std.fmt.allocPrint(arena, "{s}/{s}.md", .{ dir, champ.niche }) catch continue;
        const content = std.fmt.allocPrint(arena, "---\nname: {s}\ndescription: promoted local champion (mean {d:.2} over {d} run(s), sha {s})\nscore: {d:.4}\n---\n{s}\n", .{ champ.niche, champ_mean, champ.n, champ.sha, champ_mean, champ.text }) catch continue;
        const f = Io.Dir.cwd().createFile(io, path, .{}) catch continue;
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(content) catch continue;
        fw.interface.flush() catch {};
        out.print("  {s}✓{s} {s}{s}{s} → {s} {s}(mean {d:.2}, n={d}){s}\n", .{ style.green, style.reset, style.accent, champ.niche, style.reset, path, style.dim, champ_mean, champ.n, style.reset }) catch {};
        done.append(arena, champ.niche) catch {};
        promoted += 1;
    }
    if (promoted == 0) out.print("  {s}nothing to promote — need scored, niche-tagged genomes (spawn personas via subagent agent:\"<niche>\", then score them){s}\n", .{ style.dim, style.reset }) catch {};
    return promoted;
}
/// Resolve an agent-type name (case-sensitive) to its prompt.
pub fn agentTypePrompt(name: []const u8) ?[]const u8 {
    for (g_agent_types) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.prompt;
    }
    return null;
}

fn applyRemoteElite(arena: Allocator, types: []AgentType, name: []const u8, prompt: []const u8) bool {
    for (types) |*agent_type| {
        if (!std.mem.eql(u8, agent_type.name, name)) continue;
        // A verified local learning ref is an activation authority; best-effort
        // remote fleet data is not. Preserve unrelated remote elite updates.
        if (agent_type.learned) return false;
        agent_type.prompt = arena.dupe(u8, prompt) catch return false;
        return true;
    }
    return false;
}

/// Distribute (docs/hyperagents.md §9.E): fetch this tier's live fleet champions
/// from <base>/v1/elites, emit a fleet:elite_pull signal, and override matching
/// niches with the champion prompt so the baked builtins defer to the fleet
/// winner. Best-effort and bounded (3s) — any failure, or no champions yet,
/// returns `types` unchanged. `endpoint` is the OTLP base (…/v1/logs); the elites
/// live beside it at /v1/elites.
pub fn pullElites(io: Io, arena: Allocator, client: *std.http.Client, telem: ?*Telemetry, endpoint: []const u8, provider_class: []const u8, eval_set_hash: []const u8, types: []const AgentType) []const AgentType {
    if (endpoint.len == 0 or !root.g_fleet or !learning_privacy.allowsAggregate()) return types;
    http.waitForClientReady(io);
    var base = std.mem.trimEnd(u8, endpoint, "/");
    if (std.mem.endsWith(u8, base, "/v1/logs")) base = base[0 .. base.len - "/v1/logs".len];
    // No eval suite → omit eval_set_hash entirely (NOT empty): the worker reads an
    // absent hash as "give me the global-best champion" but a present-but-empty one
    // as cell "" (always empty), so sending "&eval_set_hash=" makes plain interactive
    // sessions pull nothing. Eval-driven sessions keep their cell-specific lookup.
    const url = if (eval_set_hash.len == 0)
        std.fmt.allocPrint(arena, "{s}/v1/elites?provider_class={s}", .{ base, provider_class }) catch return types
    else
        std.fmt.allocPrint(arena, "{s}/v1/elites?provider_class={s}&eval_set_hash={s}", .{ base, provider_class, eval_set_hash }) catch return types;
    var aw: Io.Writer.Allocating = .init(arena);
    var ok = false;
    {
        const Done = union(enum) { got: void, deadline: void };
        var dbuf: [2]Done = undefined;
        var sel: Io.Select(Done) = .init(io, &dbuf);
        sel.concurrent(.got, eliteGetTask, .{ client, url, &aw, &ok }) catch return types;
        sel.concurrent(.deadline, httpDeadline, .{io}) catch {
            _ = sel.await() catch {};
            sel.cancelDiscard();
            return types;
        };
        _ = sel.await() catch {
            sel.cancelDiscard();
            return types;
        };
        sel.cancelDiscard();
    }
    if (!ok) return types;
    const v = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch return types;
    // Worker returns {ok, provider_class, source, elites:[...]}; accept that (or a
    // bare array) and treat anything else as "no champions yet".
    var arr: []const Value = &[_]Value{};
    if (v == .array) {
        arr = v.array.items;
    } else if (v == .object) {
        if (v.object.get("elites")) |e| if (e == .array) {
            arr = e.array.items;
        };
    }
    var out: std.ArrayList(AgentType) = .empty;
    out.appendSlice(arena, types) catch return types;
    var n: i64 = 0;
    for (arr) |el| {
        if (el != .object) continue;
        n += 1;
        const nm = if (el.object.get("niche")) |x| (if (x == .string) x.string else "") else "";
        const pt = if (el.object.get("prompt_text")) |x| (if (x == .string) x.string else "") else "";
        if (nm.len == 0 or pt.len == 0) continue;
        _ = applyRemoteElite(arena, out.items, nm, pt);
    }
    if (telem) |tl| tl.fleetEvent("elite_pull", "", "", "", provider_class, eval_set_hash, n, "");
    return out.items;
}

/// Join the backgrounded fleet pull (g_elites_future) and publish its champions.
/// Called on the main thread at the top of the root's runTurn: by then the user
/// has spent time typing, so the ~0.3s fetch has overlapped and this is ~free.
/// The write to g_agent_types stays on the main thread, so there is no torn read.
pub fn joinElites(io: Io) void {
    if (g_elites_future) |*f| {
        g_agent_types = f.await(io);
        g_elites_future = null;
    }
}

/// Select-arm wrapper for pullElites: GET the elites URL into `aw`, set `ok` on 200.
fn eliteGetTask(client: *std.http.Client, url: []const u8, aw: *Io.Writer.Allocating, ok: *bool) void {
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = "simple-harness" } },
    }) catch return;
    ok.* = @intFromEnum(res.status) == 200;
}

/// Select-arm deadline: bounds a best-effort HTTP GET (mirrors flushDeadline).
fn httpDeadline(io: Io) void {
    io.sleep(.fromSeconds(3), .awake) catch {};
}

/// Effective system-prompt override for a subagent/workflow-task input:
/// an explicit system_prompt wins, else a named agent type's prompt, else
/// null (the lean default). An unknown agent name falls through to the
/// default rather than failing the spawn.
pub fn resolveOverride(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("system_prompt")) |v| {
        if (v == .string and v.string.len > 0) return v.string;
    }
    if (obj.get("agent")) |v| {
        if (v == .string and v.string.len > 0) return agentTypePrompt(v.string);
    }
    return null;
}

/// The private prompt content, if this spawn would use an inline, personal,
/// project, or locally learned persona. Builtin/remote fleet personas are
/// already public artifacts and do not need a new publication decision.
pub fn privateOverride(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("system_prompt")) |v| {
        if (v == .string and v.string.len > 0) return v.string;
    }
    if (obj.get("agent")) |v| if (v == .string) {
        for (g_agent_types) |agent_type| {
            if (std.mem.eql(u8, agent_type.name, v.string) and !agent_type.builtin) return agent_type.prompt;
        }
    };
    return null;
}

pub fn promptIsPublic(prompt: []const u8) bool {
    for (g_agent_types) |agent_type| {
        if (agent_type.builtin and std.mem.eql(u8, agent_type.prompt, prompt)) return true;
    }
    return false;
}

/// The MAP-Elites niche name for a subagent/workflow input: the named agent
/// type (agent: "<name>"), or "" for an inline system_prompt variant.
pub fn resolveNiche(obj: std.json.ObjectMap) []const u8 {
    if (obj.get("agent")) |v| if (v == .string) return v.string;
    return "";
}
test "resolveNiche: agent name is the fleet cell, inline variant is uncelled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const obj = struct {
        fn p(al: Allocator, s: []const u8) std.json.ObjectMap {
            return (std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable).object;
        }
    }.p;

    // A named agent type is the MAP-Elites niche the variant submits under.
    try std.testing.expectEqualStrings("reviewer", resolveNiche(obj(a, "{\"agent\":\"reviewer\"}")));
    // An inline system_prompt variant has no named cell — execWorkflow then falls
    // back to the phase title so it still lands somewhere non-empty.
    try std.testing.expectEqualStrings("", resolveNiche(obj(a, "{\"system_prompt\":\"be terse\"}")));
    // A plain task is uncelled too.
    try std.testing.expectEqualStrings("", resolveNiche(obj(a, "{\"description\":\"x\",\"prompt\":\"y\"}")));
}

test "privateOverride distinguishes authored content from builtin personas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = g_agent_types;
    defer g_agent_types = saved;
    const types = [_]AgentType{
        .{ .name = "public", .desc = "public", .prompt = "public prompt", .builtin = true },
        .{ .name = "private", .desc = "private", .prompt = "private prompt" },
    };
    g_agent_types = &types;
    const public_obj = (try std.json.parseFromSliceLeaky(Value, arena, "{\"agent\":\"public\"}", .{})).object;
    const private_obj = (try std.json.parseFromSliceLeaky(Value, arena, "{\"agent\":\"private\"}", .{})).object;
    const inline_obj = (try std.json.parseFromSliceLeaky(Value, arena, "{\"system_prompt\":\"inline\"}", .{})).object;
    try std.testing.expect(privateOverride(public_obj) == null);
    try std.testing.expectEqualStrings("private prompt", privateOverride(private_obj).?);
    try std.testing.expectEqualStrings("inline", privateOverride(inline_obj).?);
    try std.testing.expect(promptIsPublic("public prompt"));
    try std.testing.expect(!promptIsPublic("private prompt"));
}

test "remote elites cannot replace a verified learned policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var types = [_]AgentType{
        .{ .name = "learned", .desc = "local", .prompt = "verified-local", .learned = true },
        .{ .name = "reviewer", .desc = "remote-eligible", .prompt = "old" },
    };

    try std.testing.expect(!applyRemoteElite(arena, &types, "learned", "untrusted-remote"));
    try std.testing.expectEqualStrings("verified-local", types[0].prompt);
    try std.testing.expect(applyRemoteElite(arena, &types, "reviewer", "new-remote"));
    try std.testing.expectEqualStrings("new-remote", types[1].prompt);
}
