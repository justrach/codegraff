//! Scope, migration, and fail-closed regressions for issue #789.

const std = @import("std");
const Io = std.Io;

const Agent = @import("agent.zig").Agent;
const playbook = @import("playbook.zig");
const glue = @import("playbook_glue.zig");

fn inScratch(comptime body: fn (Io, std.mem.Allocator) anyerror!void) !void {
    if (@import("builtin").os.tag == .windows) return;
    const saved_inject = playbook.g_root_inject;
    defer playbook.g_root_inject = saved_inject;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try body(io, arena_state.allocator());
}

fn seedRaw(io: Io, raw: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, playbook.dir);
    const f = try Io.Dir.cwd().createFile(io, playbook.path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, raw, 0);
}

fn rootStub(arena: std.mem.Allocator, out: *Io.Writer) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "test-model", .context = 100_000 },
        .messages = .init(arena),
        .sub = false,
        .label = "issue-789-test",
        .out = out,
        .session_name = "",
    };
}

fn call(arena: std.mem.Allocator, text: []const u8, scope: ?[]const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "text", .{ .string = text });
    if (scope) |s| try object.put(arena, "scope", .{ .string = s });
    return .{ .object = object };
}

test "#789 note_constraint writes only an exact explicit project rule" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.named_work_task = "For this task, do not add dots. Never delete generated files unless regeneration was explicitly requested. Never add telemetry in this project.";

            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "For this task, do not add dots.", null)).is_error);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "For this task, do not add dots.", "task")).is_error);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "do not add dots.", "project")).is_error);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "Never delete generated files", "project")).is_error);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "Never add any tracking anywhere.", "project")).is_error);
            try std.testing.expectEqual(@as(usize, 0), playbook.load(io, arena).len);

            const result = glue.noteConstraint(&root, try call(arena, "Never add telemetry in this project.", "project"));
            try std.testing.expect(!result.is_error);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "recorded project constraint") != null);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "scope=project") != null);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "origin=current user message") != null);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "/never rm <unique text>") != null);
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 1), items.len);
            try std.testing.expectEqual(playbook.Scope.project, items[0].scope);
            try std.testing.expectEqualStrings("Never add telemetry in this project.", items[0].text);
        }
    }.body);
}

test "#789 exact legacy and learned matches are promoted to user project policy" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            const legacy_text = "Keep generated snapshots stable.";
            var idbuf: [11]u8 = undefined;
            const legacy_id = try arena.dupe(u8, playbook.idFor(&idbuf, legacy_text));
            const raw = try std.fmt.allocPrint(arena, "{{\"v\":1,\"op\":\"add\",\"id\":\"{s}\",\"text\":\"{s}\",\"source\":\"user\",\"provenance\":\"user:1\",\"created_at\":1}}\n", .{ legacy_id, legacy_text });
            try seedRaw(io, raw);

            const learned_text = "Prefer deterministic fixtures.";
            const learned = playbook.add(io, arena, learned_text, .learned, "run:1");
            try std.testing.expect(learned.ok);

            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.named_work_task = legacy_text;
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, legacy_text, "project")).is_error);
            const promoted_legacy = playbook.find(playbook.load(io, arena), legacy_id).?;
            try std.testing.expectEqual(playbook.Source.user, promoted_legacy.source);
            try std.testing.expectEqual(playbook.Scope.project, promoted_legacy.scope);
            try std.testing.expectEqualStrings(legacy_text, promoted_legacy.text);

            root.named_work_task = learned_text;
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, learned_text, "project")).is_error);
            const promoted_learned = playbook.find(playbook.load(io, arena), learned.id).?;
            try std.testing.expectEqual(playbook.Source.user, promoted_learned.source);
            try std.testing.expectEqual(playbook.Scope.project, promoted_learned.scope);
            try std.testing.expectEqualStrings(learned_text, promoted_learned.text);
        }
    }.body);
}

test "#789 normalized id collisions never claim different exact text was recorded" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.named_work_task = "Use C in project builds.";
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, root.named_work_task, "project")).is_error);

            root.named_work_task = "Use C++ in project builds.";
            const collision = glue.noteConstraint(&root, try call(arena, root.named_work_task, "project"));
            try std.testing.expect(collision.is_error);
            try std.testing.expect(std.mem.indexOf(u8, collision.text, "collision") != null);
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 1), items.len);
            try std.testing.expectEqualStrings("Use C in project builds.", items[0].text);
        }
    }.body);
}

