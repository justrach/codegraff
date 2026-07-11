//! DGM score-channel signing + prompt/model fingerprinting: the system-prompt
//! fingerprint, the MAP-Elites provider-class capability tier, and the HMAC
//! signing of score records (canonical message + key custody). Split out of
//! main.zig (600-line goal). Self-contained (std + pricing.priceFor); owns the
//! g_score_key / g_run_id session globals. main aliases the pure fns back and
//! mod-qualifies the two globals.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const pricing = @import("pricing.zig");
const priceFor = pricing.priceFor;

/// Short stable fingerprint of a system prompt (first 8 bytes of SHA-256,
/// hex): equal hashes along a trajectory edge mean the prompt didn't change.
pub fn promptFingerprint(prompt: []const u8) [16]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(prompt, &d, .{});
    return std.fmt.bytesToHex(d[0..8].*, .lower);
}

/// Capability tier for the running model — the MAP-Elites grid's provider-class
/// axis (docs/hyperagents.md §9). A curated table maps known model families to a
/// tier (price alone is a poor capability proxy: a small model can be premium-
/// priced and a frontier model cheap), then falls back to the models.dev output
/// price graff already carries, then to "mid". Returns "frontier" | "mid" | "small".
pub fn providerClass(model: []const u8) []const u8 {
    const Tier = struct { needle: []const u8, tier: []const u8 };
    // Most-specific first; small markers precede the families they sit in so
    // e.g. "...-flash" beats "gemini-3" and "deepseek-v4-flash" beats "deepseek-v4".
    const known = [_]Tier{
        .{ .needle = "haiku", .tier = "small" },
        .{ .needle = "flash", .tier = "small" },
        .{ .needle = "-mini", .tier = "small" }, // -mini suffix, not "minimax"/"gemini"
        .{ .needle = "lite", .tier = "small" },
        .{ .needle = "nano", .tier = "small" },
        .{ .needle = "opus", .tier = "frontier" },
        .{ .needle = "gpt-5", .tier = "frontier" },
        .{ .needle = "deepseek-v4", .tier = "frontier" },
        .{ .needle = "grok-4", .tier = "frontier" },
        .{ .needle = "glm-5", .tier = "frontier" },
        .{ .needle = "kimi-k2", .tier = "frontier" },
        .{ .needle = "minimax-m", .tier = "frontier" },
        .{ .needle = "mimo-v2.5-pro", .tier = "frontier" },
        .{ .needle = "fugu", .tier = "frontier" },
        .{ .needle = "gemini-3", .tier = "frontier" },
        .{ .needle = "sonnet", .tier = "mid" },
    };
    for (known) |k| if (std.ascii.indexOfIgnoreCase(model, k.needle) != null) return k.tier;
    // Unknown family: bucket by models.dev output price ($/1M output tokens).
    if (priceFor(model)) |p| {
        if (p.out >= 10) return "frontier";
        if (p.out >= 2) return "mid";
        return "small";
    }
    return "mid";
}
// ── Score-channel signing (DGM fitness integrity, Step 0) ──────────────────
//
// The trajectory archive is the DGM's fitness ledger, and it lives in cwd —
// so a forged `{"kind":"score",...}` row appended via write_file (cwd is
// inside confinedPath) or `echo >>` manufactures fitness AND parent_sha
// lineage that parent selection then rewards. Signing makes forged rows
// detectable: every score record the harness writes carries an HMAC over its
// fields, keyed by a secret the evolving agent's tools can't reach.
//
// Key custody: GRAFF_SCORE_KEY_FILE names a key file OUTSIDE cwd. The env var
// holds only the path (not the secret), and the file is unreadable by a
// subagent — file tools are confined to cwd, and subagent bash is cwd-locked
// with no redirection. The root agent / --yolo is the trusted orchestrator
// boundary (it could read any file anyway). Readers (dgm_loop.py load_archive,
// the harness-telemetry worker) recompute the HMAC and reject unsigned rows.

