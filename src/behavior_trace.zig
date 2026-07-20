//! Per-run behavioral event stream (`codegraff.behavior.v1`): the
//! experimental lifecycle/belief envelope and the BehaviorTrace producer with
//! its independent local + upload sinks. Split out of trace.zig (600-line
//! goal); trace.zig re-exports the public names so call sites are unchanged.
//! Schema + privacy contract: docs/behavioral-trajectories.md.
//! Tests live in behavior_trace_tests.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const behavior_upload = @import("behavior_upload.zig");
const session_start = @import("session_start.zig");
const scoring = @import("scoring.zig");
const trace = @import("trace.zig");

test {
    _ = @import("behavior_trace_tests.zig");
}

// ── Behavioral trace (one experimental event file per run) ────────────────

pub const behavior_dir = ".graff/trajectories";
pub const behavior_schema = "codegraff.behavior.v1";

/// Task-agnostic behavioral records. Per-kind fields stay flat, matching the
/// schema-harness event shape; state/action/expect values remain opaque JSON.
pub const BehaviorKind = enum {
    run_started,
    turn_started,
    text_delta,
    tool_started,
    tool_finished,
    turn_committed,
    action_taken,
    model_mispredicted,
    run_finished,
};

/// Typed lifecycle status; `.failed` is serialized as the JSON value `error`.
pub const BehaviorRunStatus = enum {
    closed,
    failed,
};

pub const max_local_behavior_event_bytes = 64 * 1024;

/// Serialize a behavioral event as one flat JSON object. `fields` must be a
/// struct; its fields are appended after the common envelope. Building the
/// full line before writing prevents serialization failures from corrupting the
/// file. The fixed 64 KiB line buffer also prevents an opaque adapter value from
/// causing unbounded temporary allocation. A write failure disables the stream
/// so a partial tail is never joined to a later event.
pub fn writeBehaviorLine(gpa: Allocator, w: *Io.Writer, kind: BehaviorKind, seq: u64, ts: f64, run_id: []const u8, fields: anytype) bool {
    const backing = gpa.alloc(u8, max_local_behavior_event_bytes + 1) catch return false;
    defer gpa.free(backing);
    var line: Io.Writer = .fixed(backing);
    var s: std.json.Stringify = .{ .writer = &line };
    s.beginObject() catch return false;
    s.objectField("kind") catch return false;
    s.write(@tagName(kind)) catch return false;
    s.objectField("seq") catch return false;
    s.write(seq) catch return false;
    s.objectField("ts") catch return false;
    s.write(ts) catch return false;
    s.objectField("run_id") catch return false;
    s.write(run_id) catch return false;
    s.objectField("schema") catch return false;
    s.write(behavior_schema) catch return false;
    inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |name| {
        comptime {
            if (std.mem.eql(u8, name, "kind") or
                std.mem.eql(u8, name, "seq") or
                std.mem.eql(u8, name, "ts") or
                std.mem.eql(u8, name, "run_id") or
                std.mem.eql(u8, name, "schema"))
            {
                @compileError("behavioral event field collides with the common envelope: " ++ name);
            }
        }
        s.objectField(name) catch return false;
        s.write(@field(fields, name)) catch return false;
    }
    s.endObject() catch return false;
    if (line.buffered().len > max_local_behavior_event_bytes) return false;
    line.writeByte('\n') catch return false;
    w.writeAll(line.buffered()) catch return false;
    w.flush() catch return false;
    return true;
}

