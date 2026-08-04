//! Tests for the #381/#383 playbook substrate, its injection block, its
//! capture surfaces, and the #383 reflector's reply parsing. Reached through
//! the `test { _ = @import(...) }` hook at the bottom of playbook.zig.
//!
//! Everything that touches the ledger FILE goes through a real
//! createFile/read round trip in a scratch cwd rather than a hand-built
//! string: the whole claim of #381 is that a constraint survives a process
//! boundary, and a test that never serializes cannot show that.

const std = @import("std");
const Io = std.Io;

const playbook = @import("playbook.zig");
const reflect = @import("playbook_reflect.zig");
const glue = @import("playbook_glue.zig");
const prompts = @import("prompts.zig");
const Agent = @import("agent.zig").Agent;

/// Run `body` with the process cwd moved into a fresh scratch directory, so
/// the real `.graff/playbook.jsonl` path is exercised without touching the
/// repo checkout. Same fchdir approach agent_eval_tests.zig uses, and for the
/// same reason: the store takes no Dir parameter.
fn inScratch(comptime body: fn (Io, std.mem.Allocator) anyerror!void) !void {
    if (@import("builtin").os.tag == .windows) return;
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

test "normalize: the dedupe key ignores case, punctuation and whitespace runs" {
    var a: [playbook.max_text]u8 = undefined;
    var b: [playbook.max_text]u8 = undefined;
    try std.testing.expectEqualStrings("no emojis in code comments", playbook.normalize(&a, "  No EMOJIS, in   code-comments!!  "));
    try std.testing.expectEqualStrings(playbook.normalize(&a, "No dots."), playbook.normalize(&b, "no  dots"));
    try std.testing.expectEqualStrings("", playbook.normalize(&a, "  ---  "));
    // Non-ASCII stays intact rather than shattering into per-byte tokens.
    try std.testing.expectEqualStrings("café ohne zucker", playbook.normalize(&a, "Café — ohne Zucker"));
}

test "idFor: content-derived, so identity and dedupe are the same operation" {
    var x: [11]u8 = undefined;
    var y: [11]u8 = undefined;
    try std.testing.expectEqualStrings(playbook.idFor(&x, "no scroll hints"), playbook.idFor(&y, "  No, Scroll Hints!  "));
    try std.testing.expect(!std.mem.eql(u8, playbook.idFor(&x, "no scroll hints"), playbook.idFor(&y, "no progress dots")));
    try std.testing.expect(std.mem.startsWith(u8, playbook.idFor(&x, "anything at all"), "pb-"));
    try std.testing.expectEqual(@as(usize, 11), playbook.idFor(&x, "anything at all").len);
}

test "store round trip: add/dedupe/retire through the real .graff/playbook.jsonl file format" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            try std.testing.expectEqual(@as(usize, 0), playbook.load(io, arena).len);

            const first = playbook.add(io, arena, "never use emojis in code comments", .user, "user:1");
            try std.testing.expect(first.ok);
            const learned = playbook.add(io, arena, "- prefer codedb outline before read on files over 300 lines", .learned, "run:abc123");
            try std.testing.expect(learned.ok); // the leading bullet marker is stripped, not stored

            // Read back through the real serializer + parser, not a fixture.
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 2), items.len);
            try std.testing.expectEqualStrings("never use emojis in code comments", items[0].text);
            try std.testing.expectEqual(playbook.Source.user, items[0].source);
            try std.testing.expectEqualStrings("user:1", items[0].provenance);
            try std.testing.expect(items[0].created_at > 0);
            try std.testing.expectEqualStrings("prefer codedb outline before read on files over 300 lines", items[1].text);
            try std.testing.expectEqual(playbook.Source.learned, items[1].source);
            try std.testing.expectEqualStrings("run:abc123", items[1].provenance);

            // Dedupe is normalized-exact: a re-statement is refused, reported,
            // and does NOT append a second record.
            const dupe = playbook.add(io, arena, "Never use emojis in CODE comments.", .user, "user:2");
            try std.testing.expect(!dupe.ok);
            try std.testing.expectEqualStrings(first.id, dupe.id);
            try std.testing.expect(std.mem.indexOf(u8, dupe.reason, "already recorded") != null);
            try std.testing.expectEqual(@as(usize, 2), playbook.load(io, arena).len);

            // An empty/punctuation-only constraint is refused rather than
            // stored as an item that injects a bare "- ".
            try std.testing.expect(!playbook.add(io, arena, "  ***  ", .user, "user:3").ok);

            // Retire is a TOMBSTONE: the add record stays on disk, and the
            // file only ever grows.
            const before = (try Io.Dir.cwd().readFileAlloc(io, playbook.path, arena, .limited(1 << 20))).len;
            try std.testing.expect(playbook.retire(io, arena, first.id));
            const after = try Io.Dir.cwd().readFileAlloc(io, playbook.path, arena, .limited(1 << 20));
            try std.testing.expect(after.len > before);
            try std.testing.expect(std.mem.indexOf(u8, after, "never use emojis in code comments") != null); // history intact
            const live = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 1), live.len);
            try std.testing.expectEqual(playbook.Source.learned, live[0].source);

            // Retiring an unknown id writes nothing and says so.
            try std.testing.expect(!playbook.retire(io, arena, "pb-deadbeef"));

            // Re-adding a retired item works: the later op wins.
            try std.testing.expect(playbook.add(io, arena, "never use emojis in code comments", .user, "user:4").ok);
            try std.testing.expectEqual(@as(usize, 2), playbook.load(io, arena).len);
        }
    }.body);
}

