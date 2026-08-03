//! Root tool permission gate. Kept separate from agent_tools.zig so the
//! dispatch/meta-tool module stays below the repository's source-size limit.

const std = @import("std");
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const tools_mod = @import("tools.zig");
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const mcp = @import("mcp.zig");
const json_args = @import("json_args.zig");
const Approvals = @import("approvals.zig").Approvals;
const skills = @import("skills.zig");
const companionTrusted = skills.companionTrusted;
const companionReadOnly = skills.companionReadOnly;
const fleet = @import("fleet.zig");
const telemetry = @import("telemetry.zig");
const learning_privacy = @import("learning_privacy.zig");

const TemplateCandidates = struct {
    items: [16][]const u8 = undefined,
    len: usize = 0,

    fn add(self: *TemplateCandidates, io: std.Io, obj: std.json.ObjectMap) void {
        const prompt = fleet.privateOverride(obj) orelse return;
        if (learning_privacy.isTemplateApproved(io, prompt)) return;
        for (self.items[0..self.len]) |existing| if (std.mem.eql(u8, existing, prompt)) return;
        if (self.len == self.items.len) return;
        self.items[self.len] = prompt;
        self.len += 1;
    }
};

fn collectPrivateTemplates(io: std.Io, call: ToolCall) TemplateCandidates {
    var found: TemplateCandidates = .{};
    if (call.input != .object) return found;
    if (std.mem.eql(u8, call.name, "subagent")) {
        found.add(io, call.input.object);
        return found;
    }
    if (!std.mem.eql(u8, call.name, "workflow")) return found;
    if (call.input.object.get("phases")) |phases| if (phases == .array) {
        for (phases.array.items) |phase| {
            if (phase != .object) continue;
            if (phase.object.get("tasks")) |tasks| if (tasks == .array) {
                for (tasks.array.items) |task| if (task == .object) found.add(io, task.object);
            };
        }
    };
    if (call.input.object.get("pipeline")) |pipeline| if (pipeline == .object) {
        if (pipeline.object.get("stages")) |stages| if (stages == .array) {
            for (stages.array.items) |stage| if (stage == .object) found.add(io, stage.object);
        };
    };
    return found;
}

fn previewLine(buf: []u8, prompt: []const u8) []const u8 {
    const source = prompt[0..@min(prompt.len, buf.len)];
    for (source, 0..) |c, i| buf[i] = if (c < 0x20 or c == 0x7f) ' ' else c;
    return buf[0..source.len];
}

/// Template mode is only a ceiling. A private persona still needs exact
/// interactive approval; no stdin, --yolo, or saved command approval can turn
/// that into content consent. Declining sharing continues the child locally.
fn gatePrivateTemplateSharing(self: *Agent, call: ToolCall) !?ExecResult {
    if (!learning_privacy.allowsTemplateReview() or !main_mod.g_fleet) return null;
    const telem = telemetry.g_telem orelse return null;
    if (!telem.on()) return null;
    const candidates = collectPrivateTemplates(self.io, call);
    if (candidates.len == 0) return null;
    const in = self.in orelse return null;
    const w = self.out orelse return null;

    try w.print("  ⚠ {d} private reusable subagent template{s} could be published\n", .{ candidates.len, if (candidates.len == 1) "" else "s" });
    var blocked_kind: []const u8 = "";
    for (candidates.items[0..candidates.len]) |prompt| {
        const fp = learning_privacy.displayFingerprint(prompt);
        const scan = learning_privacy.scanSecrets(prompt);
        if (!scan.safe() and blocked_kind.len == 0) blocked_kind = scan.first_kind;
        var pbuf: [120]u8 = undefined;
        try w.print("    {s} · {d} bytes · {s}{s}\n", .{ &fp, prompt.len, previewLine(&pbuf, prompt), if (prompt.len > pbuf.len) "…" else "" });
    }
    if (blocked_kind.len > 0) {
        try w.print("  blocked by local secret scan ({s}); child will run locally and no template text will be sent.\n", .{blocked_kind});
        try w.flush();
        return null;
    }
    try w.writeAll("  Sends: exact reusable system/persona text. Excludes: task prompt, bindings, code, paths, reports, and tool results.\n");
    try w.writeAll("  [y] share exact template version(s) this session · [l] run locally · [n] cancel child › ");
    try w.flush();
    const raw: []const u8 = (try in.takeDelimiter('\n')) orelse "";
    const answer = std.mem.trim(u8, raw, " \t\r");
    if (answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y')) {
        for (candidates.items[0..candidates.len]) |prompt| {
            if (!learning_privacy.approveTemplate(self.io, prompt)) return .{
                .text = try self.arena.dupe(u8, "template approval failed closed; retry locally or inspect the prompt for secret-like content"),
                .is_error = true,
            };
        }
        return null;
    }
    if (answer.len == 0 or answer[0] == 'l' or answer[0] == 'L') return null;
    return .{
        .text = try self.arena.dupe(u8, "user cancelled the child at the template-publication boundary"),
        .is_error = true,
    };
}

