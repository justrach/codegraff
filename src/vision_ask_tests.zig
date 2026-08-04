//! #380 tests: image-path detection, the vision-ask re-route (and the pins it
//! must NOT override), the no-vision-anywhere fast fail, and the report-time
//! honesty flag. Split out of vision_ask.zig so neither file grows toward the
//! 600-line cap; reached from test_hooks.zig, without which these would be
//! silently skipped.

const std = @import("std");

const va = @import("vision_ask.zig");
const pin_mod = @import("subagent_pin.zig");
const policy = @import("route_policy.zig");
const route_phase = @import("route_phase.zig");
const bench = @import("bench_priors.zig");
const selection = @import("subagent_selection.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;

fn obj(a: std.mem.Allocator, json: []const u8) std.json.ObjectMap {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .allocate = .alloc_always }) catch unreachable;
    return v.object;
}

fn deepseek() Provider {
    return .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-pro", .context = 128_000 };
}

fn codex() Provider {
    return .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6-sol", .context = 270_000 };
}

/// A Keys table with `logged_in` providers holding a token, installed as the
/// global bench_priors.g_keys the routing code reads. Returns the previous
/// value so the caller can restore it.
fn withKeys(keys: *provider_mod.Keys, logged_in: []const []const u8) void {
    keys.* = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        for (logged_in) |id| if (std.mem.eql(u8, spec.id, id)) {
            value.* = "test-token";
        };
    }
    bench.g_keys = keys;
}

test "#380 detection: a concrete image path, not any mention of an image format" {
    // POSITIVES — the shapes a root actually writes.
    try std.testing.expectEqualStrings("assets/palette.png", va.imagePathIn("Analyze the color palette in assets/palette.png and report the hex values").?);
    try std.testing.expectEqualStrings("shot.png", va.imagePathIn("open shot.png").?); // bare filename
    try std.testing.expectEqualStrings("/tmp/a.JPEG", va.imagePathIn("read /tmp/a.JPEG").?); // case-insensitive
    try std.testing.expectEqualStrings("docs/x.webp", va.imagePathIn("(see docs/x.webp)").?); // parenthesised
    try std.testing.expectEqualStrings("ui.gif", va.imagePathIn("`ui.gif`").?); // backticked
    try std.testing.expectEqualStrings("out/v2.final.jpg", va.imagePathIn("compare out/v2.final.jpg, then stop").?); // dotted stem, trailing comma
    try std.testing.expectEqualStrings("a.png", va.imagePathIn("the file is a.png.").?); // sentence-final period
    // A quoted path may contain spaces — widened only because the same quote
    // closes right after the extension.
    try std.testing.expectEqualStrings("my shots/color palette.png", va.imagePathIn("open \"my shots/color palette.png\" please").?);
    try std.testing.expectEqualStrings("color palette.png", va.imagePathIn("open 'color palette.png' please").?);

    // NEGATIVES — every one of these used to be the reason a naive substring
    // check could not be shipped.
    try std.testing.expect(va.imagePathIn("explain png compression and why gif is worse") == null);
    try std.testing.expect(va.imagePathIn("the .pngx container format") == null); // a word byte after the ext
    try std.testing.expect(va.imagePathIn("save it as a .png file") == null); // no stem
    try std.testing.expect(va.imagePathIn("delete all *.png artifacts") == null); // a glob is not a concrete path
    try std.testing.expect(va.imagePathIn("fetch https://example.com/a.png") == null); // remote URL, see the module doc
    try std.testing.expect(va.imagePathIn("http://x.io/y/z.jpg") == null);
    try std.testing.expect(va.imagePathIn("") == null);
    try std.testing.expect(va.imagePathIn("no images here at all") == null);
    // An unquoted space still splits: the detection is right (it IS an ask),
    // only the reported token is the tail. Pinned so the behavior is a choice.
    try std.testing.expectEqualStrings("palette.png", va.imagePathIn("open my shots/color palette.png").?);
}

