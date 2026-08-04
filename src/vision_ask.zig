//! #380 — vision-aware subagent routing, and the report-time capability-
//! honesty flag.
//!
//! THE FAILURE THIS CLOSES. A root spawned "Analyze color palette screenshot"
//! naming a `.png` path. The worker's resolved model could not accept vision
//! input; it said so in its own report ("I couldn't open the image as a
//! vision input"), then improvised eight minutes of pixel quantization,
//! reached a WRONG palette, and returned status ok. The root accepted it and
//! briefed further work on the fabricated colors. One missing capability
//! check cascaded into a confidently wrong run.
//!
//! Two halves, deliberately independent — either alone leaves a hole:
//!
//!  1. SPAWN TIME (`seat`/`forSpawn`). A task whose text names a concrete
//!     image path is a VISION ASK. If the seat the routing chain produced
//!     cannot see images, an AUTOMATIC seat is re-routed to one that can, a
//!     HUMAN's pin is kept but flagged, and a session where no vision-capable
//!     model is reachable at all refuses the spawn (`blocked`) rather than
//!     handing the work to a model that will have to imagine the pixels.
//!
//!  2. REPORT TIME (`flagReport`). Capability disclaimers happen anyway — a
//!     vision model can still be handed a path it cannot read, and a pinned
//!     blind model runs by design. When the task was a vision ask AND the
//!     report carries one of a tight set of disclaimer markers, the tool
//!     result the ROOT sees gains a leading `[vision warning]` line. It is
//!     NOT marked is_error: the work may still have value; the point is only
//!     that the root can no longer mistake inference for observation.
//!
//! WHERE THE RE-ROUTE SITS IN THE PIN CHAIN. Below every human statement:
//!
//!     explicit spawn pin  >  persona frontmatter  >  explicit --subagent-model
//!       >  [vision ask]  >  learned policy (#372)  >  ladder (#291/#373)
//!       >  plain inherit-the-root
//!
//! `subagent_pin.forSpawnIn` runs FIRST and untouched — the #292 precedence,
//! the #372 learned rung and the sub-first flat-rate routing all resolve
//! exactly as they did. Only then, and only when the answer is blind to
//! images, does this module get to move an automatic seat. That is the same
//! discipline #372/#376 apply: evidence may improve a route the harness chose
//! for itself, never one a person chose.
//!
//! CANDIDATE ORDER mirrors subagent_pin's own: a logged-in flat-rate
//! subscription first (marginal cost zero outranks metered spend, and the
//! login is the user's standing consent for that vendor), then the base
//! provider's own catalog under the same `rungAffordable` ceiling every
//! automatic rung clears. Metered cross-provider routing is never done here —
//! that decision stays with --subagent-provider and its consent flag.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Provider = @import("provider.zig").Provider;
const vision = @import("vision.zig");
const pricing = @import("pricing.zig");
const bench_priors = @import("bench_priors.zig");
const selection = @import("subagent_selection.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const subagent_pin = @import("subagent_pin.zig");
const route_policy = @import("route_policy.zig");
const route_phase = @import("route_phase.zig");
const route_trace = @import("route_trace.zig");
const util = @import("util.zig");
const tools = @import("tools.zig");

pub const Source = route_policy.Source;

// ── Detection ──────────────────────────────────────────────────────────────
// The contract, stated once: a vision ask is a PLAUSIBLE PATH TOKEN whose
// final extension is one of png/jpg/jpeg/gif/webp, case-insensitive. Not "any
// mention of png" — `png compression`, `.pngx`, a bare `.png` and the glob
// `*.png` are all negatives, because none of them is a file a worker could be
// asked to look at. `http(s)://…/x.png` is a negative too, and that one is a
// judgement call worth spelling out: a remote URL is not a path this harness
// can turn into a vision block (vision.stageImagePath reads local files), so
// re-routing for one would spend a better model to fetch nothing.

pub const image_exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp" };

/// Bytes that may follow an extension without ending the token — `.pngx` is
/// an extension of its own, not a png.
fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Where an unquoted path token stops when scanned BACKWARD from its final
/// dot. `/`, `.`, `-`, `_`, `~` and `:` are deliberately absent so relative,
/// absolute and dotted paths survive intact; `*`/`?` are present so a glob
/// yields an empty stem and is rejected rather than treated as a file.
fn pathBreak(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', '"', '\'', '`', '(', '[', '{', '<', ')', ']', '}', '>', ',', ';', '=', '|', '*', '?', '!' => true,
        else => false,
    };
}

