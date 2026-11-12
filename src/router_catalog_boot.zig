//! Startup's live model catalogs never hold the first keystroke.
//!
//! Boot used to fetch every keyed dynamic catalog with no disk cache and wait
//! for it, up to `catalog_bounded.startup_budget`. A first-ever boot (or a
//! fresh HOME) always has no cache, and a rejected key writes none, so every
//! such boot paid a full TLS GET before the prompt — ~260 ms against
//! api.anthropic.com — for a list only the model pickers read. A cold cache
//! now behaves like a stale one: boot proceeds on the baked rows, the fetch
//! runs on a detached worker, and its list activates on the main thread at
//! the next model-surface beat after it lands (`activateLanded`, ADR 0340).
//!
//! One case still waits, bounded as before: a `--model` naming a row the baked
//! table lacks. Startup resolves that name before the prompt, and without the
//! live rows it would refuse a model the provider serves.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const rc = @import("router_catalog.zig");
const catalog_bounded = @import("catalog_bounded.zig");
const catalog_selection = @import("catalog_selection.zig");
const landing = @import("catalog_landing.zig");
const kimi_catalog = @import("kimi_catalog.zig");
const pricing = @import("pricing.zig");
const provider = @import("provider.zig");
const serde = @import("serde.zig");

/// Whether startup's own `--model` resolution may need `provider_id`'s live
/// rows: the flag names a model the baked table cannot. A provider name, an
/// exact baked row, or no flag at all resolves against what is already there.
pub fn needsLiveRows(provider_id: []const u8, model_flag: ?[]const u8) bool {
    const query = std.mem.trim(u8, model_flag orelse return false, " \t");
    if (query.len == 0 or provider.specFor(query) != null) return false;
    if (catalog_selection.explicitProvider(query)) |id| {
        if (!std.mem.eql(u8, id, provider_id)) return false;
        const end = std.mem.indexOfAny(u8, query, " /\t") orelse query.len;
        const model = std.mem.trim(u8, query[end..], " \t/");
        return model.len != 0 and !pricing.providerModelInTable(provider_id, model);
    }
    return !pricing.modelInTable(query);
}

/// Kimi's account catalog: any cache activates now (a stale one refreshes
/// behind it); with none, the fetch detaches like a router's. Returns a batch
/// slot only for a `--model` that needs the live rows.
fn startKimi(io: Io, batch: *catalog_bounded.Batch, arena: Allocator, home: []const u8, keys: provider.Keys, model_flag: ?[]const u8, saved: ?serde.SavedModel) ?usize {
    if (!catalog_selection.startupMayUse(keys, "kimi", model_flag, saved)) return null;
    if (!kimi_catalog.claimAttempt()) return null;
    const access = keys.get("kimi") orelse "";
    if (access.len == 0) {
        kimi_catalog.commit(arena, &.{}, "baked fallback — no Kimi login");
        return null;
    }
    const cache = kimi_catalog.cached(io, arena, home) orelse {
        if (needsLiveRows("kimi", model_flag)) return batch.spawn(.kimi, home, access);
        kimi_catalog.commit(arena, &.{}, "baked fallback — live catalog still loading");
        landing.expect(.kimi);
        catalog_bounded.detach(.kimi, home, access);
        return null;
    };
    kimi_catalog.commit(arena, cache.rows, "cached account catalog");
    if (!cache.fresh) catalog_bounded.detach(.kimi, home, access);
    return null;
}