test "parse: a torn tail or a junk line costs at most its own record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = playbook.parse(arena,
        \\{"v":1,"op":"add","id":"pb-00000001","text":"first","source":"user"}
        \\not json at all
        \\{"v":1,"op":"add","id":"pb-00000002","text":"second","source":"learned"}
        \\
        \\{"v":1,"op":"add","id":"pb-000000
    );
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("first", items[0].text);
    try std.testing.expectEqualStrings("second", items[1].text);
}

test "blockFrom: user before learned, both headed, and nothing at all when empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("", playbook.blockFrom(arena, &.{}));

    const items = [_]playbook.Item{
        .{ .id = "pb-1", .text = "learned first in file order", .source = .learned },
        .{ .id = "pb-2", .text = "no navigation dots", .source = .user },
        .{ .id = "pb-3", .text = "no scroll hints", .source = .user },
    };
    const block = playbook.blockFrom(arena, &items);
    const user_at = std.mem.indexOf(u8, block, playbook.user_header).?;
    const learned_at = std.mem.indexOf(u8, block, playbook.learned_header).?;
    try std.testing.expect(user_at < learned_at); // user ALWAYS outranks learned
    // Newest-first within a section: the most recent "no" leads.
    try std.testing.expect(std.mem.indexOf(u8, block, "- no scroll hints").? < std.mem.indexOf(u8, block, "- no navigation dots").?);
    try std.testing.expect(std.mem.indexOf(u8, block, "- learned first in file order") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "omitted") == null); // nothing was cut

    // A learned-only ledger must not print an empty HARD CONSTRAINTS header.
    const learned_only = playbook.blockFrom(arena, items[0..1]);
    try std.testing.expect(std.mem.indexOf(u8, learned_only, playbook.user_header) == null);
    try std.testing.expect(std.mem.startsWith(u8, learned_only, playbook.learned_header));
}

test "blockFrom: the item cap truncates newest-first and SAYS it truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n = playbook.user_block_items + 5;
    const items = try arena.alloc(playbook.Item, n);
    for (items, 0..) |*item, i| item.* = .{
        .id = "pb-x",
        .text = std.fmt.allocPrint(arena, "constraint number {d}", .{i}) catch unreachable,
        .source = .user,
    };
    const block = playbook.blockFrom(arena, items);
    // Every bullet is preceded by a newline (the header's, or the previous
    // bullet's), so this counts them exactly.
    try std.testing.expectEqual(playbook.user_block_items, std.mem.count(u8, block, "\n- "));
    // Silent truncation would be a lie: a worker told "these are the
    // constraints" has to know when it was told only some of them.
    try std.testing.expect(std.mem.indexOf(u8, block, "5 older item(s) omitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, playbook.path) != null);
    // The newest survived and the oldest was the one cut.
    try std.testing.expect(std.mem.indexOf(u8, block, "constraint number 34") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "constraint number 0\n") == null);
}

