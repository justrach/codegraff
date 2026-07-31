//! User-controlled deletion of one remote aggregate learning receipt.
//! Local genomes, evidence, and immutable run history are never changed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const eval = @import("learn_eval.zig");
const learn_run = @import("learn_run.zig");
const mcp_teardown = @import("mcp_teardown.zig");
const receipt = @import("learn_receipt.zig");
const scoring = @import("scoring.zig");
const store_mod = @import("learn_store.zig");
const submit = @import("learn_submit.zig");
const telemetry_net = @import("telemetry_net.zig");

/// How long the collector gets to answer one DELETE before we stop waiting.
const delete_deadline = Io.Duration.fromSeconds(10);

fn learningUrl(gpa: Allocator, endpoint: []const u8, run_id: []const u8) ![]u8 {
    const logs_url = (try telemetry_net.otlpLogsUrl(gpa, endpoint)) orelse
        return error.InvalidTelemetryEndpoint;
    defer gpa.free(logs_url);
    const query_at = std.mem.indexOfScalar(u8, logs_url, '?') orelse logs_url.len;
    const path = logs_url[0..query_at];
    if (!std.mem.endsWith(u8, path, "/v1/logs")) return error.InvalidTelemetryEndpoint;
    const base = path[0 .. path.len - "/v1/logs".len];
    return std.fmt.allocPrint(gpa, "{s}/v1/learning/{s}{s}", .{ base, run_id, logs_url[query_at..] });
}

fn deleteRequest(client: *std.http.Client, url: []const u8, token: []const u8) u16 {
    const headers = [_]std.http.Header{.{ .name = "x-learning-delete-token", .value = token }};
    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .DELETE,
        .extra_headers = &headers,
    }) catch return 0;
    return @intFromEnum(response.status);
}

/// One DELETE plus every byte it touches, in heap state the caller does not
/// own. A request that overruns the deadline keeps running on a detached
/// thread (#303), so nothing it reads may live in the caller's frame, and its
/// client draws on a process-lifetime allocator rather than the session gpa:
/// pool memory left behind by an abandoned request would otherwise surface in
/// the gpa's exit-time leak report and read as a harness bug.
const Deletion = struct {
    client: std.http.Client,
    url: []u8,
    token: []u8,
    status: u16 = 0,

    fn create(heap: Allocator, io: Io, url: []const u8, token: []const u8) !*Deletion {
        const self = try heap.create(Deletion);
        errdefer heap.destroy(self);
        const url_copy = try heap.dupe(u8, url);
        errdefer heap.free(url_copy);
        self.* = .{
            .client = .{ .allocator = heap, .io = io },
            .url = url_copy,
            .token = try heap.dupe(u8, token),
        };
        return self;
    }

    fn destroy(self: *Deletion, heap: Allocator) void {
        self.client.deinit();
        heap.free(self.token);
        heap.free(self.url);
        heap.destroy(self);
    }

    fn send(self: *Deletion) void {
        self.status = deleteRequest(&self.client, self.url, self.token);
    }
};

/// Run `send(state)` under `deadline` and read back the status it recorded,
/// or null when the deadline wins.
///
/// #303: work that overruns the deadline is ABANDONED, never cancelled. The
/// old shape raced the request against the deadline in an Io.Select and then
/// called cancelDiscard(), which cancels AND synchronously joins whatever is
/// left. Against the real TLS collector that cancel landed inside an in-flight
/// read and panicked, so `learn delete-remote` crashed instead of reporting a
/// failure, and deletion is the one guarantee a user cannot work around.
/// mcp_teardown.runBounded (#305) exists for exactly this shape: it detaches
/// the work, waits out the deadline, and walks away without touching it again.
fn statusWithin(io: Io, deadline: Io.Duration, comptime send: anytype, state: anytype) ?u16 {
    // page_allocator, not the session gpa: the bookkeeping for an abandoned
    // task is leaked on purpose and must not read as a harness leak at exit.
    if (!mcp_teardown.runBounded(std.heap.page_allocator, io, deadline, send, .{state})) return null;
    return state.status;
}