/// Startup catalog load. Never waits on a live GET to show the prompt: fresh
/// caches activate as they are, stale ones activate and refresh behind, and
/// hosts with no cache boot on baked rows while their fetch lands behind. Only
/// a `--model` the baked rows cannot resolve joins a batch under one budget.
pub fn ensureForStartup(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, model_flag: ?[]const u8, saved: ?serde.SavedModel, worker_hint: ?[]const u8) void {
    _ = gpa;
    var batch: catalog_bounded.Batch = .{};
    const kimi_slot = startKimi(io, &batch, arena, home, keys, model_flag, saved);
    var slots: [provider.provider_specs.len + 1]?usize = @splat(null);
    for (provider.provider_specs, 0..) |spec, index| {
        if (!rc.dynamic(spec) or !catalog_selection.startupLoads(keys, spec.id, model_flag, saved, worker_hint)) continue;
        if (rc.attempted[index]) continue;
        const key = keys.get(spec.id) orelse continue;
        if (key.len == 0) continue;
        rc.attempted[index] = true;
        slots[index] = startSpec(io, &batch, arena, home, spec, key, keys.source(spec.id), model_flag);
    }
    if (provider.additional_router) |spec| {
        if (catalog_selection.startupLoads(keys, spec.id, model_flag, saved, worker_hint) and !rc.additional_attempted) {
            if (keys.get(spec.id)) |key| if (key.len != 0) {
                rc.additional_attempted = true;
                slots[provider.provider_specs.len] = startSpec(io, &batch, arena, home, spec, key, keys.source(spec.id), model_flag);
            };
        }
    }
    if (batch.len == 0) return;
    batch.wait(io, catalog_bounded.startup_budget);
    if (batch.fetched(kimi_slot)) {
        if (kimi_catalog.cached(io, arena, home)) |fresh| kimi_catalog.commit(arena, fresh.rows, "live account catalog");
    } else if (kimi_slot != null) kimi_catalog.commit(arena, &.{}, "baked fallback — live catalog still loading");
    for (provider.provider_specs, 0..) |spec, index|
        if (batch.fetched(slots[index])) {
            _ = rc.activateCached(io, arena, home, spec);
        };
    if (provider.additional_router) |spec| if (batch.fetched(slots[provider.provider_specs.len])) {
        _ = rc.activateCached(io, arena, home, spec);
    };
}

fn startSpec(io: Io, batch: *catalog_bounded.Batch, arena: Allocator, home: []const u8, spec: provider.ProviderSpec, key: []const u8, source: provider.Keys.CredentialSource, model_flag: ?[]const u8) ?usize {
    const job: catalog_bounded.Job = .{ .router = .{ .spec = spec, .source = source } };
    // The workspace router caches under `.graff`, not home.
    const cache_home = if (rc.isAdditional(spec)) "." else home;
    if (rc.cacheFresh(io, arena, home, spec)) {
        if (rc.alwaysLive(spec)) catalog_bounded.detach(job, cache_home, key);
        return null;
    }
    if (rc.activateCached(io, arena, home, spec)) {
        catalog_bounded.detach(job, cache_home, key);
        return null;
    }
    // No cache: the baked rows serve until the fetch lands, unless this
    // boot's own `--model` cannot resolve without it.
    if (needsLiveRows(spec.id, model_flag)) return batch.spawn(job, cache_home, key);
    landing.expect(job);
    catalog_bounded.detach(job, cache_home, key);
    return null;
}

/// Activate every catalog boot detached with no cache whose fetch has landed
/// since. Main thread only: it owns the model table and `arena`. Cheap when
/// nothing landed (one atomic load per slot), so model surfaces call it on
/// every beat; each landing is activated once.
pub fn activateLanded(io: Io, arena: Allocator, home: []const u8) void {
    for (provider.provider_specs, 0..) |spec, index| if (landing.take(index)) {
        _ = rc.activateCached(io, arena, home, spec);
    };
    if (landing.take(landing.additional_slot)) if (provider.additional_router) |spec| {
        _ = rc.activateCached(io, arena, home, spec);
    };
    if (landing.take(landing.kimi_slot)) if (kimi_catalog.cached(io, arena, home)) |fresh|
        kimi_catalog.commit(arena, fresh.rows, "live account catalog");
}

test {
    _ = @import("catalog_landing.zig");
}
