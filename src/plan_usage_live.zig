//! Live rate-limit & quota capture from HTTP headers, Responses WebSocket
//! frames, and Claude Code `rate_limit_event` messages. Fixed-slot static
//! state (zero global heap allocations) + atomic model block flags for
//! synchronous tier routing without an `Io` handle.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const util = @import("util.zig");
const claude_wire = @import("claude_wire.zig");

const MAX_WINDOWS = 8;
const MAX_BUF = 48;

pub const ClaudeRateLimit = struct {
    status: []const u8,
    resets_at: ?i64 = null,
    rate_limit_type: []const u8 = "",
    utilization: ?f64 = null,
    overage_status: ?[]const u8 = null,
};

pub const Window = struct {
    id: []const u8,
    label: []const u8,
    remaining_pct: ?f64 = null,
    used_pct: ?f64 = null,
    resets_in_s: ?i64 = null,
    resets_at_unix: ?i64 = null,
    window_seconds: ?i64 = null,
    status: ?[]const u8 = null,
};

pub const Snapshot = struct {
    windows: []Window,
    plan: ?[]const u8 = null,
    credits: ?[]const u8 = null,
    overage_status: ?[]const u8 = null,
    updated_ms: i64 = 0,

    pub fn deinit(self: Snapshot, a: std.mem.Allocator) void {
        for (self.windows) |w| {
            a.free(w.id);
            a.free(w.label);
            if (w.status) |s| a.free(s);
        }
        a.free(self.windows);
        if (self.plan) |p| a.free(p);
        if (self.credits) |c| a.free(c);
        if (self.overage_status) |o| a.free(o);
    }
};

const SlotId = enum(usize) { codex = 0, chatgpt_new = 1, anthropic = 2, claude_agent = 3, xai = 4, openai = 5 };