fn deleteWithDeadline(io: Io, url: []const u8, token: []const u8) u16 {
    const heap = std.heap.page_allocator;
    const deletion = Deletion.create(heap, io, url, token) catch return 0;
    // Nothing is reclaimed on the null branch: the request is still in flight
    // on a detached thread, so `deletion` is leaked on purpose (#303).
    const status = statusWithin(io, delete_deadline, Deletion.send, deletion) orelse return 0;
    deletion.destroy(heap);
    return status;
}

pub fn command(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    run_id: []const u8,
    lock_timeout_ms: u64,
    out: *Io.Writer,
) !void {
    var store = try store_mod.Store.openAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(lock_timeout_ms);
    defer lock.deinit();
    const bytes = try store.readRun(arena, run_id);
    const run = try std.json.parseFromSliceLeaky(eval.RunRecord, arena, bytes, .{});
    try eval.validateRun(run);
    const expected_trial = learn_run.trialId(
        run.config_id,
        run.parent_genome_id,
        run.parent_generation,
        run.parent_transaction_id,
        run.nonce,
    );
    if (!std.mem.eql(u8, run.trial_id, &expected_trial)) return error.TrialMismatch;

    scoring.g_score_key = scoring.loadScoreKey(io, arena, environ) orelse
        return error.ScoreSigningKeyRequired;
    const token = receipt.deletionToken(run_id, run.nonce);
    if (token[0] == 0) return error.ScoreSigningKeyRequired;
    const endpoint = try submit.deletionEndpoint(environ);
    const url = try learningUrl(gpa, endpoint, run_id);
    defer gpa.free(url);
    switch (deleteWithDeadline(io, url, &token)) {
        200, 202, 204 => try out.print(
            "deleted remote aggregate receipt for run {s}; local evidence was not changed\n",
            .{run_id},
        ),
        404 => return error.RemoteReceiptNotFoundOrUnauthorized,
        409 => return error.RemoteReceiptPredatesDeletion,
        else => return error.RemoteReceiptDeletionFailed,
    }
}

test "learning receipt URL preserves endpoint query parameters" {
    const gpa = std.testing.allocator;
    const run_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const url = try learningUrl(gpa, "https://collector.example/base?token=x#drop", run_id);
    defer gpa.free(url);
    try std.testing.expectEqualStrings(
        "https://collector.example/base/v1/learning/" ++ run_id ++ "?token=x",
        url,
    );
}

test "a DELETE that overruns its deadline is abandoned, not cancelled (#303)" {
    // #303: `learn delete-remote` panicked against the real TLS collector
    // because the deadline branch cancelled the losing request arm, and
    // Io.Select.cancelDiscard() cancels AND synchronously joins its loser.
    // The stall below parks where Io has no cancelation point at all, which
    // is what an in-flight read looks like to a canceller: an implementation
    // that joins its loser cannot come back before the stall ends, and this
    // test catches it by finding the request already finished.
    const Stall = struct {
        io: Io,
        status: u16 = 200,
        finished: std.atomic.Value(bool) = .init(false),

        fn send(self: *@This()) void {
            // A spin, not io.sleep: io.sleep IS cancelable, so a sleeping
            // stall would let the very shape this test rejects pass.
            const end = Io.Timestamp.now(self.io, .awake).nanoseconds + 3 * std.time.ns_per_s;
            while (Io.Timestamp.now(self.io, .awake).nanoseconds < end) std.atomic.spinLoopHint();
            self.finished.store(true, .release);
        }
    };
    const io = std.testing.io;
    // page_allocator: abandoned state is leaked by design, and a
    // leak-checking allocator would misreport that as a test failure.
    const heap = std.heap.page_allocator;
    const stall = try heap.create(Stall);
    stall.* = .{ .io = io };
    try std.testing.expect(statusWithin(io, .fromMilliseconds(50), Stall.send, stall) == null);
    // Asserted on STATE, not on the clock: a shared CI runner makes elapsed
    // time a flaky proxy, but "the request is still running" is exact.
    try std.testing.expect(!stall.finished.load(.acquire));
}