/// End index of a known image extension starting at `dot`, or null.
fn extEnd(text: []const u8, dot: usize) ?usize {
    const rest = text[dot + 1 ..];
    for (image_exts) |e| {
        if (rest.len < e.len or !std.ascii.eqlIgnoreCase(rest[0..e.len], e)) continue;
        const end = dot + 1 + e.len;
        // A word byte right after means this was never that extension.
        return if (end < text.len and wordByte(text[end])) null else end;
    }
    return null;
}

/// A quoted path may legitimately contain spaces (`"color palette.png"`).
/// Widened only when the SAME quote closes immediately after the extension —
/// otherwise ordinary prose containing a quote earlier in the line would
/// swallow the whole sentence.
fn quotedToken(text: []const u8, dot: usize, ext_end: usize) ?[]const u8 {
    if (ext_end >= text.len) return null;
    const q = text[ext_end];
    if (q != '"' and q != '\'') return null;
    var start = dot;
    while (start > 0 and text[start - 1] != q and text[start - 1] != '\n') start -= 1;
    if (start == 0 or start == dot or text[start - 1] != q) return null;
    return text[start..ext_end];
}

fn bareToken(text: []const u8, dot: usize, ext_end: usize) ?[]const u8 {
    var start = dot;
    while (start > 0 and !pathBreak(text[start - 1])) start -= 1;
    if (start == dot) return null; // no stem: a bare ".png", or a `*.png` glob
    return text[start..ext_end];
}

/// The first concrete image path `text` names, or null. Text-only by design:
/// the file may not exist yet (a worker is often asked to inspect something a
/// prior phase produced), and the spawn decision cannot wait on the disk.
pub fn imagePathIn(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '.')) |dot| {
        i = dot + 1;
        const ext_end = extEnd(text, dot) orelse continue;
        const token = quotedToken(text, dot, ext_end) orelse bareToken(text, dot, ext_end) orelse continue;
        if (std.mem.indexOf(u8, token, "://") != null) continue; // remote URL, not a local path
        return token;
    }
    return null;
}

// ── The spawn-time decision ────────────────────────────────────────────────

/// One spawn's vision decision, carried from the routing chain to the tool
/// result so both halves of #380 read the same facts.
pub const Ask = struct {
    /// The image path the task named; "" when it named none (not a vision
    /// ask, and every rule below is a no-op).
    path: []const u8 = "",
    /// #292's answer, untouched — this module never edits an outcome, only
    /// (possibly) the provider an AUTOMATIC seat resolved to.
    pin: subagent_pin.Resolved = .{},
    /// What the #372 route line reports as `source`.
    source: Source = .session_default,
    /// A vision-capable model was seated BECAUSE of the image.
    rerouted: bool = false,
    /// The seat is a human's pin and cannot see images: kept (a pin outranks
    /// evidence), but the run is flagged at both ends.
    pinned_blind: bool = false,
    /// No vision-capable model this spawn may take on its own is reachable.
    blocked: bool = false,
    /// A vision model the seat's provider DOES serve, which the automatic cost
    /// ceiling refused — "" when nothing vision-capable exists there at all.
    /// Kept apart so a blocked spawn says which of the two happened instead of
    /// claiming "none exists" when one does and merely costs more.
    pricier: []const u8 = "",

    pub fn isAsk(self: Ask) bool {
        return self.path.len > 0;
    }

    /// The tracer note this decision owes the user, or null when it made no
    /// decision worth recording.
    pub fn note(self: Ask) ?[]const u8 {
        if (self.blocked) return "vision ask refused: no vision-capable model is reachable with the current credentials";
        if (self.pinned_blind) return "vision warning: this task names an image and the pinned model cannot see images — the pin was kept, the report is flagged";
        if (self.rerouted) return "vision ask: re-routed an automatic seat to a vision-capable model";
        return null;
    }

    /// The same decision with `path` re-derived from `text` — a background
    /// spawn copies the prompt onto the heap and the tool call's arena dies
    /// with it, so the original slice would dangle.
    pub fn rebased(self: Ask, text: []const u8) Ask {
        var out = self;
        out.path = imagePathIn(text) orelse "";
        return out;
    }
};

/// The no-opinion Ask for a caller that only needs the report-time half
/// (workflow phase tasks, which take no per-task pins at all).
pub fn forPrompt(prompt: []const u8) Ask {
    return .{ .path = imagePathIn(prompt) orelse "" };
}

/// Did a HUMAN name this model? The only question a re-route asks, reduced
/// from #372's six-layer `Source`. `session_model_pinned` separates the two
/// meanings `session-default` carries: an explicit --subagent-model (human)
/// from a plain inherit-the-root (the harness's own default).
pub fn userChose(source: Source, session_model_pinned: bool) bool {
    return switch (source) {
        .explicit_pin, .persona => true,
        .session_default => session_model_pinned,
        .learned_policy, .ladder, .workflow_override, .vision_ask => false,
    };
}