test "#789 overlong automatic capture is rejected instead of truncating qualifiers" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            const text = try arena.alloc(u8, playbook.max_text + 1);
            @memset(text, 'x');
            root.named_work_task = text;
            const result = glue.noteConstraint(&root, try call(arena, text, "project"));
            try std.testing.expect(result.is_error);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "240-byte") != null);
            try std.testing.expectEqual(@as(usize, 0), playbook.load(io, arena).len);
        }
    }.body);
}

test "#789 storage preserves meaningful leading flags and trailing globs verbatim" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            try std.testing.expect(playbook.add(io, arena, "  --no-telemetry must be passed in this project.  ", .user, "user:1").ok);
            try std.testing.expect(playbook.add(io, arena, "Never modify generated-*", .user, "user:2").ok);
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 2), items.len);
            try std.testing.expectEqualStrings("--no-telemetry must be passed in this project.", items[0].text);
            try std.testing.expectEqualStrings("Never modify generated-*", items[1].text);
        }
    }.body);
}

test "#789 v1 user records are legacy unscoped and visibly require review" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = playbook.parse(arena,
        \\{"v":1,"op":"add","id":"pb-legacy01","text":"do not add dots right now","source":"user","provenance":"user:1","created_at":1}
    );
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(playbook.Scope.legacy_unscoped, items[0].scope);
    const block = playbook.blockFrom(arena, items);
    try std.testing.expect(std.mem.indexOf(u8, block, playbook.legacy_header) != null);
    try std.testing.expect(std.mem.indexOf(u8, block, playbook.user_header) == null);
    const state = try playbook.recordedState(arena, items);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"scope\":\"legacy_unscoped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, playbook.authority_note, "require user review with /never") != null);
}

test "#1342 a standing rule typed into an ask_user answer can be recorded verbatim" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            const answers = @import("ask_user_answers.zig");
            answers.reset();
            defer answers.reset();
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.named_work_task = "Set up the release branch.";
            const answer = "Always keep releases on the beta channel until I say otherwise. For this one, skip the changelog.";
            answers.record(answers.turnKey(glue.currentUserText(&root)), answer);

            // A fragment that drops the qualifier is still refused.
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "keep releases on the beta channel", "project")).is_error);
            const result = glue.noteConstraint(&root, try call(arena, "Always keep releases on the beta channel until I say otherwise.", "project"));
            try std.testing.expect(!result.is_error);
            try std.testing.expect(std.mem.indexOf(u8, result.text, "origin=user's ask_user answer") != null);
            try std.testing.expectEqual(@as(usize, 1), playbook.load(io, arena).len);

            // An answer from an earlier turn is not a source for this one.
            root.named_work_task = "Now cut the tag.";
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "For this one, skip the changelog.", "project")).is_error);
        }
    }.body);
}