/// Per-run behavioral event stream written to
/// `.graff/trajectories/<run_id>.jsonl`. `seq` is contiguous file order for
/// this run and starts at one. `ts` is Unix time in fractional seconds. Every
/// event carries `run_id` and `schema`, so it remains attributable even if run
/// files are later merged. Payload fields are plaintext and are not sanitized;
/// callers must explicitly avoid secrets and proprietary content.
pub fn commitmentRef(key: *const [32]u8, commitment_id: []const u8) [16]u8 {
    // The random key never leaves this process, so low-entropy adapter IDs
    // cannot be recovered from uploaded references with an offline dictionary.
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(key);
    hash.update(&.{0});
    hash.update(commitment_id);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

pub const BehaviorRunMetadata = struct {
    provider: []const u8 = "",
    model: []const u8 = "",
    prompt_sha: []const u8 = "",
    effort: []const u8 = "",
};

pub const BehaviorTrace = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    out: ?*Io.Writer,
    upload: ?*behavior_upload.Upload = null,
    run_id: []const u8,
    seq: u64 = 0,
    current_turn: u64 = 0,
    turn_active: bool = false,
    started: bool = false,
    closed: bool = false,
    commitment_key: [32]u8 = undefined,
    commitment_key_initialized: bool = false,

    fn timestamp(self: *BehaviorTrace) f64 {
        const now = Io.Timestamp.now(self.io, .real);
        return @as(f64, @floatFromInt(now.nanoseconds)) / 1_000_000_000.0;
    }

    /// Emit to the independent local and upload sinks. The return value says
    /// whether the upload retained this event; callers otherwise do not couple
    /// sink health. In particular, finish() uses it so `complete=true` cannot
    /// describe a batch whose terminal event was dropped during admission.
    fn eventLocked(self: *BehaviorTrace, kind: BehaviorKind, local_fields: anytype, metadata_fields: anytype, content_fields: anytype) bool {
        if (self.closed or self.seq == std.math.maxInt(u64)) return false;
        const uploader_active = if (self.upload) |uploader| uploader.active() else false;
        if (self.out == null and !uploader_active) return false;

        // This is the logical source sequence, reserved before either
        // independent sink is attempted. A bounded upload may therefore have
        // gaps, reported by dropped_events, while the local file remains a
        // contiguous prefix until any terminal write failure.
        const next = self.seq + 1;
        self.seq = next;
        const ts = self.timestamp();
        if (self.out) |w| {
            if (!writeBehaviorLine(self.gpa, w, kind, next, ts, self.run_id, local_fields)) {
                // Do not append after a possible partial write. Upload remains
                // independent so a local disk failure need not erase metadata.
                self.out = null;
            }
        }
        if (self.upload) |uploader| {
            return uploader.appendEvent(@tagName(kind), next, ts, metadata_fields, content_fields);
        }
        return false;
    }

    /// Start this run exactly once. The generic serializer stays private so
    /// callers cannot accidentally emit a kind without its required fields.
    pub fn start(self: *BehaviorTrace, version: []const u8, unix_ms: i64) void {
        self.startWithMetadata(version, unix_ms, .{});
    }

    pub fn startWithMetadata(self: *BehaviorTrace, version: []const u8, unix_ms: i64, metadata: BehaviorRunMetadata) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.started or self.closed) return;
        self.io.randomSecure(&self.commitment_key) catch self.io.random(&self.commitment_key);
        self.commitment_key_initialized = true;
        self.started = true;
        const local_fields = .{
            .version = version,
            .unix_ms = unix_ms,
            .provider = metadata.provider,
            .model = metadata.model,
            .prompt_sha = metadata.prompt_sha,
            .effort = metadata.effort,
        };
        // A deterministic prompt fingerprint is useful in the local trace but
        // remains prompt-derived data: even a truncated digest can disclose a
        // low-entropy prompt through enumeration. Never include it in either
        // network projection.
        const upload_fields = .{
            .version = version,
            .unix_ms = unix_ms,
            .provider = metadata.provider,
            .model = metadata.model,
            .effort = metadata.effort,
        };
        _ = self.eventLocked(.run_started, local_fields, upload_fields, upload_fields);
    }

    /// Begin one root turn. Behavioral turn IDs are dense and independent of
    /// legacy trajectory node IDs, which can skip as child agents are added.
    pub fn beginTurn(self: *BehaviorTrace, trajectory_node: u64) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.started or self.closed or self.current_turn == std.math.maxInt(u64)) return 0;
        const parent_turn = self.current_turn;
        const turn = parent_turn + 1;
        self.current_turn = turn;
        self.turn_active = true;
        const fields = .{
            .turn = turn,
            .parent_turn = parent_turn,
            .trajectory_node = trajectory_node,
        };
        _ = self.eventLocked(.turn_started, fields, fields, fields);
        return turn;
    }

    /// Clear attribution only for the matching active turn. The last turn ID is
    /// retained separately in current_turn so the next turn keeps a dense parent
    /// chain, while late administrative API/tool work is attributed to turn 0.
    pub fn endTurn(self: *BehaviorTrace, turn: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (turn != 0 and self.turn_active and turn == self.current_turn) self.turn_active = false;
    }

    pub fn currentTurn(self: *BehaviorTrace) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.turn_active) self.current_turn else 0;
    }

    /// Assert that a task adapter observed a committed action and expectation.
    /// This records the caller's belief; it does not execute or verify the action.
    pub fn recordExpectedAction(self: *BehaviorTrace, turn: u64, commitment_id: []const u8, action: anytype, expected: anytype, reason: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.started or self.closed or !self.turn_active or turn == 0 or turn != self.current_turn or commitment_id.len == 0) return;
        const local_fields = .{
            .turn = turn,
            .commitment_id = commitment_id,
            .action = action,
            .expect = expected,
            .reason = reason,
        };
        std.debug.assert(self.commitment_key_initialized);
        const commitment_ref = commitmentRef(&self.commitment_key, commitment_id);
        _ = self.eventLocked(.turn_committed, local_fields, .{
            .turn = turn,
            .commitment_ref = &commitment_ref,
        }, local_fields);
    }

    /// Assert that a caller or task-specific verifier found a contradiction.
    /// No generic semantic comparison is attempted by this backend.
    pub fn recordMisprediction(self: *BehaviorTrace, turn: u64, commitment_id: []const u8, predicted: anytype, actual: anytype, detail: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.started or self.closed or !self.turn_active or turn == 0 or turn != self.current_turn or commitment_id.len == 0) return;
        const local_fields = .{
            .turn = turn,
            .commitment_id = commitment_id,
            .predicted = predicted,
            .actual = actual,
            .detail = detail,
        };
        std.debug.assert(self.commitment_key_initialized);
        const commitment_ref = commitmentRef(&self.commitment_key, commitment_id);
        _ = self.eventLocked(.model_mispredicted, local_fields, .{
            .turn = turn,
            .commitment_ref = &commitment_ref,
        }, local_fields);
    }

    /// Attach content-free operational aggregates to the active root turn.
    /// These are not behavioral tool events: no invocation identity, argument,
    /// result, or action semantics are inferred from the operational hook.
    pub fn recordApiMetric(
        self: *BehaviorTrace,
        from_subagent: bool,
        ms: i64,
        req_bytes: usize,
        resp_bytes: usize,
        context_tokens: u64,
        cache_read_tokens: u64,
        is_error: bool,
    ) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.started or self.closed or !self.turn_active) return 0;
        const turn = self.current_turn;
        if (self.upload) |uploader| uploader.recordApi(turn, from_subagent, ms, req_bytes, resp_bytes, context_tokens, cache_read_tokens, is_error);
        return turn;
    }

    pub fn recordToolMetric(self: *BehaviorTrace, name: []const u8, from_subagent: bool, ms: i64, result_bytes: usize, is_error: bool) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.started or self.closed or !self.turn_active) return 0;
        const turn = self.current_turn;
        if (self.upload) |uploader| uploader.recordTool(turn, name, from_subagent, ms, result_bytes, is_error);
        return turn;
    }

    const FinishState = struct {
        uploader: ?*behavior_upload.Upload,
        complete: bool,
    };

    pub fn prepareFinish(self: *BehaviorTrace, status_name: []const u8) ?FinishState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return null;

        var terminal_retained = false;
        if (self.started) {
            const fields = .{ .status = status_name };
            terminal_retained = self.eventLocked(.run_finished, fields, fields, fields);
        }
        self.turn_active = false;
        self.closed = true;
        return .{
            .uploader = self.upload,
            // This flag describes the uploaded lifecycle, not merely process
            // control flow. A dropped terminal event must remain incomplete.
            .complete = self.started and (self.upload == null or terminal_retained),
        };
    }

    /// Mark a normal process/session close. This is deliberately not a task
    /// success verdict. A missing run_finished record means the run is incomplete.
    pub fn finish(self: *BehaviorTrace, status: BehaviorRunStatus) void {
        const status_name: []const u8 = switch (status) {
            .closed => "closed",
            .failed => "error",
        };
        const state = self.prepareFinish(status_name) orelse return;
        // Network I/O is terminal and bounded, but it must not hold the mutex
        // used by concurrent API/tool callbacks.
        if (state.uploader) |uploader| uploader.send(state.complete, status_name);
    }
};