test "#380 re-route: an automatic seat that cannot see images moves to one that can" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = undefined;
    withKeys(&keys, &.{"codex"});

    // A plain inherit-the-root deepseek session (session_pinned = false) is an
    // AUTOMATIC seat: nobody chose deepseek for THIS worker.
    const ask = va.forSpawn(deepseek(), obj(a, "{}"), false, .{}, "Analyze the palette in assets/palette.png");
    try std.testing.expect(ask.isAsk());
    try std.testing.expect(ask.rerouted);
    try std.testing.expect(!ask.blocked);
    try std.testing.expect(!ask.pinned_blind);
    try std.testing.expectEqual(policy.Source.vision_ask, ask.source);
    // Sub-first: the logged-in flat-rate codex subscription, cheapest rung.
    try std.testing.expectEqualStrings("codex", ask.pin.provider.?.id);
    try std.testing.expectEqualStrings("gpt-5.6-luna", ask.pin.provider.?.model);
    try std.testing.expectEqualStrings("vision-ask", ask.source.label());
    try std.testing.expect(ask.note() != null);

    // The SAME session with a task that names no image is left exactly alone.
    const plain = va.forSpawn(deepseek(), obj(a, "{}"), false, .{}, "Summarize the README");
    try std.testing.expect(!plain.isAsk());
    try std.testing.expect(!plain.rerouted);
    try std.testing.expect(plain.pin.provider == null); // session default kept
    try std.testing.expectEqual(policy.Source.session_default, plain.source);

    // A seat that ALREADY sees images is not moved either — no gratuitous
    // model changes just because a path was mentioned.
    const seeing = va.forSpawn(codex(), obj(a, "{}"), false, .{}, "Describe shot.png");
    try std.testing.expect(seeing.isAsk());
    try std.testing.expect(!seeing.rerouted);
    try std.testing.expect(seeing.pin.provider == null);
}

test "#380 re-route: an explicit pin and a persona pin keep priority, and are flagged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = undefined;
    withKeys(&keys, &.{ "codex", "deepseek" });

    // The call names a text-only model for a task that needs eyes. The pin is
    // HONORED (a human outranks a capability heuristic) and the run is marked
    // so both the trace and the report say what happened.
    const pinned = va.forSpawn(deepseek(), obj(a, "{\"model\":\"deepseek-v4-flash\"}"), false, .{}, "read assets/palette.png");
    try std.testing.expect(pinned.pinned_blind);
    try std.testing.expect(!pinned.rerouted);
    try std.testing.expect(!pinned.blocked);
    try std.testing.expectEqualStrings("deepseek-v4-flash", pinned.pin.provider.?.model); // not overridden
    try std.testing.expectEqual(policy.Source.explicit_pin, pinned.source); // the trace still credits the human
    try std.testing.expect(std.mem.indexOf(u8, pinned.note().?, "pin was kept") != null);

    // An explicit --subagent-model session (session_pinned = true, and the
    // worker model did NOT come from the #291 ladder descent) is the same
    // human decision one level up: warn, never override.
    const saved_ladder = selection.g_default_from_ladder;
    defer selection.g_default_from_ladder = saved_ladder;
    selection.g_default_from_ladder = false;
    const session = va.forSpawn(deepseek(), obj(a, "{}"), true, .{}, "read assets/palette.png");
    try std.testing.expect(session.pinned_blind);
    try std.testing.expect(!session.rerouted);
    try std.testing.expect(session.pin.provider == null);

    // The SAME session_pinned bit with the worker seated by the automatic
    // ladder descent is not a human choice at all — it re-routes. Conflating
    // the two is exactly the blindness #372 named.
    selection.g_default_from_ladder = true;
    try std.testing.expect(va.forSpawn(deepseek(), obj(a, "{}"), true, .{}, "read assets/palette.png").rerouted);

    // userChose is the whole rule, stated once.
    try std.testing.expect(va.userChose(.explicit_pin, false));
    try std.testing.expect(va.userChose(.persona, false));
    try std.testing.expect(va.userChose(.session_default, true)); // --subagent-model
    try std.testing.expect(!va.userChose(.session_default, false)); // plain inherit
    try std.testing.expect(!va.userChose(.ladder, false));
    try std.testing.expect(!va.userChose(.learned_policy, false));
}