/// Loaded once in main() from GRAFF_SCORE_KEY_FILE; null → unsigned (signing
/// off, every reader accepts rows as before — backward compatible).
pub var g_score_key: ?[]const u8 = null;

/// Per-session run id (random hex), the run_id field of signed score records.
pub var g_run_id: [16]u8 = @splat('0');

/// Canonical signing message — newline-delimited, version-prefixed, with the
/// score formatted to a fixed 6 decimals so Zig/Python/JS agree byte-for-byte.
/// v2 (issue #168 Gap 2) folds niche + provider_class into the envelope so a
/// score signed for one MAP-Elites cell cannot be replayed into another by
/// mutating what used to be unsigned transport fields. New clients emit v2
/// only; the backend verifies v2 first and falls back to v1 for legacy rows
/// during the transition window. `buf` must hold the message; returns the
/// slice written.
pub fn scoreSigMessage(
    buf: []u8,
    prompt_sha: []const u8,
    parent_sha: []const u8,
    score: f64,
    run_id: []const u8,
    judge_id: []const u8,
    artifact_sha: []const u8,
    eval_set_hash: []const u8,
    niche: []const u8,
    provider_class: []const u8,
) ?[]const u8 {
    return std.fmt.bufPrint(buf, "v2\n{s}\n{s}\n{d:.6}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        prompt_sha, parent_sha, score, run_id, judge_id, artifact_sha, eval_set_hash, niche, provider_class,
    }) catch null;
}

/// HMAC-SHA256 of the canonical message, hex. "" when no key is configured.
/// SCORE SCALE CONTRACT: `score` here (and in every scoreEvent / fleet
/// submit) is on the canonical [0,1] scale — normalize before signing.
pub fn signScore(
    prompt_sha: []const u8,
    parent_sha: []const u8,
    score: f64,
    run_id: []const u8,
    judge_id: []const u8,
    artifact_sha: []const u8,
    eval_set_hash: []const u8,
    niche: []const u8,
    provider_class: []const u8,
) [64]u8 {
    const key = g_score_key orelse return @splat(0);
    var msgbuf: [512]u8 = undefined;
    const msg = scoreSigMessage(&msgbuf, prompt_sha, parent_sha, score, run_id, judge_id, artifact_sha, eval_set_hash, niche, provider_class) orelse return @splat(0);
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, msg, key);
    return std.fmt.bytesToHex(mac, .lower);
}

/// SCORE SCALE CONTRACT (issue #168 Gap 4): every score that leaves the
/// client is in [0,1]; local display/UX stays 0-100. This is the /score
/// ingestion-boundary normalizer: [0,1] passes through, (1,100] is a
/// percentage and divides by 100, and anything else (negative, >100, NaN)
/// returns null so the caller rejects it — the backend rejects out-of-range
/// scores rather than silently clamping them into a fake 1.0.
pub fn normalizeOutboundScore(v: f64) ?f64 {
    if (std.math.isNan(v) or v < 0 or v > 100) return null;
    return if (v > 1) v / 100.0 else v;
}

/// Sanitize a user-controlled provenance field BEFORE signing (issue #168
/// review F7): '\t', '\n', '\r' become ' '. The signing message is
/// newline-delimited and scoreEvent's prov transport is tab-separated, so an
/// embedded tab/newline in e.g. a --niche would make the signed bytes differ
/// from the transported bytes and break verification server-side. Writes
/// into `buf` (result is at most buf.len bytes); callers pass the same
/// sanitized slice to both signScore and the telemetry event.
pub fn sanitizeMetaField(buf: []u8, field: []const u8) []const u8 {
    const n = @min(buf.len, field.len);
    for (field[0..n], buf[0..n]) |c, *out| {
        out.* = switch (c) {
            '\t', '\n', '\r' => ' ',
            else => c,
        };
    }
    return buf[0..n];
}

