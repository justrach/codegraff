//! Detached AI-title jobs for the root loop. The caller context is generic so
//! this module stays independent of `mainloop.zig`'s orchestration type.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const session = @import("session.zig");
const title_mod = @import("title.zig");

const Job = struct {
    future: ?Io.Future(void) = null,
    prompt: []const u8, // gpa-owned: readline storage may be reused next turn
    result: ?[]const u8 = null, // gpa-owned, published before done.release
    done: std.atomic.Value(bool) = .init(false),
    generation: u64,
};

fn apply(ctx: anytype, title: []const u8) void {
    ctx.root.session_title = ctx.arena.dupe(u8, title) catch null;
    if (ctx.root.session_title) |stored| {
        title_mod.setTerminalTitle(ctx.out, stored, main_mod.g_cwd_display);
        session.renameSession(ctx.root, ctx.arena, session.slugifyTitle(ctx.arena, stored));
    }
}

fn detachedTask(job: *Job, gpa: Allocator, io: Io, client: *std.http.Client, provider: provider_mod.Provider, budget: ?*@import("run_budget.zig").RunBudget, tracer: ?*@import("trace.zig").Tracer) void {
    job.result = title_mod.titleTask(gpa, io, client, provider, job.prompt, budget, tracer);
    job.done.store(true, .release);
}

/// Session title tasks are polled without waiting and canceled only at close.
pub const Jobs = struct {
    items: std.ArrayList(*Job) = .empty,

    pub fn start(self: *Jobs, ctx: anytype, prompt: []const u8) void {
        // An explicitly tiny budget still owes the user a real answer. Do not
        // let cosmetic title work consume the final provider-call slot before
        // the root request has a chance to acquire it.
        if (ctx.root.run_budget) |budget| if (budget.remaining() <= 1) {
            if (ctx.root.tracer) |tr| tr.note("budget", "AI title skipped to reserve the final model call for the root turn");
            return;
        };
        const job = ctx.gpa.create(Job) catch return;
        const owned_prompt = ctx.gpa.dupe(u8, prompt) catch {
            ctx.gpa.destroy(job);
            return;
        };
        job.* = .{ .prompt = owned_prompt, .generation = ctx.root.title_generation };
        const args = .{ job, ctx.gpa, ctx.io, ctx.root.client, ctx.root.provider, ctx.root.run_budget, ctx.root.tracer };
        job.future = ctx.io.concurrent(detachedTask, args) catch ctx.io.async(detachedTask, args);
        self.items.append(ctx.gpa, job) catch {
            if (job.future) |*future| future.cancel(ctx.io);
            if (job.result) |title| ctx.gpa.free(title);
            ctx.gpa.free(job.prompt);
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
            if (job.result) |title| {
                // Manual rename/session reset wins over an older detached result.
                if (job.generation == ctx.root.title_generation and ctx.root.session_title == null)
                    apply(ctx, title);
                ctx.gpa.free(title);
            }
            ctx.gpa.free(job.prompt);
            _ = self.items.orderedRemove(i);
            ctx.gpa.destroy(job);
        }
    }

    pub fn deinit(self: *Jobs, ctx: anytype) void {
        for (self.items.items) |job| {
            if (job.future) |*future| future.cancel(ctx.io);
            if (job.result) |title| ctx.gpa.free(title);
            ctx.gpa.free(job.prompt);
            ctx.gpa.destroy(job);
        }
        self.items.deinit(ctx.gpa);
    }
};