/// Cheapest vision-capable model `provider_id` serves: its ladder rungs
/// bottom-up first (descend, never escalate — the #292 cost discipline), then
/// the live catalog's cheapest vision row. Unpriced rows sort as free, which
/// is what a flat-rate subscription model actually costs.
pub fn visionModelFor(provider_id: []const u8) ?[]const u8 {
    if (tier_ladder.forProvider(provider_id)) |l| {
        for ([_]?[]const u8{ l.small, l.mid, l.frontier }) |rung| {
            const name = rung orelse continue;
            if (!vision.visionModel(name)) continue;
            if (selection.modelForProvider(provider_id, name)) |m| return m;
        }
    }
    var best: ?[]const u8 = null;
    var best_cost: f64 = std.math.inf(f64);
    for (pricing.models()) |m| {
        if (!std.mem.eql(u8, m.provider, provider_id) or !vision.visionModel(m.name)) continue;
        const cost = if (pricing.priceFor(m.name)) |p| p.in + p.out else 0;
        if (cost < best_cost) {
            best = m.name;
            best_cost = cost;
        }
    }
    return best;
}

/// A vision-capable seat to replace `base` with, or null when none is
/// reachable. Sub-first, then provider-local under the cost ceiling; see the
/// module doc for why that order, and why nothing metered ever crosses a
/// provider boundary here.
pub fn visionSeat(base: Provider) ?Provider {
    if (bench_priors.g_keys) |keys| {
        var best: ?Provider = null;
        var best_score: f64 = -1;
        for (subagent_pin.subscription_providers) |sid| {
            if (std.mem.eql(u8, sid, base.id)) continue; // handled provider-locally below
            const name = visionModelFor(sid) orelse continue;
            const prov = keys.providerById(sid, name) catch continue; // not logged in → not a candidate
            const score = bench_priors.scoreFor(sid, name) orelse 0;
            if (best == null or score > best_score) {
                best = prov;
                best_score = score;
            }
        }
        if (best) |b| return b;
    }
    const local = visionModelFor(base.id) orelse return null;
    if (!subagent_pin.rungAffordable(base.model, local)) return null;
    return base.withModel(local);
}

/// The vision model `base`'s own provider serves that the cost ceiling
/// refused, or "". An automatic seat may never escalate spend (#292's rule,
/// and unpriced rows cannot PROVE they are not an escalation), but the user
/// can authorize it by name — so the refusal has to say which model that is.
pub fn blockedByCost(base: Provider) []const u8 {
    const name = visionModelFor(base.id) orelse return "";
    return if (subagent_pin.rungAffordable(base.model, name)) "" else name;
}

/// The whole spawn-time decision: run the #292/#372 chain unchanged, then ask
/// the vision question of its answer.
pub fn forSpawn(base: Provider, obj: std.json.ObjectMap, session_pinned: bool, cell: route_policy.Cell, prompt: []const u8) Ask {
    var ask: Ask = .{ .pin = subagent_pin.forSpawnIn(base, obj, !session_pinned, cell) };
    ask.source = if (ask.pin.provider != null) ask.pin.source else route_trace.sessionSource(session_pinned);
    ask.path = imagePathIn(prompt) orelse return ask;
    const current = ask.pin.provider orelse base;
    if (vision.visionModel(current.model)) return ask; // the seat already sees images
    if (userChose(ask.source, session_pinned)) {
        ask.pinned_blind = true;
        return ask;
    }
    ask.pin.provider = visionSeat(current) orelse {
        ask.blocked = true;
        ask.pricier = blockedByCost(current);
        return ask;
    };
    ask.source = .vision_ask;
    ask.rerouted = true;
    return ask;
}

/// forSpawn plus every note and trace line the decision owes — one call
/// because subagent.zig sits at the 600-line cap. The #372 route line is
/// emitted here so a vision re-route reports `source=vision-ask` on exactly
/// the same three sinks (tracer, trajectory, --json) as every other seat.
pub fn seat(ctx: tools.ToolCtx, base: Provider, obj: std.json.ObjectMap, cell: route_policy.Cell, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8) Ask {
    const ask = forSpawn(base, obj, ctx.subagent_provider != null, cell, prompt);
    if (ctx.tracer) |tr| {
        if (ask.pin.outcome != .none) tr.note("subagent", ask.pin.outcome.describe());
        if (ask.pin.effort_outcome != .none) tr.note("subagent", ask.pin.effort_outcome.describe());
        if (ask.note()) |n| tr.note("vision", n);
    }
    route_trace.emitSpawnProvider(ctx.io, ctx.tracer, label, ask.pin.provider orelse base, cell, ask.source, sys_override, niche);
    return ask;
}