test "#380 fast fail: no vision-capable model anywhere refuses the spawn, actionably" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = undefined;
    withKeys(&keys, &.{"deepseek"}); // no sub logged in, and deepseek serves no vision model

    const ask = va.forSpawn(deepseek(), obj(a, "{}"), false, .{}, "extract the hexes from assets/palette.png");
    try std.testing.expect(ask.blocked);
    try std.testing.expect(!ask.rerouted);
    try std.testing.expect(ask.pin.provider == null);

    const msg = try va.blockMessage(std.testing.allocator, ask);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "assets/palette.png") != null); // names the trigger
    try std.testing.expect(std.mem.indexOf(u8, msg, "graff login") != null); // names the fix
    try std.testing.expect(std.mem.indexOf(u8, msg, "API_KEY") != null); // …and the other fix
    try std.testing.expect(std.mem.indexOf(u8, msg, "not spawned") != null); // and says nothing ran

    try std.testing.expect(ask.pricier.len == 0); // deepseek serves NO vision model, at any price

    // A task with no image on the same credential-starved session still runs.
    try std.testing.expect(!va.forSpawn(deepseek(), obj(a, "{}"), false, .{}, "refactor util.zig").blocked);

    // The OTHER refusal: a vision model exists on this provider but the cost
    // ceiling refuses it, because an automatic route never escalates spend.
    // Saying "none is reachable" there would be a lie, so it is a distinct
    // message that names the model and how to authorize it.
    withKeys(&keys, &.{"anthropic"});
    const cheap: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-haiku-4-5", .context = 200_000 };
    try std.testing.expectEqualStrings("", va.blockedByCost(cheap)); // haiku IS the cheap vision rung — affordable, so not this case
    const priced_out: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "deepseek-v4-flash", .context = 200_000 };
    try std.testing.expectEqualStrings("claude-haiku-4-5", va.blockedByCost(priced_out));
    const cost_msg = try va.blockMessage(std.testing.allocator, .{ .path = "a.png", .blocked = true, .pricier = "claude-haiku-4-5" });
    defer std.testing.allocator.free(cost_msg);
    try std.testing.expect(std.mem.indexOf(u8, cost_msg, "model:\"claude-haiku-4-5\"") != null); // how to authorize it
    try std.testing.expect(std.mem.indexOf(u8, cost_msg, "escalate") != null); // and why it was not taken
    try std.testing.expect(!std.mem.eql(u8, cost_msg, msg));
}

test "#380 candidate search: sub-first, then provider-local under the cost ceiling" {
    // Ladder rungs bottom-up, so a re-route descends price rather than seizing
    // the frontier model.
    try std.testing.expectEqualStrings("gpt-5.6-luna", va.visionModelFor("codex").?);
    try std.testing.expectEqualStrings("claude-haiku-4-5", va.visionModelFor("anthropic").?);
    try std.testing.expect(va.visionModelFor("deepseek") == null); // no vision model at any rung

    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = undefined;

    // Nothing logged in: no sub candidate, and deepseek has nothing local.
    bench.g_keys = null;
    try std.testing.expect(va.visionSeat(deepseek()) == null);

    // codex logged in: the flat-rate sub wins, cross-provider, exactly like
    // subagent_pin.subscriptionRung — the login IS the consent.
    withKeys(&keys, &.{"codex"});
    const seat = va.visionSeat(deepseek()).?;
    try std.testing.expectEqualStrings("codex", seat.id);
    try std.testing.expectEqualStrings("gpt-5.6-luna", seat.model);

    // An anthropic base with no sub logged in resolves provider-locally, and
    // only because haiku is CHEAPER than the opus it replaces.
    withKeys(&keys, &.{"anthropic"});
    const opus_root: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-opus-4-8", .context = 200_000 };
    const local = va.visionSeat(opus_root).?;
    try std.testing.expectEqualStrings("anthropic", local.id);
    try std.testing.expectEqualStrings("claude-haiku-4-5", local.model);
}