test "#1821 write and cap failures never fabricate an existing id; real collisions still name it" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);

            // Force createFile to fail by placing a directory at `.graff/playbook.jsonl`.
            try Io.Dir.cwd().createDirPath(io, playbook.path);
            const rule = "Never add telemetry in this project.";
            root.named_work_task = rule;
            const add_err = playbook.add(io, arena, rule, .user, "user:1");
            try std.testing.expect(!add_err.ok);
            try std.testing.expectEqualStrings("", add_err.id);
            try std.testing.expect(std.mem.indexOf(u8, add_err.reason, "could not write .graff/playbook.jsonl:") != null);

            const tool_err = glue.noteConstraint(&root, try call(arena, rule, "project"));
            try std.testing.expect(tool_err.is_error);
            try std.testing.expect(std.mem.indexOf(u8, tool_err.text, "could not write .graff/playbook.jsonl:") != null);
            try std.testing.expect(std.mem.indexOf(u8, tool_err.text, "existing id") == null);
            try std.testing.expect(std.mem.indexOf(u8, tool_err.text, "pb-") == null);

            // Replace the directory with an empty 0-byte file (the Windows failure artifact)
            // and verify appending succeeds cleanly across multiple writes.
            try Io.Dir.cwd().deleteTree(io, playbook.path);
            try seedRaw(io, "");
            const ok1 = glue.noteConstraint(&root, try call(arena, rule, "project"));
            try std.testing.expect(!ok1.is_error);
            root.named_work_task = "Use C in project builds.";
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, root.named_work_task, "project")).is_error);
            try std.testing.expectEqual(@as(usize, 2), playbook.load(io, arena).len);

            // A genuine normalized-id collision still reports the existing id.
            root.named_work_task = "Use C++ in project builds.";
            const collision = glue.noteConstraint(&root, try call(arena, root.named_work_task, "project"));
            try std.testing.expect(collision.is_error);
            try std.testing.expect(std.mem.indexOf(u8, collision.text, " — existing id pb-") != null);

            // Learned cap refusal also leaves `id` empty because the item is not in the ledger.
            for (0..playbook.max_learned) |i| {
                const text = try std.fmt.allocPrint(arena, "learned rule {d}", .{i});
                try std.testing.expect(playbook.add(io, arena, text, .learned, "run:1").ok);
            }
            const capped = playbook.add(io, arena, "learned overflow rule", .learned, "run:1");
            try std.testing.expect(!capped.ok);
            try std.testing.expectEqualStrings("", capped.id);

            // Sibling append-only writer (`compact_note`) also appends cleanly onto a 0-byte file.
            const cn = @import("compact_note.zig");
            try Io.Dir.cwd().createDirPath(io, cn.dir);
            const cn_path = cn.pathFor(arena, "s1").?;
            const f = try Io.Dir.cwd().createFile(io, cn_path, .{});
            f.close(io);
            try std.testing.expect(cn.record(io, arena, "s1", 0, "keep migration invariants"));
            try std.testing.expectEqual(@as(usize, 1), cn.load(io, arena, "s1").len);
        }
    }.body);
}

test "#1342 direct user message in history wins over stale named_work_task and rejects earlier turn" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            const messages = @import("messages.zig");
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);

            try root.messages.append(try messages.textMessage(arena, "user", "Never use emojis in turn one."));
            try root.messages.append(try messages.textMessage(arena, "assistant", "Understood."));
            try root.messages.append(try messages.textMessage(arena, "user", "Never commit credentials in this project."));
            // Simulate stale named_work_task still pointing at turn 1 (or another prior task).
            root.named_work_task = "Never use emojis in turn one.";

            try std.testing.expectEqualStrings("Never commit credentials in this project.", glue.currentUserText(&root));
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "Never use emojis in turn one.", "project")).is_error);

            const ok = glue.noteConstraint(&root, try call(arena, "Never commit credentials in this project.", "project"));
            try std.testing.expect(!ok.is_error);
            try std.testing.expect(std.mem.indexOf(u8, ok.text, "origin=current user message") != null);
            try std.testing.expectEqual(@as(usize, 1), playbook.load(io, arena).len);
        }
    }.body);
}

test "#1342 multimodal user messages, steers, and flushed images keep exact user provenance" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            const messages = @import("messages.zig");
            const session_wake = @import("session_wake.zig");
            const vision_queue = @import("vision_queue.zig");
            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.provider = .{ .id = "codegraff", .kind = .interactions, .auth = .bearer, .url = "", .api_key = "k", .model = "gemini-3-pro", .context = 100_000 };

            // Interactions multimodal `user_input` array (no `role` field).
            const gemini_msg = try std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{"type":"user_input","content":[{"type":"text","text":"Never inline SVG blobs in source files."},{"type":"image","mime_type":"image/png","data":"AAA="}]}
            , .{});
            try root.messages.append(gemini_msg);
            try std.testing.expectEqualStrings("Never inline SVG blobs in source files.", messages.latestUserText(root.messages.items));
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, "Never inline SVG blobs in source files.", "project")).is_error);

            // Multi-block user prompt where block 0 is a resource URI and block 1 is the user's text.
            try root.messages.append(try messages.textMessage(arena, "assistant", "Done."));
            const multi_block = try std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{"role":"user","content":[{"type":"text","text":"file:///repo/src/main.zig"},{"type":"text","text":"Always keep Zig files at or below 600 lines."}]}
            , .{});
            try root.messages.append(multi_block);
            root.named_work_task = messages.latestUserText(root.messages.items);
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, "Always keep Zig files at or below 600 lines.", "project")).is_error);

            // Post-tool image flush (`Attached image.`) must not clobber currentUserText or become recordable.
            vision_queue.stage(&root, .{ .media_type = "image/png", .b64 = "AAA=", .label = "shot.png" });
            try vision_queue.flushPending(&root);
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, vision_queue.attached_note, "project")).is_error);
            try std.testing.expect(!std.mem.eql(u8, vision_queue.attached_note, glue.currentUserText(&root)));

            // Human mid-turn steer (`injectSteer` / `steerMessage`) is a notice on the wire
            // yet eligible for `note_constraint`; machine wakes (`inject`) never are.
            session_wake.inject(&root, "Background job finished.");
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "Background job finished.", "project")).is_error);
            session_wake.injectSteer(&root, "Never auto-push release tags.");
            try std.testing.expect(session_wake.isNotice(root.messages.items[root.messages.items.len - 1]));
            try std.testing.expect(!glue.noteConstraint(&root, try call(arena, "Never auto-push release tags.", "project")).is_error);
            try std.testing.expectEqual(@as(usize, 3), playbook.load(io, arena).len);
        }
    }.body);
}

