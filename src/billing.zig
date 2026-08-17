//! Which billing class one provider SEAT falls into (#471).
//!
//! Split out of pricing.zig because the answer is not a property of a price
//! sheet. `pricing.priceFor` is keyed by model NAME alone — `price_overlay` is
//! rebuilt from the models.dev sheet in ~/.codegraff/models.json, which has no
//! provider column — so `gpt-5.6-luna` carries the same list price whether it
//! is reached through a metered OpenAI key or a flat-rate Codex login. Two
//! facts the sheet cannot see decide the class:
//!
//!   1. the PROVIDER's declared plan (`ProviderSpec.sub_login`), and
//!   2. HOW this session's credential was obtained
//!      (`Keys.CredentialSource` — `.login` vs `.environment`/`.stored`).
//!
//! It is the login that is flat-rate, not the vendor. `graff login xai` buys a
//! SuperGrok plan; `XAI_API_KEY` is metered api.x.ai access. Same provider,
//! same model, different bill — so classification takes the source, and a
//! caller that only knows the provider id gets the metered answer.
//!
//! WHY THIS EXISTS AT ALL. Before #471 the classifier was a hardcoded id list
//! (`provider_id == "codex" or "kimi"`) living in pricing.zig, and it was the
//! THIRD such list to disagree with the other two: `ProviderSpec.LoginKind`
//! knew about codegraff/codex/kimi but not xai, `oauth.refreshOAuthKey` knew
//! about kimi/xai/codex but not codegraff, and the billing list knew about
//! codex/kimi only. The result was that xAI OAuth sessions — a real
//! device-code flow since oauth.zig's xaiLogin — were billed to /cost at grok
//! list price against a subscription the user had already paid for. Declaring
//! it on the spec makes a new subscription provider one field instead of an id
//! remembered in N files.

const std = @import("std");
const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");

pub const Billing = pricing.Billing;
pub const CredentialSource = provider_mod.Keys.CredentialSource;

/// True when a `/login` on this provider buys a flat-rate plan. Reads the
/// declaration on the provider spec; an unknown id (a workspace router) is
/// metered, which is the safe direction — it over-reports cost rather than
/// hiding spend.
pub fn subscriptionLogin(provider_id: []const u8) bool {
    for (provider_mod.provider_specs) |spec|
        if (std.mem.eql(u8, spec.id, provider_id)) return spec.sub_login;
    if (provider_mod.additional_router) |spec|
        if (std.mem.eql(u8, spec.id, provider_id)) return spec.sub_login;
    return false;
}

/// A seat served from THIS MACHINE — a local OpenAI-compatible server (LM
/// Studio :1234, mlx-lm :8080). The rule mirrors `keys_cli.isLocalUrl`, which
/// this module deliberately does not import: keys_cli is the interactive key
/// CLI and billing is a leaf.
fn localSeat(provider_id: []const u8) bool {
    const spec = provider_mod.specFor(provider_id) orelse return false;
    return std.mem.indexOf(u8, spec.url, "127.0.0.1") != null or
        std.mem.indexOf(u8, spec.url, "localhost") != null;
}

/// What a turn on this seat COSTS THE USER, in the terms they think in.
/// `Billing` answers "does /cost add a number", which is the accountant's
/// question; this answers "am I about to spend my plan, my gateway balance, or
/// my metered key", which is the one a model picker has to answer BEFORE the
/// turn. The same `gpt-5.6` reached through codex, codegraff and openai is
/// three different bills and used to render as three identical rows.
pub const CostClass = enum {
    /// Flat-rate subscription login: ChatGPT plan, SuperGrok, Kimi.
    plan,
    /// The codegraff gateway, drawn against a credit balance.
    credits,
    /// A metered vendor key — the meter runs per token.
    api,
    /// A server on this machine. No bill exists.
    local,

    pub fn badge(self: CostClass) []const u8 {
        return switch (self) {
            .plan => "plan",
            .credits => "credits",
            .api => "api",
            .local => "local",
        };
    }
};

/// Classify a seat. Where a credential exists it decides — the same discipline
/// `forSeat` uses, because it is the LOGIN that is flat-rate and not the
/// vendor. A seat with no credential yet falls back to the provider table and
/// there advertises what signing in would buy, which is the only useful thing
/// to say on a row the user cannot pick yet.
pub fn costFor(provider_id: []const u8, source: CredentialSource) CostClass {
    if (localSeat(provider_id)) return .local;
    if (std.mem.eql(u8, provider_id, "codegraff")) return .credits;
    if (!subscriptionLogin(provider_id)) return .api;
    return switch (source) {
        .login, .none => .plan,
        .environment, .stored, .session => .api,
    };
}

/// The billing class of one API call on this seat.
pub fn forSeat(provider_id: []const u8, model: []const u8, source: CredentialSource) Billing {
    if (source == .login and subscriptionLogin(provider_id)) return .sub;
    return if (pricing.priceFor(model) != null) .priced else .unpriced;
}

/// The class of a resolved `Provider`, which already carries both inputs.
pub fn forProvider(p: provider_mod.Provider) Billing {
    return forSeat(p.id, p.model, p.source);
}

/// A seat that costs nothing per token, so no cost ceiling applies to it: the
/// #292 rung check exists to stop an AUTOMATIC ladder rung from spending more
/// than the model the user chose, and on a flat-rate plan every rung spends
/// the same nothing. Ranking such a seat by score-per-dollar is meaningless
/// (and divides by zero); callers should rank by capability alone.
pub fn freeAtTheMargin(p: provider_mod.Provider) bool {
    return forProvider(p) == .sub;
}