const FixedWindow = struct {
    id_buf: [MAX_BUF]u8 = undefined,
    id_len: u8 = 0,
    label_buf: [MAX_BUF]u8 = undefined,
    label_len: u8 = 0,
    status_buf: [24]u8 = undefined,
    status_len: u8 = 0,
    limit_id_buf: [32]u8 = undefined,
    limit_id_len: u8 = 0,
    remaining_pct: ?f64 = null,
    used_pct: ?f64 = null,
    resets_in_s: ?i64 = null,
    resets_at_unix: ?i64 = null,
    window_seconds: ?i64 = null,
    limit_val: ?f64 = null,
    rem_val: ?f64 = null,
    is_secondary: bool = false,
    codex_style: bool = false,

    fn id(self: *const FixedWindow) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

fn fillArray(comptime T: type, comptime n: usize, comptime val: T) [n]T {
    var out: [n]T = undefined;
    for (&out) |*e| e.* = val;
    return out;
}

const FixedSlot = struct {
    active: bool = false,
    updated_ms: i64 = 0,
    windows: [MAX_WINDOWS]FixedWindow = fillArray(FixedWindow, MAX_WINDOWS, .{}),
    window_count: u8 = 0,
    plan_buf: [32]u8 = undefined,
    plan_len: u8 = 0,
    credits_buf: [24]u8 = undefined,
    credits_len: u8 = 0,
    overage_buf: [24]u8 = undefined,
    overage_len: u8 = 0,

    fn upsert(self: *FixedSlot, key: []const u8) ?*FixedWindow {
        const capped = key[0..@min(key.len, MAX_BUF)];
        for (self.windows[0..self.window_count]) |*w| {
            if (std.mem.eql(u8, w.id(), capped)) return w;
        }
        if (self.window_count >= MAX_WINDOWS) return null;
        var w = &self.windows[self.window_count];
        w.* = .{};
        setBuf(&w.id_buf, &w.id_len, capped);
        self.window_count += 1;
        return w;
    }
};

var g_mu: Io.Mutex = .init;
var g_slots: [6]FixedSlot = fillArray(FixedSlot, 6, .{});
var g_blocked_mask: std.atomic.Value(u32) = .init(0);
const FABLE_ANTHROPIC_BIT: u32 = 1 << 0;
const FABLE_CLAUDE_AGENT_BIT: u32 = 1 << 1;

fn slotFor(provider: []const u8) ?SlotId {
    const map = .{
        .{ "codex", SlotId.codex },
        .{ "chatgpt-new", SlotId.chatgpt_new },
        .{ "anthropic", SlotId.anthropic },
        .{ "claude-agent", SlotId.claude_agent },
        .{ "xai", SlotId.xai },
        .{ "openai", SlotId.openai },
    };
    inline for (map) |e| if (std.mem.eql(u8, provider, e[0])) return e[1];
    return null;
}

fn fableMaskFor(provider: []const u8, model: []const u8) u32 {
    if (!claude_wire.isFable(model)) return 0;
    if (std.mem.eql(u8, provider, "anthropic")) return FABLE_ANTHROPIC_BIT;
    if (std.mem.eql(u8, provider, "claude-agent")) return FABLE_CLAUDE_AGENT_BIT;
    return 0;
}

pub fn isModelBlocked(provider: []const u8, model: []const u8) bool {
    const bit = fableMaskFor(provider, model);
    return bit != 0 and (g_blocked_mask.load(.acquire) & bit) != 0;
}

pub fn setModelBlocked(provider: []const u8, model: []const u8, blocked: bool) void {
    const bit = fableMaskFor(provider, model);
    if (bit != 0) setMaskBit(bit, blocked);
}

fn setMaskBit(bit: u32, blocked: bool) void {
    if (blocked) _ = g_blocked_mask.fetchOr(bit, .release) else _ = g_blocked_mask.fetchAnd(~bit, .release);
}

pub fn resetForTest() void {
    g_blocked_mask.store(0, .release);
    g_slots = fillArray(FixedSlot, 6, .{});
}

fn setBuf(buf: []u8, len_out: *u8, val: []const u8) void {
    const n = @min(val.len, buf.len);
    @memcpy(buf[0..n], val[0..n]);
    len_out.* = @intCast(n);
}

fn startsWithIC(hay: []const u8, prefix: []const u8) bool {
    return hay.len >= prefix.len and std.ascii.eqlIgnoreCase(hay[0..prefix.len], prefix);
}

fn endsWithIC(hay: []const u8, suffix: []const u8) bool {
    return hay.len >= suffix.len and std.ascii.eqlIgnoreCase(hay[hay.len - suffix.len ..], suffix);
}

fn clampPct(v: f64) f64 {
    return @max(0.0, @min(100.0, v));
}

fn trimStr(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn applyResetTimestamp(w: *FixedWindow, raw: i64, now_s: i64) void {
    if (raw > 1_000_000_000) {
        w.resets_at_unix = raw;
        w.resets_in_s = @max(0, raw - now_s);
    } else if (raw >= 0) {
        w.resets_in_s = raw;
        w.resets_at_unix = now_s + raw;
    }
}

fn parseDurationSeconds(raw: []const u8) ?i64 {
    const s = trimStr(raw);
    if (s.len == 0) return null;
    if (std.fmt.parseInt(i64, s, 10) catch null) |n| return n;
    var total_ms: i64 = 0;
    var i: usize = 0;
    var any = false;
    while (i < s.len) {
        if (!std.ascii.isDigit(s[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        const n = std.fmt.parseInt(i64, s[start..i], 10) catch return null;
        if (i + 1 < s.len and std.ascii.eqlIgnoreCase(s[i .. i + 2], "ms")) {
            total_ms += n;
            i += 2;
        } else if (i < s.len) {
            const mult: i64 = switch (std.ascii.toLower(s[i])) {
                'm' => 60_000,
                'h' => 3_600_000,
                'd' => 86_400_000,
                else => 1000,
            };
            total_ms += n * mult;
            i += 1;
        } else total_ms += n * 1000;
        any = true;
    }
    return if (any) @max(0, @divTrunc(total_ms + 500, 1000)) else null;
}

fn formatSpan(buf: []u8, secs: i64) []const u8 {
    if (secs >= 86400 and @mod(secs, 86400) == 0) return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(secs, 86400)}) catch "limit";
    if (secs >= 3600 and @mod(secs, 3600) == 0) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(secs, 3600)}) catch "limit";
    if (secs >= 60) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(secs, 60)}) catch "limit";
    return std.fmt.bufPrint(buf, "{d}s", .{@max(1, secs)}) catch "limit";
}

fn formatLimitName(buf: []u8, raw: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "codex_bengalfox")) return "GPT-5.3-Codex-Spark";
    var n: usize = 0;
    var cap = true;
    for (raw) |c| {
        if (n >= buf.len) break;
        if (c == '_' or c == '-') {
            buf[n] = ' ';
            cap = true;
        } else {
            buf[n] = if (cap) std.ascii.toUpper(c) else c;
            cap = false;
        }
        n += 1;
    }
    return buf[0..n];
}