test "#1342 ACP elicitation ask_user records multi-sentence answers and expires next turn" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            const main_mod = @import("main.zig");
            const ask_user = @import("ask_user.zig");
            const acp_ask = @import("acp_ask.zig");
            const acp_elicit = @import("acp_elicit.zig");
            const answers = @import("ask_user_answers.zig");
            const messages = @import("messages.zig");

            answers.reset();
            defer answers.reset();
            const saved_json = main_mod.json_mode;
            main_mod.json_mode = true;
            defer main_mod.json_mode = saved_json;
            const saved_mode = acp_elicit.mode;
            defer acp_elicit.mode = saved_mode;

            acp_ask.attach(io, std.testing.allocator);
            defer acp_ask.detach();
            acp_elicit.configure(try std.json.parseFromSliceLeaky(
                std.json.Value,
                arena,
                "{\"clientCapabilities\":{\"elicitation\":{\"form\":{}}}}",
                .{},
            ));

            var aw: Io.Writer.Allocating = .init(arena);
            var root = rootStub(arena, &aw.writer);
            root.in = null;
            try root.messages.append(try messages.textMessage(arena, "user", "Prepare the release."));
            root.named_work_task = "Prepare the release.";

            const full_answer = "Always run tier-1 checks before pushing.\r\nFor this dry run, skip tag signing.";
            var responder = try io.concurrent(struct {
                fn run(inner_io: Io) void {
                    while (!acp_ask.reply(full_answer, false)) {
                        inner_io.sleep(.fromMilliseconds(1), .awake) catch break;
                    }
                }
            }.run, .{io});
            defer responder.cancel(io);

            const ask_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"question\":\"Any release rules?\"}", .{});
            const ask_res = try ask_user.askUser(&root, .{ .id = "call-1", .name = "ask_user", .input = ask_input });
            try std.testing.expect(!ask_res.is_error);

            // Qualifier-dropping fragment is rejected; single complete sentence and full verbatim answer both work.
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "run tier-1 checks before pushing", "project")).is_error);
            const single = glue.noteConstraint(&root, try call(arena, "Always run tier-1 checks before pushing.", "project"));
            try std.testing.expect(!single.is_error);
            try std.testing.expect(std.mem.indexOf(u8, single.text, "origin=user's ask_user answer") != null);

            const whole = glue.noteConstraint(&root, try call(arena, "Always run tier-1 checks before pushing.\nFor this dry run, skip tag signing.", "project"));
            try std.testing.expect(!whole.is_error);
            try std.testing.expectEqual(@as(usize, 2), playbook.load(io, arena).len);

            // Next user turn in messages (even before named_work_task updates) expires the prior turn's answer.
            try root.messages.append(try messages.textMessage(arena, "assistant", "Done."));
            try root.messages.append(try messages.textMessage(arena, "user", "Ship the notes."));
            try std.testing.expect(glue.noteConstraint(&root, try call(arena, "For this dry run, skip tag signing.", "project")).is_error);
        }
    }.body);
}