test "blockFrom: the byte cap bounds the block even with one absurd item each" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long = try arena.alloc(u8, playbook.max_text);
    @memset(long, 'x');
    const items = try arena.alloc(playbook.Item, 40);
    for (items, 0..) |*item, i| item.* = .{ .id = "pb-x", .text = long, .source = if (i % 2 == 0) .user else .learned };
    const block = playbook.blockFrom(arena, items);
    try std.testing.expect(block.len < playbook.user_block_bytes + playbook.learned_block_bytes + 512);
}

test "rideBrief: identity on an empty ledger, block-prefixed once there is one" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            try std.testing.expectEqualStrings("do the thing", playbook.rideBrief(io, arena, "do the thing"));
            try std.testing.expect(playbook.add(io, arena, "no navigation dots", .user, "user:1").ok);
            const brief = playbook.rideBrief(io, arena, "do the thing");
            try std.testing.expect(std.mem.startsWith(u8, brief, playbook.user_header));
            try std.testing.expect(std.mem.indexOf(u8, brief, "- no navigation dots") != null);
            try std.testing.expect(std.mem.endsWith(u8, brief, "do the thing"));
        }
    }.body);
}

test "composeRoot: gated off until armed, then appends the same block to the root's base" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            try std.testing.expect(playbook.add(io, arena, "no scroll hints", .user, "user:1").ok);
            const composed = playbook.composeRoot(io, arena, "BASE");
            try std.testing.expect(std.mem.startsWith(u8, composed, "BASE"));
            try std.testing.expect(std.mem.indexOf(u8, composed, "- no scroll hints") != null);
        }
    }.body);
}

test "the learned cap refuses rather than evicting, and never touches user items" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            for (0..playbook.max_learned) |i| {
                const text = try std.fmt.allocPrint(arena, "learned insight number {d}", .{i});
                try std.testing.expect(playbook.add(io, arena, text, .learned, "run:x").ok);
            }
            const over = playbook.add(io, arena, "one insight too many", .learned, "run:x");
            try std.testing.expect(!over.ok);
            try std.testing.expect(std.mem.indexOf(u8, over.reason, "cap") != null);
            // v1 refuses; it does NOT evict, because choosing a victim needs
            // per-item fitness and that attribution is follow-up scope.
            try std.testing.expectEqual(playbook.max_learned, playbook.countOf(playbook.load(io, arena), .learned));
            // A user constraint still lands: the learned ceiling is not a
            // ceiling on the user's own rules.
            try std.testing.expect(playbook.add(io, arena, "never ship on a Friday", .user, "user:1").ok);
        }
    }.body);
}

test "reflector (#383): parses at most 3 bullets out of a canned reply, no live call" {
    var out: [reflect.max_candidates][]const u8 = undefined;

    const typical =
        \\Here are the durable lessons from this run:
        \\- the zig sources are capped at 600 lines; split before adding a module
        \\* regenerate the SDKs after any tool-schema change or CI fails
        \\1. run zig fmt on touched files before committing
        \\- a fourth bullet that must not be taken
        \\
        \\Hope that helps!
    ;
    const got = reflect.parseCandidates(&out, typical);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("the zig sources are capped at 600 lines; split before adding a module", got[0]);
    try std.testing.expectEqualStrings("regenerate the SDKs after any tool-schema change or CI fails", got[1]);
    try std.testing.expectEqualStrings("run zig fmt on touched files before committing", got[2]);

    // Prose-only replies yield nothing: a preamble curated into the playbook
    // would be injected into every future brief forever, so a false positive
    // costs far more than a missed insight.
    try std.testing.expectEqual(@as(usize, 0), reflect.parseCandidates(&out, "I could not find anything durable worth recording.").len);
    try std.testing.expectEqual(@as(usize, 0), reflect.parseCandidates(&out, "none").len);
    try std.testing.expectEqual(@as(usize, 0), reflect.parseCandidates(&out, "- none").len);
    try std.testing.expectEqual(@as(usize, 0), reflect.parseCandidates(&out, "- ok").len); // too short to be an insight
    try std.testing.expectEqual(@as(usize, 0), reflect.parseCandidates(&out, "").len);

    // An oversized bullet is capped, not dropped.
    var big: [playbook.max_text * 2]u8 = undefined;
    @memset(&big, 'y');
    big[0] = '-';
    big[1] = ' ';
    const capped = reflect.parseCandidates(&out, &big);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    try std.testing.expectEqual(playbook.max_text, capped[0].len);
}