fn formatBucketLabel(w: *FixedWindow) void {
    const id = w.id();
    if (w.codex_style) {
        var sb: [16]u8 = undefined;
        var nb: [32]u8 = undefined;
        const has_span = (w.window_seconds orelse 0) > 0;
        const span = if (has_span) formatSpan(&sb, w.window_seconds.?) else "";
        const base = if (w.limit_id_len > 0)
            formatLimitName(&nb, w.limit_id_buf[0..w.limit_id_len])
        else if (w.is_secondary)
            "Week"
        else
            "Session";
        const out = if (has_span)
            std.fmt.bufPrint(&w.label_buf, "{s} ({s})", .{ base, span }) catch base
        else
            std.fmt.bufPrint(&w.label_buf, "{s}", .{base}) catch base;
        w.label_len = @intCast(out.len);
        return;
    }
    const labels = .{
        .{ "5h", "Session" },        .{ "five_hour", "Session" },
        .{ "7d", "Week" },           .{ "seven_day", "Week" },
        .{ "7d_opus", "Opus" },      .{ "seven_day_opus", "Opus" },
        .{ "7d_sonnet", "Sonnet" },  .{ "seven_day_sonnet", "Sonnet" },
        .{ "7d_haiku", "Haiku" },    .{ "seven_day_haiku", "Haiku" },
        .{ "fable", "Fable" },       .{ "overage", "Overage" },
        .{ "requests", "Requests" }, .{ "tokens", "Tokens" },
    };
    inline for (labels) |kv| {
        if (std.ascii.eqlIgnoreCase(id, kv[0])) {
            setBuf(&w.label_buf, &w.label_len, kv[1]);
            return;
        }
    }
    var nb: [32]u8 = undefined;
    setBuf(&w.label_buf, &w.label_len, formatLimitName(&nb, id));
}

const HeaderCtx = struct {
    unified_status: [24]u8 = undefined,
    unified_status_len: u8 = 0,
    rep_claim: [32]u8 = undefined,
    rep_claim_len: u8 = 0,
    overage_status: [24]u8 = undefined,
    overage_status_len: u8 = 0,
};

fn upsertCodexWin(slot: *FixedSlot, now_s: i64, lid: []const u8, secondary: bool, field: []const u8, value: []const u8) void {
    var kb: [MAX_BUF]u8 = undefined;
    const sfx = if (secondary) "secondary" else "primary";
    const key = if (lid.len == 0) sfx else std.fmt.bufPrint(&kb, "{s}_{s}", .{ lid, sfx }) catch sfx;
    const w = slot.upsert(key) orelse return;
    w.codex_style = true;
    w.is_secondary = secondary;
    if (lid.len > 0) setBuf(&w.limit_id_buf, &w.limit_id_len, lid);
    if (std.ascii.eqlIgnoreCase(field, "used-percent")) {
        if (std.fmt.parseFloat(f64, trimStr(value)) catch null) |u| {
            w.used_pct = clampPct(u);
            w.remaining_pct = clampPct(100.0 - u);
        }
    } else if (std.ascii.eqlIgnoreCase(field, "window-minutes")) {
        if (std.fmt.parseInt(i64, trimStr(value), 10) catch null) |m| if (m > 0) {
            w.window_seconds = m * 60;
        };
    } else if (std.ascii.eqlIgnoreCase(field, "reset-at") or std.ascii.eqlIgnoreCase(field, "reset-after-seconds")) {
        if (std.fmt.parseInt(i64, trimStr(value), 10) catch null) |raw| applyResetTimestamp(w, raw, now_s);
    }
    slot.active = true;
}

fn applyLimitHeader(slot: *FixedSlot, now_s: i64, name: []const u8, tv: []const u8) void {
    const key = if (endsWithIC(name, "requests") or util.indexOfIgnoreCase(name, "-requests-") != null)
        "requests"
    else if (endsWithIC(name, "tokens") or util.indexOfIgnoreCase(name, "-tokens-") != null)
        "tokens"
    else
        return;
    const w = slot.upsert(key) orelse return;
    if (endsWithIC(name, "-limit") or util.indexOfIgnoreCase(name, "-limit-") != null) {
        if (std.fmt.parseFloat(f64, tv) catch null) |v| w.limit_val = v;
    } else if (util.indexOfIgnoreCase(name, "remaining") != null) {
        if (std.fmt.parseFloat(f64, tv) catch null) |v| w.rem_val = v;
    } else if (util.indexOfIgnoreCase(name, "reset") != null) {
        if (parseDurationSeconds(tv)) |s| applyResetTimestamp(w, s, now_s);
    }
    if (w.limit_val) |lim| if (w.rem_val) |rem| if (lim > 0) {
        w.remaining_pct = clampPct((rem * 100.0) / lim);
        w.used_pct = clampPct(100.0 - w.remaining_pct.?);
        slot.active = true;
    };
}