test "#380 honesty flag: each disclaimer spelling is caught, ordinary reports are not" {
    const ask: va.Ask = .{ .path = "assets/palette.png" };
    const not_ask: va.Ask = .{};

    // The exact sentence from the trajectory that motivated this issue.
    const real = "I couldn't open the image as a vision input, so I sampled the file bytes instead.";
    try std.testing.expect(va.disclaimed(real));
    try std.testing.expectEqualStrings(va.disclaimer_warning, va.warningFor(ask, real).?);

    for (va.disclaimers) |d| {
        var buf: [256]u8 = undefined;
        const report = try std.fmt.bufPrint(&buf, "Report follows. {s} — here is what I inferred.", .{d});
        try std.testing.expect(va.disclaimed(report));
        try std.testing.expectEqualStrings(va.disclaimer_warning, va.warningFor(ask, report).?);
        // Case-insensitive, since a report may start the sentence.
        var up: [256]u8 = undefined;
        const upper = std.ascii.upperString(up[0..report.len], report);
        try std.testing.expect(va.disclaimed(upper));
        // …but a task that never named an image is never flagged, however the
        // worker phrased itself.
        try std.testing.expect(va.warningFor(not_ask, report) == null);
    }

    // Ordinary reports — including ones that talk about images at length —
    // stay unflagged. This is why the marker list is tight.
    for ([_][]const u8{
        "The image shows three greens and a warm grey; the dominant hue is #2E5B3A.",
        "I opened the image and read the palette directly.",
        "png compression is lossless, unlike jpeg",
        "Could not open the file assets/palette.png — it does not exist.",
        "",
    }) |ok| {
        try std.testing.expect(!va.disclaimed(ok));
        try std.testing.expect(va.warningFor(ask, ok) == null);
    }

    // A kept blind pin flags even a report that made no admission — the root
    // otherwise has no way to know the worker never saw anything.
    const blind: va.Ask = .{ .path = "a.png", .pinned_blind = true };
    try std.testing.expectEqualStrings(va.pinned_warning, va.warningFor(blind, "The palette is #2E5B3A, #C9A227, #8A8F98.").?);
    // The stronger, evidence-backed line wins when both apply.
    try std.testing.expectEqualStrings(va.disclaimer_warning, va.warningFor(blind, "I cannot view the image.").?);
    // And an unflagged, non-ask spawn keeps its blind pin quiet.
    try std.testing.expect(va.warningFor(.{ .pinned_blind = true }, "done") == null);
}

test "#380 flagText: prepends once, transfers ownership, never marks is_error" {
    const gpa = std.testing.allocator;
    const ask: va.Ask = .{ .path = "a.png" };

    const owned = try gpa.dupe(u8, "I couldn't open the image as a vision input; the palette below is inferred.");
    const flagged = va.flagText(gpa, owned, ask);
    defer gpa.free(flagged);
    try std.testing.expect(std.mem.startsWith(u8, flagged, va.disclaimer_warning));
    try std.testing.expect(std.mem.indexOf(u8, flagged, "the palette below is inferred") != null); // report survives verbatim
    try std.testing.expect(std.mem.indexOf(u8, flagged, "not seen.\n\nI couldn't") != null); // one blank line, one warning

    // A clean report is returned byte-identical, with no reallocation.
    const clean = try gpa.dupe(u8, "The palette is #2E5B3A.");
    const unflagged = va.flagText(gpa, clean, ask);
    defer gpa.free(unflagged);
    try std.testing.expectEqual(clean.ptr, unflagged.ptr);

    // flagReport preserves is_error in both directions: a disclaimed report is
    // not a failure, and a failed one does not become a success.
    const err_text = try gpa.dupe(u8, "cannot view the image");
    const out = va.flagReport(gpa, .{ .text = err_text, .is_error = true }, ask);
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    const ok_text = try gpa.dupe(u8, "cannot view the image");
    const ok = va.flagReport(gpa, .{ .text = ok_text, .is_error = false }, ask);
    defer gpa.free(ok.text);
    try std.testing.expect(!ok.is_error); // the work may still have value

    // rebased re-derives the path from a heap copy, so a background job's
    // decision does not point into the dead tool-call arena.
    const heap_prompt = try gpa.dupe(u8, "look at assets/palette.png");
    defer gpa.free(heap_prompt);
    const moved = ask.rebased(heap_prompt);
    try std.testing.expect(moved.isAsk());
    try std.testing.expectEqualStrings("assets/palette.png", moved.path);
    try std.testing.expect(!ask.rebased("no image here").isAsk());
}