/// #376's phase seat, asked the same question. A phase is re-seated as a
/// WHOLE (every worker in it keeps the one model #290 requires) when any of
/// its task prompts names an image and the seat the phase would otherwise
/// have taken is blind to images. A phase whose seat a human chose is left
/// alone, and — unlike the `subagent` tool — a phase with no vision model
/// available is NOT refused: it runs and relies on the report-time flag, so
/// one image-shaped task cannot abort a whole workflow.
pub fn phaseSeat(base: route_phase.Seat, prompts: []const []const u8, session_pinned: bool) route_phase.Seat {
    var out = base;
    if (vision.visionModel(out.provider.model)) return out;
    if (userChose(out.sourceFor(false), session_pinned)) return out;
    for (prompts) |p| {
        if (imagePathIn(p) == null) continue;
        const better = visionSeat(out.provider) orelse return out;
        out.pin = better;
        out.provider = better;
        out.vision = true;
        return out;
    }
    return out;
}

// ── The report-time honesty flag ───────────────────────────────────────────

/// Capability disclaimers, kept TIGHT on purpose: every entry names the image
/// explicitly, so ordinary prose about images ("the image shows three greens")
/// cannot trip it. Curly-apostrophe spellings are listed separately rather
/// than normalized — a model emits one or the other and both must match.
pub const disclaimers = [_][]const u8{
    "couldn't open the image",
    "couldn\u{2019}t open the image",
    "could not open the image",
    "can't view the image",
    "can\u{2019}t view the image",
    "cannot view the image",
    "unable to see the image",
    "not able to view the image",
    "as a vision input",
};

pub fn disclaimed(report: []const u8) bool {
    for (disclaimers) |d| if (util.indexOfIgnoreCase(report, d) != null) return true;
    return false;
}

pub const disclaimer_warning = "[vision warning] worker disclaimed image-viewing capability — visual conclusions below are inferred, not seen.";
pub const pinned_warning = "[vision warning] this task names an image and the worker's pinned model cannot accept vision input — visual conclusions below are inferred, not seen.";

/// The warning line this report earns, or null. Both arms require the task to
/// have BEEN a vision ask: a disclaimer in a report about anything else is
/// prose, not a capability admission.
pub fn warningFor(ask: Ask, report: []const u8) ?[]const u8 {
    if (!ask.isAsk()) return null;
    if (disclaimed(report)) return disclaimer_warning;
    return if (ask.pinned_blind) pinned_warning else null;
}

/// Prepend the warning to a gpa-owned report, transferring ownership. Never
/// fails: on OOM the report is returned unflagged rather than lost, because a
/// missing warning is a smaller harm than a missing report.
pub fn flagText(gpa: Allocator, text: []u8, ask: Ask) []u8 {
    const line = warningFor(ask, text) orelse return text;
    const out = std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ line, text }) catch return text;
    gpa.free(text);
    return out;
}

/// flagText over a whole ToolOutput. `is_error` is carried through unchanged
/// — a disclaimed report is not a failed one.
pub fn flagReport(gpa: Allocator, out: tools.ToolOutput, ask: Ask) tools.ToolOutput {
    var flagged = out;
    flagged.text = flagText(gpa, out.text, ask);
    return flagged;
}

/// The fast-fail a blocked vision ask returns instead of spawning. Names the
/// reason and every way to fix it, because the alternative — the run that
/// motivated #380 — is a text-only worker inventing what it cannot see.
pub fn blockMessage(gpa: Allocator, ask: Ask) ![]u8 {
    if (ask.pricier.len > 0) return std.fmt.allocPrint(
        gpa,
        "subagent not spawned: this task references an image ({s}) and the only vision-capable model this provider serves ('{s}') is not provably cheaper than the model this worker would have used — an automatic route never escalates spend. Authorize it explicitly by passing model:\"{s}\" on the subagent call, or log in to a flat-rate vision subscription (`graff login codex`, `graff login kimi`). A text-only worker would have to infer the pixels rather than see them, so this spawn is refused instead of returning a confident guess.",
        .{ ask.path, ask.pricier, ask.pricier },
    );
    return std.fmt.allocPrint(
        gpa,
        "subagent not spawned: this task references an image ({s}) and no vision-capable model is reachable with the current credentials. A text-only worker would have to infer the pixels rather than see them, so this spawn is refused instead of returning a confident guess. Fix it with `graff login codex`, `graff login kimi`, `graff login anthropic`, or by setting OPENAI_API_KEY / ANTHROPIC_API_KEY / GEMINI_API_KEY, then retry. Vision-capable families: claude-*, gpt-5*/gpt-4*, gemini-*, grok-4*, kimi/k*. If the image is incidental, drop the path from the task and re-spawn.",
        .{ask.path},
    );
}

test {
    _ = @import("vision_ask_tests.zig");
}
