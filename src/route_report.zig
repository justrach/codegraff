//! `graff route` with no model: which providers you can actually reach right
//! now, what each one bills, and the worker tiers it offers (#471).
//!
//! The gap this fills: `graff models` lists the catalog and `graff route
//! <model>` resolves ONE seat, so nothing answered "what am I logged into,
//! and which of those cost me money?". That question decides where every
//! unpinned subagent lands, and it was only answerable by reading traces.
//!
//! THE COLLISION IT EXISTS TO SURFACE. A provider can hold two credentials at
//! once — `KIMI_API_KEY` *and* a `graff login kimi` plan, `XAI_API_KEY` *and*
//! SuperGrok. `Keys` has one slot per provider and startup.resolveKeys fills
//! it from the environment FIRST, loading a login only `if (value == null)`.
//! So the metered key silently wins and every call bills per token against a
//! subscription already paid for — the expensive branch, chosen invisibly.
//! Detecting it needs a credential probe that does NOT consume the login, so
//! `loginOnDisk` only stats the file: no refresh, no network, no spend.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const provider_mod = @import("provider.zig");
const billing_mod = @import("billing.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const credential_store = @import("credential_store.zig");
const credential_failover = @import("credential_failover.zig");
const oauth_helpers = @import("oauth_helpers.zig");
const pricing = @import("pricing.zig");

pub const Row = struct {
    id: []const u8,
    source: provider_mod.Keys.CredentialSource,
    billing: pricing.Billing,
    frontier: []const u8 = "",
    mid: []const u8 = "",
    small: []const u8 = "",
    /// A saved login exists on disk for this provider, whatever won the slot.
    login_available: bool = false,
    /// A metered credential is parked behind the plan, unused (#471).
    key_standing_by: bool = false,
    /// The plan ran out mid-session and the parked key took over.
    failed_over: bool = false,
};

/// Does a saved device-login credential exist for `spec`? File presence only —
/// never a refresh, so listing providers cannot cost a network round trip or
/// rotate a token out from under a running session.
pub fn loginOnDisk(io: Io, arena: Allocator, home: []const u8, spec: provider_mod.ProviderSpec) bool {
    if (home.len == 0) return false;
    const path = switch (spec.login) {
        .api_key => return false,
        .kimi_device => credential_store.oauthPath(arena, home, ".kimi"),
        .xai_device => credential_store.oauthPath(arena, home, ".xai"),
        .codex_device => blk: {
            const dir = oauth_helpers.codexHomeDir(arena, home) orelse return false;
            break :blk std.fmt.allocPrint(arena, "{s}/auth.json", .{dir}) catch return false;
        },
        .codegraff_device => std.fmt.allocPrint(arena, "{s}/.simple-harness-codegraff.json", .{home}) catch return false,
    };
    if (path.len == 0) return false;
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn rungOr(name: ?[]const u8) []const u8 {
    return name orelse "";
}

/// One row per provider that has ANY credential. A provider you cannot reach
/// is left out: the question is what is available, not what exists.
pub fn rows(io: Io, arena: Allocator, keys: provider_mod.Keys, home: []const u8) []const Row {
    var out: std.ArrayList(Row) = .empty;
    for (provider_mod.provider_specs) |spec| {
        const source = keys.source(spec.id);
        const on_disk = loginOnDisk(io, arena, home, spec);
        if (source == .none and !on_disk) continue;
        const model = pricing.providerDefaultModel(spec.id, spec.default_model);
        var row: Row = .{
            .id = spec.id,
            .source = source,
            .billing = billing_mod.forSeat(spec.id, model, source),
            .login_available = on_disk,
            .key_standing_by = credential_failover.standingBy(spec.id),
            .failed_over = credential_failover.promoted(spec.id),
        };
        if (tier_ladder.forProvider(spec.id)) |l| {
            row.frontier = l.frontier;
            row.mid = rungOr(l.mid);
            row.small = rungOr(l.small);
        }
        out.append(arena, row) catch break;
    }
    return out.items;
}

pub fn write(out: *Io.Writer, list: []const Row) !void {
    if (list.len == 0) {
        try out.writeAll("no provider credentials found — `graff login <provider>` or `graff key set`\n");
        return;
    }
    try out.writeAll("provider     auth           billing        frontier / mid / small\n");
    for (list) |r| {
        try out.print("{s: <12} {s: <14} {s: <14} ", .{ r.id, r.source.label(), billingWord(r.billing) });
        if (r.frontier.len == 0) {
            try out.writeAll("(no tier ladder — workers inherit the root model)\n");
        } else {
            try out.print("{s} / {s} / {s}\n", .{ r.frontier, dash(r.mid), dash(r.small) });
        }
    }
    var noted = false;
    for (list) |r| {
        if (r.failed_over) {
            noted = true;
            try out.print("\n! {s}: the plan ran out of quota this session, so its API key took over — billing PER TOKEN now.\n", .{r.id});
        } else if (r.key_standing_by) {
            noted = true;
            try out.print("\n· {s}: plan in use; its API key is parked and takes over only if the plan runs out.\n", .{r.id});
        }
    }
    if (!noted) try out.writeAll("\nusage: graff route <model> [<model>…] — dry-run one model's seat (no API call)\n");
}

fn dash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}

fn billingWord(b: pricing.Billing) []const u8 {
    return switch (b) {
        .sub => "subscription",
        .priced => "metered",
        .unpriced => "unpriced",
    };
}

test "#471 the plan is in use and the metered key is reported as reserve" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Both credentials exist. The plan won the slot; the key is parked. What
    // the user must be able to see is that the reserve exists and is NOT
    // costing them anything yet.
    const reserved: Row = .{ .id = "kimi", .source = .login, .billing = .sub, .frontier = "k3", .mid = "k3", .login_available = true, .key_standing_by = true };
    var buf: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(a, &buf);
    try write(&w.writer, &.{reserved});
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "parked") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "subscription") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "k3 / k3 / -") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "PER TOKEN") == null); // not billing yet

    // After the plan runs dry the same provider must say so loudly: billing
    // silently changed, which is the one thing the user cannot infer.
    const spent: Row = .{ .id = "kimi", .source = .environment, .billing = .priced, .frontier = "k3", .mid = "k3", .login_available = true, .failed_over = true };
    var buf2: std.ArrayList(u8) = .empty;
    var w2 = std.Io.Writer.Allocating.fromArrayList(a, &buf2);
    try write(&w2.writer, &.{spent});
    try std.testing.expect(std.mem.indexOf(u8, w2.written(), "PER TOKEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2.written(), "ran out of quota") != null);

    // A plain provider with no reserve gets no note at all, and one with no
    // ladder says so rather than printing empty columns.
    const bare: Row = .{ .id = "xai", .source = .login, .billing = .sub, .login_available = true };
    var buf3: std.ArrayList(u8) = .empty;
    var w3 = std.Io.Writer.Allocating.fromArrayList(a, &buf3);
    try write(&w3.writer, &.{bare});
    try std.testing.expect(std.mem.indexOf(u8, w3.written(), "no tier ladder") != null);
    try std.testing.expect(std.mem.indexOf(u8, w3.written(), "parked") == null);
}

test "#471 loginOnDisk never reports a login for an api_key-only provider" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (provider_mod.provider_specs) |spec| {
        if (spec.login != .api_key) continue;
        try std.testing.expect(!loginOnDisk(std.testing.io, a, "/nonexistent-home", spec));
    }
    // …and a device-login provider with no credential file is simply absent,
    // not an error: `graff route` must work before you have logged into
    // anything at all.
    for (provider_mod.provider_specs) |spec| {
        if (spec.login == .api_key) continue;
        try std.testing.expect(!loginOnDisk(std.testing.io, a, "/nonexistent-home", spec));
    }
}