test "#1342 markdown list/quote lines and sentence punctuation work without weakening #789" {
    try std.testing.expect(glue.exactUserSegment("- Never push directly to main.", "Never push directly to main."));
    try std.testing.expect(glue.exactUserSegment("  * Always run zig fmt.", "Always run zig fmt."));
    try std.testing.expect(glue.exactUserSegment("> Never dump keychain items.", "Never dump keychain items."));
    try std.testing.expect(glue.exactUserSegment("1) Keep files at or below 600 lines.", "Keep files at or below 600 lines."));
    try std.testing.expect(glue.exactUserSegment("`Never emit OSC 50.`", "Never emit OSC 50."));
    try std.testing.expect(glue.exactUserSegment("(See #42.) Never dump keychain items.", "Never dump keychain items."));
    try std.testing.expect(glue.exactUserSegment("Never add telemetry in this project. Also check main.zig.", "Never add telemetry in this project"));

    // Qualifier and flag protections from #789 remain fail-closed.
    try std.testing.expect(!glue.exactUserSegment("- For this task, do not add dots.", "do not add dots."));
    try std.testing.expect(!glue.exactUserSegment("--no-telemetry must be passed.", "no-telemetry must be passed."));
    try std.testing.expect(!glue.exactUserSegment("\"Never delete files\" unless requested.", "Never delete files"));
    try std.testing.expect(!glue.exactUserSegment("In staging: never run migrations automatically.", "never run migrations automatically."));
    try std.testing.expect(!glue.exactUserSegment("Never modify v1.2.3 snapshots.", "Never modify v1"));
}

test "Harness^2 recordOutcome: retires negative-fitness learned items while preserving user constraints" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            const u = playbook.add(io, arena, "Never import external packages in billing.py", .user, "user:1");
            const bad = playbook.add(io, arena, "[domain] Return strings instead of ints from compute_total", .learned, "run:1");
            try std.testing.expect(u.ok and bad.ok);

            try std.testing.expectEqual(@as(usize, 0), playbook.recordOutcome(io, arena, false));
            const after1 = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 2), after1.len);
            try std.testing.expectEqual(@as(u32, 1), playbook.find(after1, bad.id).?.fails);

            try std.testing.expectEqual(@as(usize, 1), playbook.recordOutcome(io, arena, false));
            const after2 = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 1), after2.len);
            try std.testing.expectEqualStrings(u.id, after2[0].id);
        }
    }.body);
}

test "Harness^2 contrastive reflector: noteFailure and reflectPromptWithContext carry fail->fix->pass evidence" {
    const reflect = @import("playbook_reflect.zig");
    reflect.resetForTest();
    defer reflect.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    reflect.noteFailure("ContractError: every serializer dict MUST include '_wire_envelope': 'v2-strict'");
    try std.testing.expect(std.mem.indexOf(u8, reflect.failEvidence(), "_wire_envelope") != null);
    try std.testing.expect(!reflect.editedAfterFailure());
    reflect.noteEditAfterFailure();
    try std.testing.expect(reflect.editedAfterFailure());

    const prompt = reflect.reflectPromptWithContext(
        arena,
        "verify",
        100,
        100,
        "ALL CHECKS PASSED\nscore: 100",
        reflect.failEvidence(),
        "+    '_wire_envelope': 'v2-strict'",
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Prior failed check output (before the fix):") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "_wire_envelope") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Workspace diff that made the check pass:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[invariant]") != null);
}

test "corrupt-safe playbook: parseDetailed counts malformed rows and recordedStateWithHealth emits storage_warning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const raw =
        "{\"v\":2,\"op\":\"add\",\"id\":\"pb-11111111\",\"text\":\"never use eval\",\"source\":\"user\",\"scope\":\"project\"}\n" ++
        "{torn-json-from-crash\n" ++
        "{\"v\":2,\"op\":\"add\",\"id\":\"pb-22222222\",\"text\":\"keep files under 600 lines\",\"source\":\"user\",\"scope\":\"project\"}\n";
    const report = playbook.parseDetailed(a, raw);
    try std.testing.expectEqual(@as(usize, 2), report.items.len);
    try std.testing.expectEqual(@as(usize, 1), report.corrupt_lines);
    try std.testing.expectEqual(@as(usize, 2), report.first_corrupt_line);

    const state = try playbook.recordedStateWithHealth(a, report);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"storage_warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "1 malformed JSONL row(s) (first at line 2)") != null);
}