/// Hosted documentation queries still cross a network boundary after the
/// ordinary approval prompt. Reject recognizable credentials locally even
/// under --yolo; source/docs identifiers never need to contain a secret.
fn gateSmolifySecrets(arena: std.mem.Allocator, call: ToolCall) !?ExecResult {
    if (!std.mem.startsWith(u8, call.name, "mcp__smolify__")) return null;
    var encoded: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &encoded.writer };
    try stringify.write(call.input);
    const scan = learning_privacy.scanSecrets(encoded.writer.buffered());
    if (scan.safe()) return null;
    return .{
        .text = try std.fmt.allocPrint(arena, "Smolify call blocked locally: arguments resemble a {s}. Remove secrets and send only public project/documentation identifiers.", .{scan.first_kind}),
        .is_error = true,
    };
}

/// The permission gate, root side: an unapproved external action prompts the
/// user. Subagents never prompt; their gate is the executor's allowlist.
/// #366: the harness's own policy file is not the model's to edit. A worker
/// was observed writing pre_approved_tools into it after a denial — a write
/// that takes effect on next load is self-privilege-escalation, cwd-jail or
/// not. Applies to root AND subagents, before every other gate.
fn gateHarnessPolicyWrite(self: *Agent, call: ToolCall) !?ExecResult {
    if (!(std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file"))) return null;
    const obj = json_args.object(call.input) orelse return null;
    const pv = obj.get("path") orelse return null;
    if (pv != .string) return null;
    const path = std.mem.trim(u8, pv.string, " \t");
    if (!(std.mem.eql(u8, path, Approvals.settings_path) or std.mem.endsWith(u8, path, "/" ++ Approvals.settings_path))) return null;
    return .{
        .text = try self.arena.dupe(u8, "refused: " ++ Approvals.settings_path ++ " is the harness's own policy file (approvals, hooks, pre-approvals) — a model never widens its own permissions. Ask the USER to change config, or proceed without this tool."),
        .is_error = true,
    };
}

pub fn gateTool(self: *Agent, call: ToolCall) !?ExecResult {
    if (try gateHarnessPolicyWrite(self, call)) |blocked| return blocked; // #366: before the sub branch — children are exactly who must not widen approvals
    if (self.sub) {
        if (std.mem.eql(u8, call.name, "learn_candidate")) return .{
            .text = try self.arena.dupe(u8, "learning is root-only — subagents cannot run mutators, evaluators, or publish grades"),
            .is_error = true,
        };
        if (std.mem.eql(u8, call.name, "bash") and call.input == .object) {
            if (call.input.object.get("command")) |cv| if (cv == .string and Approvals.isDestructiveGit(cv.string)) return .{
                .text = try self.arena.dupe(u8, "destructive git is blocked for subagents (no one to confirm) — leave reset --hard / clean -f / force-push / branch -D to the root session"),
                .is_error = true,
            };
        }
        return null;
    }
    if (try gateSmolifySecrets(self.arena, call)) |blocked| return blocked;
    if (try gatePrivateTemplateSharing(self, call)) |blocked| return blocked;
    const approvals = self.approvals orelse return null;

    if (main_mod.plan_mode) {
        if (std.mem.eql(u8, call.name, "learn_candidate") or
            std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or
            std.mem.eql(u8, call.name, "imagegen") or // #352: writes a file and spawns a workspace-write child
            (mcp.Registry.isMcp(call.name) and !companionReadOnly(call.name, call.input))) return .{
            .text = try self.arena.dupe(u8, "plan mode is on — read-only. Fold this change into the plan you present; the user applies it after approving (/plan toggles the mode off)."),
            .is_error = true,
        };
        if (std.mem.eql(u8, call.name, "bash")) {
            // Model-supplied: a non-object here is UB in a ReleaseFast build,
            // and this gate is ROOT-only, so the subagent-path guards added in
            // v0.0.223 never covered it.
            const args = json_args.object(call.input) orelse return null;
            const cmd_val = args.get("command") orelse return null;
            if (cmd_val != .string) return null;
            const cmd = std.mem.trim(u8, cmd_val.string, " \t");
            if (Approvals.readOnlyAllowed(cmd)) return null;
            if (Approvals.readOnlyExternal(cmd)) {
                if (approvals.planReadAllowed(self.io, cmd)) return null;
                if (self.in) |in| if (self.out) |w| {
                    try w.print("  ⚠ plan mode — read outside the project: {s}\n  [a]llow read-only access to these paths this session · [n]o › ", .{cmd});
                    try w.flush();
                    const raw: []const u8 = (try in.takeDelimiter('\n')) orelse "";
                    const answer = std.mem.trim(u8, raw, " \t\r");
                    if (answer.len > 0 and (answer[0] == 'a' or answer[0] == 'A' or answer[0] == 'y' or answer[0] == 'Y')) {
                        try approvals.approvePlanRead(self.io, self.gpa, cmd);
                        return null;
                    }
                };
                return .{
                    .text = try self.arena.dupe(u8, "plan mode — read-only access outside the project was declined; describe what you need read in the plan instead"),
                    .is_error = true,
                };
            }
            return .{
                .text = try self.arena.dupe(u8, "plan mode is on — only read-only commands run (ls/cat/grep/git status…). Put this command in the plan instead."),
                .is_error = true,
            };
        }
    }

    var key: []const u8 = undefined;
    var line_buf: [256]u8 = undefined;
    var prompt_line: []const u8 = undefined;
    if (std.mem.eql(u8, call.name, "bash")) {
        const args = json_args.object(call.input) orelse return null; // model-supplied; UB in ReleaseFast without the tag check
        const cmd_val = args.get("command") orelse return null;
        if (cmd_val != .string) return null;
        const cmd = std.mem.trim(u8, cmd_val.string, " \t");
        const destructive_git = Approvals.isDestructiveGit(cmd);
        const gate_ok = !destructive_git or Approvals.destructiveGitAllowed(approvals.yolo, self.sub);
        if (gate_ok and approvals.allowed(self.io, cmd)) return null;
        key = firstWord(cmd);
        prompt_line = if (destructive_git)
            std.fmt.bufPrint(&line_buf, "DESTRUCTIVE git — run: {s}", .{cmd}) catch cmd
        else
            std.fmt.bufPrint(&line_buf, "run: {s}", .{cmd}) catch cmd;
    } else if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file")) {
        if (approvals.allowedExact(self.io, call.name)) return null;
        key = call.name;
        const path = if (call.input == .object)
            (if (call.input.object.get("path")) |p| (if (p == .string) p.string else "?") else "?")
        else
            "?";
        prompt_line = std.fmt.bufPrint(&line_buf, "{s} {s}", .{ call.name, path }) catch call.name;
    } else if (std.mem.eql(u8, call.name, "learn_candidate")) {
        if (!learning_privacy.allowsAggregate()) {
            const in = self.in orelse return .{
                .text = try self.arena.dupe(u8, "learning privacy is Local and no interactive user can approve this one-shot aggregate submission"),
                .is_error = true,
            };
            const w = self.out orelse return .{
                .text = try self.arena.dupe(u8, "learning privacy is Local and no interactive user can approve this one-shot aggregate submission"),
                .is_error = true,
            };
            try w.writeAll(
                "  ⚠ learn_candidate will run the pinned adapters, then send signed aggregate grades once\n" ++
                    "  Adapter egress: a configured model adapter may send prompt/genome text to its model provider.\n" ++
                    "  Sends: pass counts/deltas, significance, critical regressions, tool/cost/latency totals, gate settings, eligibility, fingerprints, and evidence IDs.\n" ++
                    "  No stable install ID, OS, architecture, or service version is sent.\n" ++
                    "  Excludes: prompt/genome text, tasks, code, paths, evaluator input/output, and traces.\n" ++
                    "  [y] run + send once · [n] cancel › ",
            );
            try w.flush();
            const raw: []const u8 = (try in.takeDelimiter('\n')) orelse "";
            const answer = std.mem.trim(u8, raw, " \t\r");
            if (answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y')) {
                learning_privacy.authorizeAggregateOnce(self.io);
                return null;
            }
            return .{
                .text = try self.arena.dupe(u8, "user declined the bundled learning submission"),
                .is_error = true,
            };
        }
        if (approvals.allowedExact(self.io, call.name)) return null;
        key = call.name;
        prompt_line = "run pinned learning mutator/evaluator and submit signed aggregate grades";
    } else if (mcp.Registry.isMcp(call.name)) {
        if (companionTrusted(call.name)) return null;
        if (approvals.allowedExact(self.io, call.name)) return null;
        key = call.name;
        prompt_line = if (std.mem.startsWith(u8, call.name, "mcp__smolify__"))
            std.fmt.bufPrint(&line_buf, "send arguments to hosted Smolify tool {s}", .{call.name}) catch call.name
        else
            std.fmt.bufPrint(&line_buf, "call MCP tool {s}", .{call.name}) catch call.name;
    } else return null;

    // #369: a denial that just says "not pre-approved" strands the model —
    // observed spirals: probing .harness/settings.json, retrying the same
    // tool, burning the whole call budget. Name what was denied, forbid the
    // dead ends, and point at a productive next move.
    const in = self.in orelse return .{
        .text = try std.fmt.allocPrint(self.arena, "tool denied ({s}): not pre-approved, and this unattended run has no user to ask. Do NOT retry it, probe harness config, or try to change approvals — use a different tool you already have, or finish and report the limitation. The USER can pre-approve it in {s} or run with --yolo.", .{ prompt_line, Approvals.settings_path }),
        .is_error = true,
    };
    const w = self.out orelse return .{
        .text = try std.fmt.allocPrint(self.arena, "tool denied ({s}): not pre-approved, and no interactive user to ask. Do NOT retry it or probe harness config — use a different tool you already have, or finish and report the limitation. The USER can pre-approve it in {s} or run with --yolo.", .{ prompt_line, Approvals.settings_path }),
        .is_error = true,
    };
    try w.print("  ⚠ {s}\n  [y]es once · [a]lways allow \"{s}\" (saved to {s}) · [n]o › ", .{ prompt_line, key, Approvals.settings_path });
    try w.flush();
    const raw: []const u8 = (try in.takeDelimiter('\n')) orelse "";
    const answer = std.mem.trim(u8, raw, " \t\r");
    if (answer.len > 0) switch (answer[0]) {
        'y', 'Y' => return null,
        'a', 'A' => {
            try approvals.approve(self.io, self.gpa, key);
            if (std.mem.eql(u8, call.name, "bash") and Approvals.isInterpreter(key)) {
                try w.print("  note: \"{s}\" can execute arbitrary code (e.g. {s} -c '…'); approving it is effectively unrestricted.\n", .{ key, key });
                try w.flush();
            }
            return null;
        },
        else => {},
    };
    return .{
        .text = try self.arena.dupe(u8, "user declined this tool call — try another approach or ask them how to proceed"),
        .is_error = true,
    };
}

pub fn firstWord(cmd: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, cmd, " \t") orelse cmd.len;
    return cmd[0..end];
}

