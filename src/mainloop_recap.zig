//! Detached session-recap jobs for the root loop (#419) — mainloop_title.zig's
//! shape with a per-turn settle debounce. The caller context is generic so
//! this module stays independent of `mainloop.zig`'s orchestration type.
//!
//! Turn end emits the FREE recap synchronously (`onTurnEnd`: the heuristic
//! event precedes the terminal `turn` event so stream-until-turn clients like
//! the GUI always see it), then schedules the cheap-model recap. The job runs
//! while the loop idles; `poll` applies it only when no newer turn has
//! started (the generation check IS the debounce — a streaming turn bumps the
//! generation, so recaps never thrash mid-turn). Emission then happens at the
//! next poll point: in --json mode that is just before the next prompt is
//! read, which is the harness's first chance to write while blocked on stdin.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const recap_mod = @import("recap.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");

const Recap = recap_mod.Recap;

const Job = struct {
    future: ?Io.Future(void) = null,
    input: []const u8, // gpa-owned digest: the session arena must stay off-thread
    result: ?Recap = null, // text gpa-owned, published before done.release
    done: std.atomic.Value(bool) = .init(false),
    generation: u64,
};

/// The cheapest rung the root provider's ladder knows (#291), as a ready
/// Provider. Null — silently, per #419 — when the family has no cheaper rung,
/// the root already sits on it, or no key exists for the provider.
fn cheapProvider(ctx: anytype) ?provider_mod.Provider {
    const root_p = ctx.root.provider;
    const ladder = tier_ladder.forProvider(root_p.id) orelse return null;
    const model = ladder.modelFor(.small) orelse ladder.modelFor(.mid) orelse return null;
    if (std.mem.eql(u8, model, root_p.model)) return null; // already bottom rung
    return ctx.keys.providerById(root_p.id, model) catch null;
}

fn publish(ctx: anytype, recap: Recap, source: []const u8) void {
    const stored = ctx.arena.dupe(u8, recap.text) catch return;
    ctx.root.session_recap = .{ .status = recap.status, .text = stored };
    if (main_mod.json_mode) ctx.root.emit(.{
        .type = "session_recap",
        .text = stored,
        .status = @tagName(recap.status),
        .source = source,
    });
}

/// Turn end, success path: the heuristic recap lands first (free, and ordered
/// before the terminal `turn` event), then the model recap is scheduled.
/// `final_text` borrows turn-scoped memory — everything the job keeps is
/// duped before it spawns.
pub fn onTurnEnd(ctx: anytype, jobs: *Jobs, final_text: []const u8) void {
    publish(ctx, recap_mod.heuristic(final_text, false), "heuristic");
    // Cosmetic model calls stay out of scripted sessions — the same rule the
    // AI title follows (mainloop.zig): a recap request against a scripted
    // mock shifts every request-count assertion (test-review-mode.py on CI).
    if (!main_mod.json_mode and !ctx.root.review_mode) jobs.start(ctx);
}

fn detachedTask(job: *Job, gpa: Allocator, io: Io, client: *std.http.Client, provider: provider_mod.Provider, budget: ?*@import("run_budget.zig").RunBudget, tracer: ?*@import("trace.zig").Tracer) void {
    job.result = recap_mod.recapTask(gpa, io, client, provider, job.input, budget, tracer);
    job.done.store(true, .release);
}

/// Cheap-model recap jobs are polled without waiting and canceled at close.
pub const Jobs = struct {
    items: std.ArrayList(*Job) = .empty,

    fn start(self: *Jobs, ctx: anytype) void {
        // Same reserve as the AI title: cosmetic work never consumes the
        // final provider-call slot the root turn is owed.
        if (ctx.root.run_budget) |budget| if (budget.remaining() <= 1) return;
        const provider = cheapProvider(ctx) orelse return;
        const digest = recap_mod.buildDigest(ctx.arena, ctx.root.messages.items) catch return;
        if (digest.len == 0) return;
        const job = ctx.gpa.create(Job) catch return;
        const owned_input = ctx.gpa.dupe(u8, digest) catch {
            ctx.gpa.destroy(job);
            return;
        };
        job.* = .{ .input = owned_input, .generation = ctx.root.recap_generation };
        const args = .{ job, ctx.gpa, ctx.io, ctx.root.client, provider, ctx.root.run_budget, ctx.root.tracer };
        job.future = ctx.io.concurrent(detachedTask, args) catch ctx.io.async(detachedTask, args);
        self.items.append(ctx.gpa, job) catch {
            if (job.future) |*future| future.cancel(ctx.io);
            if (job.result) |recap| ctx.gpa.free(recap.text);
            ctx.gpa.free(job.input);
            ctx.gpa.destroy(job);
        };
    }

    pub fn poll(self: *Jobs, ctx: anytype) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            const job = self.items.items[i];
            if (!job.done.load(.acquire)) {
                i += 1;
                continue;
            }
            if (job.future) |*future| future.await(ctx.io); // done=true: never blocks
            job.future = null;
            if (job.result) |recap| {
                // A turn that started after this job was scheduled supersedes
                // it — the newer turn's own recap will describe the session.
                if (job.generation == ctx.root.recap_generation) publish(ctx, recap, "model");
                ctx.gpa.free(recap.text);
            }
            ctx.gpa.free(job.input);
            _ = self.items.orderedRemove(i);
            ctx.gpa.destroy(job);
        }
    }

    pub fn deinit(self: *Jobs, ctx: anytype) void {
        for (self.items.items) |job| {
            if (job.future) |*future| future.cancel(ctx.io);
            if (job.result) |recap| ctx.gpa.free(recap.text);
            ctx.gpa.free(job.input);
            ctx.gpa.destroy(job);
        }
        self.items.deinit(ctx.gpa);
    }
};