test "reflector curation is deterministic: the same candidates twice add nothing the second time" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var out: [reflect.max_candidates][]const u8 = undefined;
            const reply = "- regenerate the SDKs after any tool-schema change\n- zig sources are capped at 600 lines";
            for (0..2) |_| {
                for (reflect.parseCandidates(&out, reply)) |text| _ = playbook.add(io, arena, text, .learned, "run:abc");
            }
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 2), items.len);
            for (items) |item| {
                try std.testing.expectEqual(playbook.Source.learned, item.source);
                try std.testing.expectEqualStrings("run:abc", item.provenance); // provenance is the minting run
            }
        }
    }.body);
}

/// A root Agent with just enough wired up for the capture surfaces: real io
/// (they touch the ledger file), a captured writer, and undefined provider/
/// client, which neither surface goes near.
fn stubRoot(gpa: std.mem.Allocator, arena: std.mem.Allocator, out: *Io.Writer) Agent {
    return .{
        .gpa = gpa,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = out,
    };
}

test "/never (#381): bare lists, text adds, rm retires — and a non-/never line falls through" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = stubRoot(std.testing.allocator, arena, &aw.writer);

            // Unrelated lines are NOT claimed, including the prefix trap.
            try std.testing.expect(!try glue.command(&root, arena, "/models", &aw.writer));
            try std.testing.expect(!try glue.command(&root, arena, "/neverending story", &aw.writer));

            try std.testing.expect(try glue.command(&root, arena, "/never", &aw.writer));
            try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "playbook empty") != null);

            aw.clearRetainingCapacity();
            try std.testing.expect(try glue.command(&root, arena, "/never no navigation dots or scroll hints", &aw.writer));
            const added = aw.writer.buffered();
            // Duped: the writer below is cleared and rewritten, and a slice
            // into its retained buffer would silently become another message.
            const id = try arena.dupe(u8, added[std.mem.indexOf(u8, added, "pb-").?..][0..11]);
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 1), items.len);
            try std.testing.expectEqualStrings("no navigation dots or scroll hints", items[0].text);
            try std.testing.expectEqual(playbook.Source.user, items[0].source);
            try std.testing.expect(std.mem.startsWith(u8, items[0].provenance, "user:"));

            // The alias is the same command, and it dedupes against the same ledger.
            aw.clearRetainingCapacity();
            try std.testing.expect(try glue.command(&root, arena, "/constraint No navigation dots, or scroll hints!", &aw.writer));
            try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "not recorded") != null);
            try std.testing.expectEqual(@as(usize, 1), playbook.load(io, arena).len);

            aw.clearRetainingCapacity();
            try std.testing.expect(try glue.command(&root, arena, "/never", &aw.writer));
            try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "no navigation dots") != null);
            try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "user") != null);

            aw.clearRetainingCapacity();
            try std.testing.expect(try glue.command(&root, arena, "/never rm pb-deadbeef", &aw.writer));
            try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "no live playbook item") != null);

            aw.clearRetainingCapacity();
            const rm = try std.fmt.allocPrint(arena, "/never rm {s}", .{id});
            try std.testing.expect(try glue.command(&root, arena, rm, &aw.writer));
            try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "retired") != null);
            try std.testing.expectEqual(@as(usize, 0), playbook.load(io, arena).len);
        }
    }.body);
}

