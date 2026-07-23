//! User-controlled deletion of one remote aggregate learning receipt.
//! Local genomes, evidence, and immutable run history are never changed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const eval = @import("learn_eval.zig");
const learn_run = @import("learn_run.zig");
const receipt = @import("learn_receipt.zig");
const scoring = @import("scoring.zig");
const store_mod = @import("learn_store.zig");
const submit = @import("learn_submit.zig");
const telemetry = @import("telemetry.zig");
const telemetry_net = @import("telemetry_net.zig");

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

fn deleteWithDeadline(io: Io, client: *std.http.Client, url: []const u8, token: []const u8) u16 {
    const Done = union(enum) { status: u16, deadline: void };
    var done_buf: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &done_buf);
    select.concurrent(.deadline, telemetry.Telemetry.flushDeadline, .{ io, Io.Duration.fromSeconds(10) }) catch return 0;
    select.concurrent(.status, deleteRequest, .{ client, url, token }) catch {
        select.cancelDiscard();
        return 0;
    };
    const first = select.await() catch {
        select.cancelDiscard();
        return 0;
    };
    select.cancelDiscard();
    return switch (first) {
        .status => |status| status,
        .deadline => 0,
    };
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
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    switch (deleteWithDeadline(io, &client, url, &token)) {
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