/// Read the signing key from GRAFF_SCORE_KEY_FILE (a path outside cwd) into
/// `arena`. Whitespace-trimmed; null when unset, unreadable, or empty.
pub fn loadScoreKey(io: Io, arena: Allocator, environ: anytype) ?[]const u8 {
    const path = environ.get("GRAFF_SCORE_KEY_FILE") orelse return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}
test "promptFingerprint is stable, short, and collision-visible" {
    const a = promptFingerprint("you are a careful reviewer");
    const b = promptFingerprint("you are a careful reviewer");
    const c = promptFingerprint("you are a careless reviewer");
    try std.testing.expectEqualStrings(&a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}
test "score signing message is canonical and cross-language stable" {
    // This exact byte layout is the contract the Python/JS verifiers
    // reimplement — a change here breaks signature verification, so it is
    // pinned. Score is fixed to 6 decimals; fields newline-joined; "v2" tag
    // with niche + provider_class as the last two (now-signed) fields.
    var buf: [512]u8 = undefined;
    const msg = scoreSigMessage(&buf, "aaaaaaaaaaaaaaaa", "", 0.5, "run123", "j1", "", "", "", "").?;
    try std.testing.expectEqualStrings("v2\naaaaaaaaaaaaaaaa\n\n0.500000\nrun123\nj1\n\n\n\n", msg);

    // With a key, signScore is a stable, key-dependent HMAC; without one
    // (default global) it is all-zero hex and callers omit it.
    g_score_key = "testkey";
    defer g_score_key = null;
    const sig = signScore("aaaaaaaaaaaaaaaa", "", 0.5, "run123", "j1", "", "", "reviewer", "mid");
    const sig2 = signScore("aaaaaaaaaaaaaaaa", "", 0.5, "run123", "j1", "", "", "reviewer", "mid");
    try std.testing.expectEqualStrings(&sig, &sig2); // deterministic
    const sig_changed = signScore("aaaaaaaaaaaaaaaa", "", 0.6, "run123", "j1", "", "", "reviewer", "mid");
    try std.testing.expect(!std.mem.eql(u8, &sig, &sig_changed)); // score is signed
    const sig_niche = signScore("aaaaaaaaaaaaaaaa", "", 0.5, "run123", "j1", "", "", "skeptic", "mid");
    try std.testing.expect(!std.mem.eql(u8, &sig, &sig_niche)); // niche is signed (v2)
    const sig_tier = signScore("aaaaaaaaaaaaaaaa", "", 0.5, "run123", "j1", "", "", "reviewer", "small");
    try std.testing.expect(!std.mem.eql(u8, &sig, &sig_tier)); // provider_class is signed (v2)
}
test "providerClass buckets models by capability tier" {
    try std.testing.expectEqualStrings("frontier", providerClass("claude-opus-4-8"));
    try std.testing.expectEqualStrings("frontier", providerClass("gpt-5.5"));
    try std.testing.expectEqualStrings("frontier", providerClass("deepseek-v4-pro"));
    try std.testing.expectEqualStrings("frontier", providerClass("grok-4.3"));
    try std.testing.expectEqualStrings("small", providerClass("claude-haiku-4-5"));
    try std.testing.expectEqualStrings("small", providerClass("gemini-3-flash")); // flash wins over gemini-3
    try std.testing.expectEqualStrings("mid", providerClass("claude-sonnet-4-6"));
    try std.testing.expectEqualStrings("mid", providerClass("some-unknown-model"));
    try std.testing.expectEqualStrings("frontier", providerClass("MiniMax-M3")); // minimax-m needle (case-insensitive)
    // price-table fallback (no name needle): bucket by models.dev output $/1M
    try std.testing.expectEqualStrings("mid", providerClass("grok-build")); // out=2 → mid
    try std.testing.expectEqualStrings("small", providerClass("mimo-v2.5")); // out=0.28 → small
}
test "signScore: golden v2 vector (backend + SDK must match byte-for-byte)" {
    // hmac.new(b"test-key", msg, sha256) over the canonical v2 tuple:
    //   "v2\na1b2\nc3d4\n0.500000\nrun1\nreplay-v1\nart\nevalhash\nreviewer\nfrontier"
    // The worker's v2 verifier and the Python SDK's score_signature are
    // checked against this exact vector — do not regenerate it casually.
    const saved = g_score_key;
    defer g_score_key = saved;
    g_score_key = "test-key";
    const sig = signScore("a1b2", "c3d4", 0.5, "run1", "replay-v1", "art", "evalhash", "reviewer", "frontier");
    try std.testing.expectEqualStrings(
        "2b27be06ec7b686b67f4c1f248d96841b2db8391030030ebee958ce9c53e4d1d",
        &sig,
    );
    g_score_key = null;
    const unsigned = signScore("a1b2", "c3d4", 0.5, "run1", "replay-v1", "art", "evalhash", "reviewer", "frontier");
    try std.testing.expectEqual(@as(u8, 0), unsigned[0]); // no key -> zeroed sig
}

test "scoreSigMessage: canonical bytes are cross-language stable" {
    // The Python SDK (score_signature) and the telemetry worker recompute
    // this byte-for-byte; {d:.6} drifting would silently break every sig.
    var buf: [512]u8 = undefined;
    const msg = scoreSigMessage(&buf, "a1b2", "c3d4", 0.5, "run1", "replay-v1", "art", "evalhash", "reviewer", "frontier").?;
    try std.testing.expectEqualStrings("v2\na1b2\nc3d4\n0.500000\nrun1\nreplay-v1\nart\nevalhash\nreviewer\nfrontier", msg);
    const empty = scoreSigMessage(&buf, "a1b2", "", 1.0, "", "", "", "", "", "").?;
    try std.testing.expectEqualStrings("v2\na1b2\n\n1.000000\n\n\n\n\n\n", empty);
}

test "normalizeOutboundScore: [0,1] passes, (1,100] divides, else rejected" {
    const eps = 1e-12;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), normalizeOutboundScore(0).?, eps);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), normalizeOutboundScore(0.5).?, eps);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), normalizeOutboundScore(1).?, eps);
    try std.testing.expectApproxEqAbs(@as(f64, 0.43), normalizeOutboundScore(43).?, eps);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), normalizeOutboundScore(100).?, eps);
    try std.testing.expectEqual(@as(?f64, null), normalizeOutboundScore(100.5));
    try std.testing.expectEqual(@as(?f64, null), normalizeOutboundScore(-1));
    try std.testing.expectEqual(@as(?f64, null), normalizeOutboundScore(std.math.nan(f64)));
}