test "note_constraint (#381): appends user items only, is idempotent, and can never retire one" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            var aw: Io.Writer.Allocating = .init(arena);
            var root = stubRoot(std.testing.allocator, arena, &aw.writer);
            const call = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"text\":\"never use emojis in code comments\"}", .{});

            const first = glue.noteConstraint(&root, call);
            try std.testing.expect(!first.is_error);
            try std.testing.expect(std.mem.indexOf(u8, first.text, "constraint recorded as pb-") != null);
            const items = playbook.load(io, arena);
            try std.testing.expectEqual(@as(usize, 1), items.len);
            try std.testing.expectEqual(playbook.Source.user, items[0].source); // NEVER .learned

            // A repeat is the desired end state, not a failure: reporting it as
            // an error would push the model into retrying a correct ledger.
            const again = glue.noteConstraint(&root, call);
            try std.testing.expect(!again.is_error);
            try std.testing.expectEqual(@as(usize, 1), playbook.load(io, arena).len);

            // Empty/blank text is refused rather than stored.
            const blank = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"text\":\"   \"}", .{});
            try std.testing.expect(glue.noteConstraint(&root, blank).is_error);
            const missing = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
            try std.testing.expect(glue.noteConstraint(&root, missing).is_error);

            // The append-only contract, structurally: whatever the model puts
            // in `text`, the ledger only ever grows and the item stays live.
            // There is no argument shape that reaches retire from here.
            for ([_][]const u8{ "{\"text\":\"retire pb-00000001\"}", "{\"text\":\"rm all\"}", "{\"op\":\"retire\",\"id\":\"pb-00000001\",\"text\":\"x\"}" }) |raw| {
                const before = playbook.load(io, arena).len;
                _ = glue.noteConstraint(&root, try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}));
                try std.testing.expect(playbook.load(io, arena).len >= before);
            }
            try std.testing.expect(playbook.find(playbook.load(io, arena), items[0].id) != null); // the original survived every one
        }
    }.body);
}

test "refreshRoot (#381): a constraint recorded mid-session reaches the ROOT's own prompt, all four variants" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            _ = io; // the ledger is reached through the agent's own io here
            const saved = playbook.g_root_inject;
            defer playbook.g_root_inject = saved;
            var aw: Io.Writer.Allocating = .init(arena);
            var root = stubRoot(std.testing.allocator, arena, &aw.writer);

            try prompts.setRootSystemPrompts(&root, "ROOT-BASE", arena);
            try std.testing.expectEqualStrings("ROOT-BASE", root.sys_base);
            try std.testing.expectEqualStrings("ROOT-BASE", root.sys_normal); // empty ledger costs nothing

            _ = glue.noteConstraint(&root, try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"text\":\"no scroll hints\"}", .{}));
            // noteConstraint refreshed it: no restart, no re-login, next request.
            for ([_][]const u8{ root.sys_normal, root.sys_strict, root.sys_ultra, root.sys_ultra_strict }) |v| {
                try std.testing.expect(std.mem.indexOf(u8, v, "ROOT-BASE") != null);
                try std.testing.expect(std.mem.indexOf(u8, v, "- no scroll hints") != null);
            }
            // The BASE is remembered unpolluted, so the next refresh composes
            // from it rather than stacking a second block onto the first.
            try std.testing.expectEqualStrings("ROOT-BASE", root.sys_base);
            _ = glue.noteConstraint(&root, try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"text\":\"no progress dots\"}", .{}));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, root.sys_normal, playbook.user_header));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, root.sys_normal, "ROOT-BASE"));
            try std.testing.expect(std.mem.indexOf(u8, root.sys_normal, "- no progress dots") != null);

            // And a persona swap through the ordinary funnel keeps the block.
            try prompts.setSystemPrompts(&root, "PERSONA-BASE", arena);
            try std.testing.expect(std.mem.indexOf(u8, root.sys_normal, "PERSONA-BASE") != null);
            try std.testing.expect(std.mem.indexOf(u8, root.sys_normal, "- no progress dots") != null);
        }
    }.body);
}

test "idList: the kind:\"playbook\" row's id column is the join key for later attribution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("", playbook.idList(arena, &.{}));
    try std.testing.expectEqualStrings("pb-1,pb-2", playbook.idList(arena, &.{
        .{ .id = "pb-1", .text = "a", .source = .user },
        .{ .id = "pb-2", .text = "b", .source = .learned },
    }));
}