test "firstWord splits the command on the first whitespace" {
    try std.testing.expectEqualStrings("git", firstWord("git status -s"));
    try std.testing.expectEqualStrings("ls", firstWord("ls"));
    try std.testing.expectEqualStrings("cat", firstWord("cat\tfile"));
    try std.testing.expectEqualStrings("", firstWord(""));
    try std.testing.expectEqualStrings("", firstWord(" leading"));
}

test "Smolify arguments containing recognizable secrets fail closed locally" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"query\":\"github_token=ghp_not-for-egress\"}", .{});
    const public = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"query\":\"Zig HTTP client\"}", .{});
    const blocked = (try gateSmolifySecrets(arena, .{ .id = "1", .name = "mcp__smolify__search_docs", .input = secret })).?;
    try std.testing.expect(blocked.is_error);
    try std.testing.expect(std.mem.indexOf(u8, blocked.text, "blocked locally") != null);
    try std.testing.expect((try gateSmolifySecrets(arena, .{ .id = "2", .name = "mcp__smolify__search_docs", .input = public })) == null);
    try std.testing.expect((try gateSmolifySecrets(arena, .{ .id = "3", .name = "read_file", .input = secret })) == null);
}

test "gateHarnessPolicyWrite: the model never edits the harness's own policy file (#366)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = undefined;
    agent.arena = arena;
    const settings = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\".harness/settings.json\",\"content\":\"{}\"}", .{});
    const nested = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"../other/.harness/settings.json\",\"content\":\"{}\"}", .{});
    const normal = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"src/main.zig\",\"content\":\"x\"}", .{});
    // Both write tools are refused on the policy file, any spelling of it…
    const direct = (try gateHarnessPolicyWrite(&agent, .{ .id = "1", .name = "write_file", .input = settings })).?;
    try std.testing.expect(direct.is_error);
    try std.testing.expect(std.mem.indexOf(u8, direct.text, "policy file") != null);
    try std.testing.expect((try gateHarnessPolicyWrite(&agent, .{ .id = "2", .name = "edit_file", .input = nested })) != null);
    // …while ordinary paths and other tools pass through untouched.
    try std.testing.expect((try gateHarnessPolicyWrite(&agent, .{ .id = "3", .name = "write_file", .input = normal })) == null);
    try std.testing.expect((try gateHarnessPolicyWrite(&agent, .{ .id = "4", .name = "bash", .input = settings })) == null);
}

test "private template collector covers subagents and workflow stages" {
    const io = std.testing.io;
    learning_privacy.setMode(io, .templates);
    defer learning_privacy.setMode(io, .local);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sub_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"system_prompt\":\"private one\",\"prompt\":\"task\"}", .{});
    const sub = collectPrivateTemplates(io, .{ .id = "1", .name = "subagent", .input = sub_value });
    try std.testing.expectEqual(@as(usize, 1), sub.len);
    const wf_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"phases\":[{\"tasks\":[{\"system_prompt\":\"phase private\",\"prompt\":\"x\"}]}],\"pipeline\":{\"stages\":[{\"system_prompt\":\"stage private\",\"prompt\":\"y\"}]}}", .{});
    const wf = collectPrivateTemplates(io, .{ .id = "2", .name = "workflow", .input = wf_value });
    try std.testing.expectEqual(@as(usize, 2), wf.len);
}