fn applySingleHeader(slot: *FixedSlot, ctx: *HeaderCtx, now_s: i64, name: []const u8, value: []const u8) void {
    const tv = trimStr(value);
    if (startsWithIC(name, "x-codex-")) {
        const rest = name["x-codex-".len..];
        if (std.ascii.eqlIgnoreCase(rest, "plan-type")) {
            setBuf(&slot.plan_buf, &slot.plan_len, tv);
            slot.active = true;
        } else if (std.ascii.eqlIgnoreCase(rest, "credits-balance")) {
            setBuf(&slot.credits_buf, &slot.credits_len, tv);
            slot.active = true;
        } else if (std.ascii.eqlIgnoreCase(rest, "credits-unlimited") and std.ascii.eqlIgnoreCase(tv, "true")) {
            setBuf(&slot.credits_buf, &slot.credits_len, "unlimited");
            slot.active = true;
        } else if (startsWithIC(rest, "primary-")) upsertCodexWin(slot, now_s, "", false, rest["primary-".len..], tv) else if (startsWithIC(rest, "secondary-")) upsertCodexWin(slot, now_s, "", true, rest["secondary-".len..], tv) else if (util.indexOfIgnoreCase(rest, "-primary-")) |i| {
            if (!startsWithIC(rest[0..i], "credits")) upsertCodexWin(slot, now_s, rest[0..i], false, rest[i + "-primary-".len ..], tv);
        } else if (util.indexOfIgnoreCase(rest, "-secondary-")) |i| {
            if (!startsWithIC(rest[0..i], "credits")) upsertCodexWin(slot, now_s, rest[0..i], true, rest[i + "-secondary-".len ..], tv);
        }
        return;
    }
    if (startsWithIC(name, "anthropic-ratelimit-unified-")) {
        const rest = name["anthropic-ratelimit-unified-".len..];
        if (std.ascii.eqlIgnoreCase(rest, "status")) setBuf(&ctx.unified_status, &ctx.unified_status_len, tv) else if (std.ascii.eqlIgnoreCase(rest, "representative-claim")) setBuf(&ctx.rep_claim, &ctx.rep_claim_len, tv) else if (std.ascii.eqlIgnoreCase(rest, "overage-status")) {
            setBuf(&ctx.overage_status, &ctx.overage_status_len, tv);
            setBuf(&slot.overage_buf, &slot.overage_len, tv);
        } else if (endsWithIC(rest, "-utilization")) {
            if (std.fmt.parseFloat(f64, tv) catch null) |raw| if (slot.upsert(rest[0 .. rest.len - "-utilization".len])) |w| {
                const used = clampPct(if (raw <= 1.0) raw * 100.0 else raw);
                w.used_pct = used;
                w.remaining_pct = clampPct(100.0 - used);
                slot.active = true;
            };
        } else if (endsWithIC(rest, "-reset")) {
            if (std.fmt.parseInt(i64, tv, 10) catch null) |ts| if (slot.upsert(rest[0 .. rest.len - "-reset".len])) |w| {
                applyResetTimestamp(w, ts, now_s);
                slot.active = true;
            };
        } else if (endsWithIC(rest, "-status")) {
            if (slot.upsert(rest[0 .. rest.len - "-status".len])) |w| {
                setBuf(&w.status_buf, &w.status_len, tv);
                slot.active = true;
            }
        }
        return;
    }
    if (startsWithIC(name, "anthropic-ratelimit-") or startsWithIC(name, "x-ratelimit-")) applyLimitHeader(slot, now_s, name, tv);
}

