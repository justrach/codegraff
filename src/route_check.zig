//! `graff route <model>…` — dry-run provider seating (#377 follow-up).
//!
//! Answers "which provider, which native spelling, and which billing class
//! would this model land on?" WITHOUT making an API call: the same key
//! resolution as a real session (startup.resolveKeys), the same seat chooser
//! (Keys.providerFor — including the #377 family-alias phase that seats
//! `kimi-k3` on a logged-in kimi instead of the gateway), and the usage
//! footer's own billing classifier (pricing.billingFor). Dispatched from the
//! `graff models`/`route` block in startup.runSubcommand, so the live catalog
//! caches are already loaded and gateway spellings resolve exactly as they
//! would in-session.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pricing = @import("pricing.zig");
const billing = @import("billing.zig");
const report = @import("route_report.zig");
const provider_mod = @import("provider.zig");
const startup_keys = @import("startup_keys.zig");

pub const Seat = struct {
    pid: []const u8,
    model: []const u8,
    billing: pricing.Billing,
    source: provider_mod.Keys.CredentialSource,
};

pub const Answer = union(enum) {
    unknown,
    no_credential: []const u8, // the resolved catalog name nobody keyed serves
    seat: Seat,
};

/// Pure resolution shared by the command and its tests: catalog-name
/// resolution, then the real provider seat.
pub fn seatFor(keys: provider_mod.Keys, query: []const u8) Answer {
    // A provider-qualified model is an exact seat in --model and /model.
    // Keep this dry run on the same route instead of resolving its bare name
    // again, which could choose another credential for a shared model.
    const qualified = startup_keys.qualifiedProvider(keys, query) catch |err| return switch (err) {
        error.UnknownModel => .unknown,
        error.MissingKey => .{ .no_credential = query },
    };
    if (qualified) |p| return answerFor(p);
    const resolved = pricing.resolveModelName(keys, query) orelse return .unknown;
    const p = keys.providerFor(resolved) catch return .{ .no_credential = resolved };
    return answerFor(p);
}

fn answerFor(p: provider_mod.Provider) Answer {
    return .{ .seat = .{
        .pid = p.id,
        .model = p.model,
        .billing = billing.forProvider(p),
        .source = p.source,
    } };
}

test "qualified route keeps the selected provider and credential" {
    const original = pricing.active_model_table;
    defer pricing.active_model_table = original;
    pricing.active_model_table = &.{
        .{ .provider = "codex", .name = "shared-route-fixture", .context = 270_000 },
        .{ .provider = "openai", .name = "shared-route-fixture", .context = 270_000 },
    };
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    try std.testing.expect(keys.set("codex", "login-token", .login));
    try std.testing.expect(keys.set("openai", "metered-token", .session));

    const codex = seatFor(keys, "codex/shared-route-fixture");
    try std.testing.expectEqualStrings("codex", codex.seat.pid);
    try std.testing.expectEqual(pricing.Billing.sub, codex.seat.billing);
    const openai = seatFor(keys, "openai/shared-route-fixture");
    try std.testing.expectEqualStrings("openai", openai.seat.pid);
    try std.testing.expect(openai.seat.billing != .sub);

    var openai_only: provider_mod.Keys = .{ .values = @splat(null) };
    try std.testing.expect(openai_only.set("openai", "metered-token", .session));
    try std.testing.expect(seatFor(openai_only, "codex/shared-route-fixture") == .no_credential);
    try std.testing.expect(seatFor(keys, "codex/not-a-model") == .unknown);
}

pub fn billingLabel(b: pricing.Billing) []const u8 {
    return switch (b) {
        .sub => "subscription, flat-rate",
        .priced => "metered",
        .unpriced => "unpriced (gateway/license)",
    };
}

pub fn command(io: Io, gpa: Allocator, arena: Allocator, environ_map: anytype, sub_args: []const []const u8) !void {
    var obuf: [8 * 1024]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;
    const rk = try @import("startup.zig").resolveKeys(io, gpa, arena, environ_map, null, null);
    if (sub_args.len == 0) {
        const d = rk.default_provider;
        try out.print("session default: {s}/{s} · auth: {s} · billing: {s}\n\n", .{ d.id, d.model, d.source.label(), billingLabel(billing.forProvider(d)) });
        // #471: which providers are actually reachable, what each bills, and
        // the worker tiers it offers — the question that decides where every
        // unpinned subagent lands.
        const home = @import("keys_cli.zig").homeEnv(environ_map) orelse "";
        try report.write(out, report.rows(io, arena, rk.keys, home));
        try out.flush();
        return;
    }
    for (sub_args) |q| {
        switch (seatFor(rk.keys, q)) {
            .unknown => try out.print("{s} → ✗ unknown model — run `graff models refresh` or see `graff models`\n", .{q}),
            .no_credential => |m| try out.print("{s} → ✗ '{s}' is catalogued, but no logged-in/keyed provider serves it — `graff login <provider>` or `graff key set`\n", .{ q, m }),
            .seat => |s| {
                try out.print("{s} → {s}/{s} · auth: {s} · billing: {s}", .{ q, s.pid, s.model, s.source.label(), billingLabel(s.billing) });
                if (s.billing == .priced) {
                    if (pricing.priceFor(s.model)) |pr| try out.print(" (${d}/{d} per 1M)", .{ pr.in, pr.out });
                }
                try out.writeAll("\n");
            },
        }
    }
    try out.flush();
}

test "seatFor: family-alias spelling seats the sub, exact names hold, unknown misses" {
    // Sources matter since #471: the flat-rate plan is the LOGIN, so a seat
    // only bills as .sub when its credential came from one.
    const all = provider_mod.Keys{ .values = @splat("k"), .sources = @splat(.login) };
    const kk = seatFor(all, "kimi-k3");
    try std.testing.expectEqualStrings("kimi", kk.seat.pid);
    try std.testing.expectEqualStrings("k3", kk.seat.model);
    try std.testing.expectEqual(pricing.Billing.sub, kk.seat.billing);
    const sol = seatFor(all, "gpt-5.6-sol");
    try std.testing.expectEqualStrings("codex", sol.seat.pid);
    try std.testing.expectEqual(pricing.Billing.sub, sol.seat.billing);
    try std.testing.expect(seatFor(all, "totally-unknown-zzz") == .unknown);

    // The same seat reached with KIMI_API_KEY is billed, not free. (Whether it
    // lands on .priced or .unpriced is the price sheet's business; what must
    // never happen is a metered key being written off as a subscription.)
    const keyed = provider_mod.Keys{ .values = @splat("k"), .sources = @splat(.environment) };
    try std.testing.expect(seatFor(keyed, "kimi-k3").seat.billing != .sub);
}

test "seatFor: catalogued model with no serving credential reports no_credential, not a gateway seat" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    pricing.active_model_table = &.{.{ .provider = "codex", .name = "native-only-fixture", .context = 270_000 }};
    var values: [provider_mod.provider_specs.len]?[]const u8 = @splat(null);
    for (provider_mod.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "codegraff")) values[i] = "k";
    }
    const only_gateway = provider_mod.Keys{ .values = values };
    // native-only-fixture is catalogued only under codex (#294): with just a gateway
    // key it must surface as a credential problem, not silently seat there.
    const a = seatFor(only_gateway, "native-only-fixture");
    try std.testing.expectEqualStrings("native-only-fixture", a.no_credential);
}