test "sanitizeMetaField: a niche with an embedded tab signs and round-trips identically" {
    var buf: [64]u8 = undefined;
    const niche = sanitizeMetaField(&buf, "code\treviewer\r\n");
    try std.testing.expectEqualStrings("code reviewer  ", niche);

    // Round-trip through scoreEvent's tab-separated prov transport: splitting
    // on tabs recovers the exact signed bytes, so a verifier recomputes the
    // same HMAC over the transported attr value.
    var provbuf: [512]u8 = undefined;
    const prov = try std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ "j1", "art", "evalhash", "mid", niche });
    var it = std.mem.splitScalar(u8, prov, '\t');
    _ = it.next(); // judge_id
    _ = it.next(); // artifact_sha
    _ = it.next(); // eval_set_hash
    _ = it.next(); // provider_class
    const transported = it.next().?;
    try std.testing.expect(it.next() == null); // sanitized niche added no extra field
    try std.testing.expectEqualStrings(niche, transported);

    const saved = g_score_key;
    defer g_score_key = saved;
    g_score_key = "test-key";
    const signed = signScore("a1b2", "", 0.5, "run1", "j1", "art", "evalhash", niche, "mid");
    const verified = signScore("a1b2", "", 0.5, "run1", "j1", "art", "evalhash", transported, "mid");
    try std.testing.expectEqualStrings(&signed, &verified);
}