// ── Session bootstrap (main's sink wiring, 600-line goal) ─────────────────

/// The two behavioral sinks owned by main()'s frame: the privacy-projected
/// uploader and the local JSONL behind `behavior`. Construct with boot(),
/// then call link() exactly once after the value has settled at its final
/// address — openBehaviorFile's writer is only safe to point at after the
/// copy has landed (see session_start.zig's FileWriterOpen header).
pub const Boot = struct {
    io: Io,
    uploader: behavior_upload.Upload,
    open: session_start.FileWriterOpen,
    behavior: BehaviorTrace,

    /// Point the behavior stream at this Boot's settled storage and assign
    /// the shared tracer. All root/subagent callbacks already share that
    /// stable tracer, so this single assignment covers every producer.
    pub fn link(self: *Boot, tracer: ?*trace.Tracer) void {
        self.behavior.out = if (self.open.file != null) &self.open.writer.interface else null;
        self.behavior.upload = if (self.uploader.active()) &self.uploader else null;
        if (tracer) |tr| tr.behavior = &self.behavior;
    }

    /// Terminal lifecycle event + upload, then close/deinit both sinks. A
    /// clean return is not a task success verdict; finish() is idempotent and
    /// keeps an earlier error-unwind status terminal.
    pub fn finishAndClose(self: *Boot, tracer: ?*trace.Tracer, status: BehaviorRunStatus) void {
        self.behavior.finish(status);
        if (tracer) |tr| tr.behavior = null;
        if (self.open.file) |f| f.close(self.io);
        self.uploader.deinit();
    }
};