fn finalizeSlotUpdate(provider: []const u8, model: ?[]const u8, status_code: u16, ctx: *const HeaderCtx, slot: *FixedSlot, now_ms: i64) void {
    slot.updated_ms = now_ms;
    for (slot.windows[0..slot.window_count]) |*w| formatBucketLabel(w);
    if (!std.mem.eql(u8, provider, "anthropic")) return;
    const ustat = ctx.unified_status[0..ctx.unified_status_len];
    const claim = ctx.rep_claim[0..ctx.rep_claim_len];
    const ostat = ctx.overage_status[0..ctx.overage_status_len];
    const overage_ok = std.ascii.eqlIgnoreCase(ostat, "allowed") or std.ascii.eqlIgnoreCase(ostat, "allowed_warning");
    const is_fable_model = if (model) |m| claude_wire.isFable(m) else false;
    const fable_claim = util.indexOfIgnoreCase(claim, "fable") != null;
    if (!overage_ok and ((is_fable_model and (status_code == 429 or std.ascii.eqlIgnoreCase(ustat, "rejected"))) or (fable_claim and std.ascii.eqlIgnoreCase(ustat, "rejected")))) {
        setMaskBit(FABLE_ANTHROPIC_BIT, true);
    } else if (is_fable_model and status_code >= 200 and status_code < 300 and !std.ascii.eqlIgnoreCase(ustat, "rejected")) {
        setMaskBit(FABLE_ANTHROPIC_BIT, false);
    }
}

pub fn noteHttpResponse(io: Io, provider: []const u8, model: ?[]const u8, status_code: u16, response: *const std.http.Client.Response) void {
    if (slotFor(provider) == null) return;
    var it = response.head.iterateHeaders();
    var headers: [48]std.http.Header = undefined;
    var count: usize = 0;
    while (it.next()) |h| {
        if ((startsWithIC(h.name, "x-codex-") or startsWithIC(h.name, "anthropic-ratelimit-") or startsWithIC(h.name, "x-ratelimit-")) and count < headers.len) {
            headers[count] = h;
            count += 1;
        }
    }
    if (count == 0 and !(std.mem.eql(u8, provider, "anthropic") and model != null and claude_wire.isFable(model.?))) return;
    noteHeaderList(io, provider, model, status_code, headers[0..count]);
}

pub fn noteHeaderList(io: Io, provider: []const u8, model: ?[]const u8, status_code: u16, headers: []const std.http.Header) void {
    const sid = slotFor(provider) orelse return;
    const now_ms = util.unixMs(io);
    const now_s = @divTrunc(now_ms, 1000);
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    var ctx: HeaderCtx = .{};
    const slot = &g_slots[@backingInt(sid)];
    for (headers) |h| applySingleHeader(slot, &ctx, now_s, h.name, h.value);
    finalizeSlotUpdate(provider, model, status_code, &ctx, slot, now_ms);
}

fn jsonFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

fn parseCodexWsWindow(slot: *FixedSlot, obj: std.json.ObjectMap, lid: []const u8, secondary: bool, now_s: i64) void {
    var kb: [MAX_BUF]u8 = undefined;
    const sfx = if (secondary) "secondary" else "primary";
    const key = if (lid.len == 0) sfx else std.fmt.bufPrint(&kb, "{s}_{s}", .{ lid, sfx }) catch sfx;
    const w = slot.upsert(key) orelse return;
    w.codex_style = true;
    w.is_secondary = secondary;
    if (lid.len > 0) setBuf(&w.limit_id_buf, &w.limit_id_len, lid);
    if (jsonFloat(obj, "used_percent")) |u| {
        w.used_pct = clampPct(u);
        w.remaining_pct = clampPct(100.0 - u);
    }
    const mins = util.intFieldObj(obj, "window_minutes", 0);
    if (mins > 0) w.window_seconds = mins * 60;
    const rst = util.intFieldObj(obj, "resets_at", -1);
    if (rst >= 0) applyResetTimestamp(w, rst, now_s);
    formatBucketLabel(w);
    slot.active = true;
}

pub fn noteWsFrame(io: Io, provider: []const u8, frame_bytes: []const u8) void {
    if (std.mem.indexOf(u8, frame_bytes, "codex.rate_limits") == null) return;
    const sid = slotFor(provider) orelse return;
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const parsed = std.json.parseFromSliceLeaky(Value, arena_impl.allocator(), frame_bytes, .{}) catch return;
    if (parsed != .object) return;
    const obj = parsed.object;
    const root_rl = if (obj.get("rate_limits")) |v| (if (v == .object) v.object else obj) else if (obj.get("rate_limit")) |v| (if (v == .object) v.object else obj) else obj;
    const now_ms = util.unixMs(io);
    const now_s = @divTrunc(now_ms, 1000);
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const slot = &g_slots[@backingInt(sid)];
    const lid = util.strFieldObj(root_rl, "limit_id") orelse util.strFieldObj(obj, "limit_id") orelse "";
    if (root_rl.get("primary")) |p| if (p == .object) parseCodexWsWindow(slot, p.object, lid, false, now_s);
    if (root_rl.get("secondary")) |s| if (s == .object) parseCodexWsWindow(slot, s.object, lid, true, now_s);
    if (util.strFieldObj(root_rl, "plan_type") orelse util.strFieldObj(obj, "plan_type")) |pt| setBuf(&slot.plan_buf, &slot.plan_len, pt);
    if (root_rl.get("credits")) |cr| if (cr == .object) if (util.strFieldObj(cr.object, "balance")) |b| setBuf(&slot.credits_buf, &slot.credits_len, b);
    slot.updated_ms = now_ms;
}

