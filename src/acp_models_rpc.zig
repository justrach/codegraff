//! `graff/models` vendor RPC and sibling vendor extension routing for `graff acp`.
//! Split out of `acp.zig` to keep `acp.zig` well below the 600-LOC cap.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const provider_mod = @import("provider.zig");
const proto = @import("acp_protocol.zig");
const pricing = @import("pricing.zig");
const billing = @import("billing.zig");
const models_rank = @import("models_rank");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;

/// `graff/models` (vendor extension, dispatched through `engine.Dispatch.extra`):
/// the same catalog + credential view the REPL `/models` table prints, so an
/// ACP client can offer only the models this install can actually reach.
/// Rows come back in election order (plan, then local, credits, api).
pub fn liveModels(ctx: *anyopaque, arena: Allocator, w: *Io.Writer, req: proto.Request) anyerror!bool {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    if (try @import("acp_agents.zig").handle(arena, live.root.io, live.root.home, w, req)) return true;
    if (try @import("acp_changes.zig").handle(arena, live.root.io, w, req)) return true;
    if (try @import("acp_session_fork.zig").handle(live, arena, w, req)) return true;
    if (try @import("acp_mcp_app.zig").handle(arena, w, req, live.root)) return true;
    if (try @import("acp_accounts.zig").handle(arena, live.root.io, live.root.gpa, live.root.home, live.keys, live.root.provider.id, w, req)) return true;
    if (!std.mem.eql(u8, req.method, "graff/models")) return false;
    if (req.id == null) return true;
    const keys = live.keys;
    const root = live.root;
    // Hydrate deferred local metadata without network refresh or MCP startup.
    @import("acp_model_option.zig").hydrate(live);
    const er = @import("effort_route.zig");
    const cat_refresh = @import("catalog_refresh.zig");
    const codex_home = if (root.model_catalog) |mc| mc.codex_home else "";
    if (cat_refresh.forceRequested(req.params)) {
        _ = cat_refresh.refreshAllBounded(root.io, root.arena, root.home, codex_home, keys.*, .fromSeconds(4));
    } else if (@import("gateway_picker_catalog.zig").requested(req.params)) {
        @import("gateway_picker_catalog.zig").refresh(root.io, root.arena, root.home, keys.*);
        cat_refresh.detachStaleAll(root.io, root.arena, root.home, codex_home, keys.*);
    }
    const catalog = pricing.models();
    const Row = struct {
        name: []const u8,
        provider: []const u8,
        maker: ?[]const u8, // who made it, for a logo; the provider is only the route
        context: u64,
        authenticated: bool,
        cost: []const u8,
        separateQuota: bool = false,
        current: bool,
        effortLevels: []const []const u8,
        fastSupported: bool,
        ultrafastSupported: bool,
        serviceTiers: []const []const u8,
        orchestratorSupported: bool,
        executorModel: ?[]const u8,
    };
    const orchestrator = @import("orchestrator_mode.zig");
    const service_tier = @import("service_tier.zig");
    const ranked = try arena.alloc(models_rank.Scored, catalog.len);
    for (catalog, 0..) |m, i| ranked[i] = .{
        .idx = i,
        .score = models_rank.electionRank(
            keys.get(m.provider) != null,
            billing.costFor(m.provider, keys.source(m.provider)),
        ),
    };
    @import("stable_sort.zig").sort(models_rank.Scored, ranked, {}, models_rank.scoredLess);
    const rows = try arena.alloc(Row, catalog.len);
    for (ranked, rows) |r, *row| {
        const m = catalog[r.idx];
        const spec = provider_mod.specFor(m.provider);
        const supports_effort = spec != null and @import("schema.zig").providerTakesEffort(spec.?.kind, m.provider, m.name);
        const exec_p = if (spec) |sp|
            orchestrator.resolveExecutor(keys.build(sp, keys.get(m.provider) orelse "", m.name), root.reasoning)
        else
            null;
        row.* = .{
            .name = m.name,
            .provider = m.provider,
            .maker = @import("model_maker.zig").of(m.provider, m.name),
            .context = pricing.contextFor(m.provider, m.name),
            .authenticated = keys.get(m.provider) != null,
            .cost = billing.costFor(m.provider, keys.source(m.provider)).badge(),
            .separateQuota = billing.quotaPoolFor(m.provider, m.name, keys.source(m.provider)) == .separate,
            .current = std.mem.eql(u8, m.name, root.provider.model) and std.mem.eql(u8, m.provider, root.provider.id),
            .effortLevels = if (supports_effort) er.levels(m.provider, m.name) else &.{},
            .fastSupported = service_tier.supportsFast(m.provider),
            .ultrafastSupported = service_tier.supportsUltrafast(m.provider, m.name),
            .serviceTiers = service_tier.tiersFor(m.provider, m.name),
            .orchestratorSupported = exec_p != null,
            .executorModel = if (exec_p) |ep| ep.model else null,
        };
    }
    const levels: []const []const u8 = if (!root.effortApplies()) &.{} else er.levels(root.provider.id, root.provider.model);
    const cur_exec = orchestrator.resolveExecutor(root.provider, root.reasoning);
    const cur_tier = service_tier.normalizedForModel(root.provider.id, root.provider.model, service_tier.effective(root));
    try proto.writeResult(w, req.id, .{
        .models = rows,
        .commands = proto.slashCommands(),
        .current = .{
            .model = root.provider.model,
            .provider = root.provider.id,
            .effort = er.normalize(root.provider.id, root.provider.model, @tagName(root.reasoning)),
            .fast = cur_tier != .standard,
            .serviceTier = cur_tier.label(),
            .effortLevels = levels,
            .fastSupported = service_tier.supportsFast(root.provider.id),
            .ultrafastSupported = service_tier.supportsUltrafast(root.provider.id, root.provider.model),
            .orchestrator = orchestrator.g_mode.label(),
            .orchestratorSupported = cur_exec != null,
            .executorModel = if (cur_exec) |ep| ep.model else null,
        },
    });
    return true;
}