/// Construct the behavioral sinks for an agent session. Behavioral tracing
/// starts only after the root Agent exists, so utility and self-test paths do
/// not create zero-turn behavioral runs. The local JSONL and the
/// privacy-projected upload are independent sinks. `buf` storage is owned by
/// the caller (a stack array in main()) and must outlive the Boot.
pub fn boot(io: Io, gpa: Allocator, client: ?*std.http.Client, environ_map: anytype, endpoint: []const u8, auth_key: ?[]const u8, install_id: [32]u8, client_name: []const u8, service_version: []const u8, buf: []u8) Boot {
    const uploader: behavior_upload.Upload = .{
        .io = io,
        .gpa = gpa,
        .client = client,
        .endpoint = endpoint,
        .auth_key = auth_key,
        .install_id = install_id,
        .client_name = client_name,
        .service_version = service_version,
        .run_id = &scoring.g_run_id,
        .mode = behavior_upload.resolveMode(environ_map.get("GRAFF_BEHAVIOR_UPLOAD"), endpoint.len > 0),
    };
    const enabled = if (environ_map.get("GRAFF_BEHAVIOR_TRACE")) |value|
        !(std.ascii.eqlIgnoreCase(value, "off") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no"))
    else
        true;
    const open = if (enabled)
        session_start.openBehaviorFile(io, Io.Dir.cwd(), behavior_dir, &scoring.g_run_id, buf)
    else
        session_start.FileWriterOpen{ .file = null, .writer = undefined };
    return .{
        .io = io,
        .uploader = uploader,
        .open = open,
        .behavior = .{
            .io = io,
            .gpa = gpa,
            .out = null,
            .upload = null,
            .run_id = &scoring.g_run_id,
        },
    };
}