test "#380 phase seat: a whole phase moves at once, and only an automatic one" {
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = undefined;
    withKeys(&keys, &.{"codex"});

    const image_tasks = [_][]const u8{ "summarize the notes", "read assets/palette.png" };
    const text_tasks = [_][]const u8{ "summarize the notes", "refactor util.zig" };
    const ladder_seat: route_phase.Seat = .{ .provider = deepseek(), .base_source = .ladder, .title = "sweep", .role = "sweep" };

    // Automatic (ladder) seat + an image somewhere in the phase → re-seated,
    // uniformly, and reported as vision-ask rather than learned-policy.
    const moved = va.phaseSeat(ladder_seat, &image_tasks, false);
    try std.testing.expect(moved.vision);
    try std.testing.expectEqualStrings("gpt-5.6-luna", moved.provider.model);
    try std.testing.expectEqualStrings("gpt-5.6-luna", moved.pin.?.model); // every worker gets it
    try std.testing.expectEqual(policy.Source.vision_ask, moved.sourceFor(false));
    try std.testing.expectEqual(policy.Source.vision_ask, moved.sourceFor(true)); // even with a genome override

    // No image in the phase → untouched.
    const still = va.phaseSeat(ladder_seat, &text_tasks, false);
    try std.testing.expect(!still.vision);
    try std.testing.expect(still.pin == null);
    try std.testing.expectEqual(policy.Source.ladder, still.sourceFor(false));

    // A seat a human chose (explicit --subagent-model) is never moved.
    const human: route_phase.Seat = .{ .provider = deepseek(), .base_source = .session_default };
    try std.testing.expect(!va.phaseSeat(human, &image_tasks, true).vision);

    // A seat that already sees images is left alone too.
    const seeing: route_phase.Seat = .{ .provider = codex(), .base_source = .ladder };
    try std.testing.expect(!va.phaseSeat(seeing, &image_tasks, false).vision);
}

test "#380 trace: the routing line carries source=vision-ask in #372's own format" {
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings(
        "shape=adhoc role=- tier=small resolved_model=gpt-5.6-luna source=vision-ask policy_or_genome_id=-",
        policy.formatDecision(&buf, .{ .tier = .small, .resolved_model = "gpt-5.6-luna", .source = .vision_ask }),
    );
    // The spelling is hyphenated like every other source, and distinct.
    try std.testing.expectEqualStrings("vision-ask", policy.Source.vision_ask.label());
    for ([_]policy.Source{ .explicit_pin, .persona, .learned_policy, .workflow_override, .session_default, .ladder }) |other|
        try std.testing.expect(!std.mem.eql(u8, other.label(), policy.Source.vision_ask.label()));
}

test "#380 does not disturb #292: the pin chain's own outcomes still arrive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = undefined;
    withKeys(&keys, &.{"codex"});

    // An effort pin rides through a vision ask untouched (independent axes).
    const ask = va.forSpawn(deepseek(), obj(a, "{\"effort\":\"max\"}"), false, .{}, "read a.png");
    try std.testing.expectEqual(pin_mod.EffortOutcome.pinned, ask.pin.effort_outcome);
    try std.testing.expect(ask.pin.effort.? == .max);
    try std.testing.expect(ask.rerouted);

    // An off-vocabulary tier is still reported as a typo, not swallowed.
    const typo = va.forSpawn(codex(), obj(a, "{\"tier\":\"cheap\"}"), false, .{}, "read a.png");
    try std.testing.expectEqual(pin_mod.Outcome.unknown_tier, typo.pin.outcome);
}