test "a flat-rate login and a metered key on the same seat bill differently (#471)" {
    // The regression: xAI OAuth was billed at grok list price because the
    // classifier keyed on provider id alone and xai wasn't on its list.
    try std.testing.expectEqual(Billing.sub, forSeat("xai", "grok-4.3", .login));
    try std.testing.expectEqual(Billing.priced, forSeat("xai", "grok-4.3", .environment));

    // Same discipline for the two providers that were already classified: the
    // subscription is the login, so KIMI_API_KEY is metered per token.
    try std.testing.expectEqual(Billing.sub, forSeat("kimi", "kimi-k2.7", .login));
    try std.testing.expectEqual(Billing.priced, forSeat("kimi", "kimi-k2.7", .environment));

    // codex has no usable env key (env_key is the CODEX_DISABLED sentinel), so
    // it is only ever reached by login — but the source still gates it.
    try std.testing.expectEqual(Billing.sub, forSeat("codex", "gpt-5.5", .login));

    // A metered vendor's login (none exists today) would still be priced, and
    // the codegraff gateway's device login draws on credits, not a plan.
    try std.testing.expectEqual(Billing.priced, forSeat("anthropic", "claude-sonnet-4-6", .login));
    try std.testing.expectEqual(Billing.priced, forSeat("codegraff", "claude-sonnet-4-6", .login));

    // Unpriced stays unpriced: no plan, no price row.
    try std.testing.expectEqual(Billing.unpriced, forSeat("openai", "mystery-model", .environment));
}

test "subscriptionLogin is declared on the spec, not a hardcoded id list" {
    // Every provider whose spec says sub_login must also HAVE a login flow;
    // a plan you cannot sign into would silently zero out real spend.
    for (provider_mod.provider_specs) |spec| {
        if (!spec.sub_login) continue;
        try std.testing.expect(spec.login != .api_key);
        try std.testing.expect(subscriptionLogin(spec.id));
    }
    // And the inverse guard that caught this bug: every device login is
    // classified one way or the other on purpose, never by omission.
    for (provider_mod.provider_specs) |spec| {
        if (spec.login == .api_key) continue;
        const declared = spec.sub_login or std.mem.eql(u8, spec.id, "codegraff");
        try std.testing.expect(declared);
    }
    try std.testing.expect(!subscriptionLogin("no-such-provider"));
}

test "freeAtTheMargin follows the credential, not the vendor" {
    const seat = struct {
        fn p(id: []const u8, model: []const u8, source: CredentialSource) provider_mod.Provider {
            return .{ .id = id, .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = model, .context = 0, .source = source };
        }
    }.p;
    try std.testing.expect(freeAtTheMargin(seat("xai", "grok-4.3", .login)));
    try std.testing.expect(!freeAtTheMargin(seat("xai", "grok-4.3", .environment)));
    try std.testing.expect(!freeAtTheMargin(seat("anthropic", "claude-opus-4-8", .environment)));
}

test "costFor: the picker's badge follows the credential, then the provider" {
    // The user's complaint, encoded: codex is a ChatGPT plan, the codegraff
    // gateway spends credits, and a raw OpenAI key runs a meter — three
    // different bills that used to render as the same bare model name.
    try std.testing.expectEqual(CostClass.plan, costFor("codex", .login));
    try std.testing.expectEqual(CostClass.credits, costFor("codegraff", .login));
    try std.testing.expectEqual(CostClass.credits, costFor("codegraff", .environment));
    try std.testing.expectEqual(CostClass.api, costFor("openai", .environment));
    try std.testing.expectEqual(CostClass.api, costFor("anthropic", .stored));

    // Same provider, two credentials, two answers — `graff login xai` buys a
    // plan, XAI_API_KEY buys metered api.x.ai.
    try std.testing.expectEqual(CostClass.plan, costFor("xai", .login));
    try std.testing.expectEqual(CostClass.api, costFor("xai", .environment));
    try std.testing.expectEqual(CostClass.plan, costFor("kimi", .login));
    try std.testing.expectEqual(CostClass.api, costFor("kimi", .stored));

    // localhost is nobody's bill.
    try std.testing.expectEqual(CostClass.local, costFor("lmstudio", .environment));
    try std.testing.expectEqual(CostClass.local, costFor("mlx", .none));

    // No credential: the row still says what signing in would buy.
    try std.testing.expectEqual(CostClass.plan, costFor("codex", .none));
    try std.testing.expectEqual(CostClass.api, costFor("openai", .none));

    // An id nothing knows is metered, the same safe direction `forSeat` takes.
    try std.testing.expectEqual(CostClass.api, costFor("no-such-provider", .login));
}

test "costFor agrees with forSeat wherever both have an opinion" {
    // Two classifiers over one fact is how #471 happened. They answer
    // different questions, but a plan seat must never be a metered badge.
    for (provider_mod.provider_specs) |spec| {
        for ([_]CredentialSource{ .none, .environment, .login, .stored, .session }) |src| {
            const class = costFor(spec.id, src);
            const sub = forSeat(spec.id, "definitely-not-in-the-price-sheet", src) == .sub;
            if (sub) try std.testing.expectEqual(CostClass.plan, class);
            if (class == .plan) try std.testing.expect(sub or src == .none);
        }
    }
}

test "every CostClass badge is short, distinct and non-empty" {
    // The badge is a table column in two surfaces; an empty or oversized one
    // silently breaks alignment rather than failing anywhere.
    var seen: [4][]const u8 = undefined;
    var n: usize = 0;
    for ([_]CostClass{ .plan, .credits, .api, .local }) |c| {
        const b = c.badge();
        try std.testing.expect(b.len > 0 and b.len <= 7);
        for (seen[0..n]) |prev| try std.testing.expect(!std.mem.eql(u8, prev, b));
        seen[n] = b;
        n += 1;
    }
}