pub fn noteClaudeRateLimit(io: Io, model: ?[]const u8, rl: ClaudeRateLimit) void {
    const now_ms = util.unixMs(io);
    const now_s = @divTrunc(now_ms, 1000);
    const key = if (rl.rate_limit_type.len > 0) rl.rate_limit_type else "session";
    const overage_ok = if (rl.overage_status) |os| std.ascii.eqlIgnoreCase(os, "allowed") or std.ascii.eqlIgnoreCase(os, "allowed_warning") else false;
    const is_fable_scope = util.indexOfIgnoreCase(rl.rate_limit_type, "fable") != null or ((if (model) |m| claude_wire.isFable(m) else false) and rl.rate_limit_type.len == 0);
    if (is_fable_scope) {
        if (std.ascii.eqlIgnoreCase(rl.status, "rejected") and !overage_ok) setMaskBit(FABLE_CLAUDE_AGENT_BIT, true) else if (std.ascii.eqlIgnoreCase(rl.status, "allowed") or std.ascii.eqlIgnoreCase(rl.status, "allowed_warning")) setMaskBit(FABLE_CLAUDE_AGENT_BIT, false);
    }
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const slot = &g_slots[@backingInt(SlotId.claude_agent)];
    if (rl.overage_status) |os| setBuf(&slot.overage_buf, &slot.overage_len, os);
    if (slot.upsert(key)) |w| {
        if (rl.utilization) |raw| {
            const used = clampPct(if (raw <= 1.0) raw * 100.0 else raw);
            w.used_pct = used;
            w.remaining_pct = clampPct(100.0 - used);
        }
        if (rl.resets_at) |raw| applyResetTimestamp(w, if (raw > 10_000_000_000) @divTrunc(raw, 1000) else raw, now_s);
        setBuf(&w.status_buf, &w.status_len, rl.status);
        formatBucketLabel(w);
        slot.active = true;
    }
    slot.updated_ms = now_ms;
}

pub fn snapshot(io: Io, a: std.mem.Allocator, provider: []const u8) !?Snapshot {
    const sid = slotFor(provider) orelse return null;
    const now_s = @divTrunc(util.unixMs(io), 1000);
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const slot = &g_slots[@backingInt(sid)];
    if (!slot.active or slot.window_count == 0) return null;
    const wins = try a.alloc(Window, slot.window_count);
    var built: usize = 0;
    errdefer {
        for (wins[0..built]) |w| {
            a.free(w.id);
            a.free(w.label);
            if (w.status) |s| a.free(s);
        }
        a.free(wins);
    }
    for (slot.windows[0..slot.window_count]) |fw| {
        const dyn_in: ?i64 = if (fw.resets_at_unix) |ts| @max(0, ts - now_s) else fw.resets_in_s;
        wins[built] = .{
            .id = try a.dupe(u8, fw.id()),
            .label = try a.dupe(u8, if (fw.label_len > 0) fw.label_buf[0..fw.label_len] else fw.id()),
            .remaining_pct = fw.remaining_pct,
            .used_pct = fw.used_pct,
            .resets_in_s = dyn_in,
            .resets_at_unix = fw.resets_at_unix,
            .window_seconds = fw.window_seconds,
            .status = if (fw.status_len > 0) try a.dupe(u8, fw.status_buf[0..fw.status_len]) else null,
        };
        built += 1;
    }
    return .{
        .windows = wins,
        .plan = if (slot.plan_len > 0) try a.dupe(u8, slot.plan_buf[0..slot.plan_len]) else null,
        .credits = if (slot.credits_len > 0) try a.dupe(u8, slot.credits_buf[0..slot.credits_len]) else null,
        .overage_status = if (slot.overage_len > 0) try a.dupe(u8, slot.overage_buf[0..slot.overage_len]) else null,
        .updated_ms = slot.updated_ms,
    };
}
