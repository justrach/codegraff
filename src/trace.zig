//! Operational tracing, per-run behavioral traces, and the DGM trajectory
//! archive. Every invocation writes its own `.graff/traces/<run-id>.jsonl`
//! (performance telemetry) and `.graff/trajectories/<run-id>.jsonl` (DGM
//! archive nodes plus the experimental behavioral lifecycle/belief stream),
//! so independent graff processes never truncate or seek/write through the
//! same file. Every record is stamped with the run id, process id, and
//! runtime session id before the event's own fields. Also owns the per-agent
//! ToolSink summary.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const telemetry = @import("telemetry.zig");
const behavior_upload = @import("behavior_upload.zig");

pub const traces_dir = ".graff/traces";
pub const trajectories_dir = ".graff/trajectories";
pub const legacy_trajectory_path = "harness.trajectory.jsonl";

/// Stable metadata prepended to every trace and trajectory record.
pub const Identity = struct {
    run_id: []const u8 = "",
    pid: u64 = 0,
    session_id: []const u8 = "",
};

pub fn currentPid() u64 {
    return if (builtin.os.tag == .windows)
        @intCast(std.os.windows.GetCurrentProcessId())
    else
        @intCast(std.posix.system.getpid());
}

pub fn newSessionId(io: Io) [32]u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

pub fn tracePath(allocator: Allocator, run_id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ traces_dir, run_id });
}

pub fn trajectoryPath(allocator: Allocator, run_id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ trajectories_dir, run_id });
}

/// Serialize one record as a single JSON line into an in-memory buffer, then
/// write the whole line to `w` in one shot. Building the line in memory first
/// means a partial serialization failure writes *nothing* — the shared buffered
/// file writer never sees a half-record, and the trailing newline is always
/// attached to its record. Without this, a write that errored mid-record left a
/// truncated line plus leftover buffer bytes that the next record concatenated
/// onto, corrupting the JSONL (issue #86: lines like `{"text":"You ar{"kind":…`).
/// Flushing per line keeps the buffer empty between records. Best-effort.
/// Returns `false` only when the *file* write/flush fails. A failed drain can
/// leave the shared buffered writer's offset desynced from the bytes actually on
/// disk; the caller must then stop using the writer, otherwise the next record
/// lands at the drifted offset and leaves a sparse NUL gap or splices onto a
/// half-written record — the large NUL holes + prefix-less fragments seen in long
/// sessions (issue #242). In-memory serialization failures (OOM) return `true`:
/// they wrote nothing to disk, so the writer stays consistent and tracing
/// continues (best-effort, per #86).
fn writeJsonLine(gpa: Allocator, w: *Io.Writer, identity: Identity, rec: anytype) bool {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.beginObject() catch return true;
    s.objectField("run_id") catch return true;
    s.write(identity.run_id) catch return true;
    s.objectField("pid") catch return true;
    s.write(identity.pid) catch return true;
    s.objectField("session_id") catch return true;
    s.write(identity.session_id) catch return true;
    const Rec = @TypeOf(rec);
    switch (@typeInfo(Rec)) {
        .@"struct" => inline for (comptime std.meta.fieldNames(Rec)) |field_name| {
            // Identity owns these top-level names. Event-specific provenance
            // must use a more precise name such as `score_run_id`.
            if (comptime std.mem.eql(u8, field_name, "run_id") or
                std.mem.eql(u8, field_name, "pid") or
                std.mem.eql(u8, field_name, "session_id")) continue;
            s.objectField(field_name) catch return true;
            s.write(@field(rec, field_name)) catch return true;
        },
        else => @compileError("trace records must be structs"),
    }
    s.endObject() catch return true;
    aw.writer.writeByte('\n') catch return true;
    // The record is fully built; one writeAll keeps it atomic under the caller's
    // mutex. A failure here means the on-disk offset may be desynced — tell the
    // caller to stop (see the doc comment).
    w.writeAll(aw.writer.buffered()) catch return false;
    w.flush() catch return false;
    return true;
}

/// Session event trace: one JSON object per line in the run's unique file.
/// Thread-safe — agents on pool threads share it through the mutex. The
/// system prompt tells the agent the file exists, so it can read its own
/// trace to debug or profile the harness ("t" is ms since session start).
pub const Tracer = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    out: ?*Io.Writer,
    start: Io.Timestamp,
    identity: Identity = .{},
    path: []const u8 = "",
    enabled: bool = true,
    // Assigned once before the first root turn. Keeping this on the stable
    // shared tracer avoids a process-global pointer race on worker callbacks.
    behavior: ?*BehaviorTrace = null,

    pub fn api(self: *Tracer, label: []const u8, from_subagent: bool, model: []const u8, ms: i64, req_bytes: usize, resp_bytes: usize, context_tokens: u64, cache_read: u64, is_error: bool) void {
        if (telemetry.g_telem) |t| t.countApi(model, is_error);
        const behavior_turn = if (self.behavior) |behavior|
            behavior.recordApiMetric(from_subagent, ms, req_bytes, resp_bytes, context_tokens, cache_read, is_error)
        else
            0;
        self.write(.{
            .t = self.elapsedMs(),
            .ev = "api",
            .turn = behavior_turn,
            .agent = label,
            .model = model,
            .ms = ms,
            .req_bytes = req_bytes,
            .resp_bytes = resp_bytes,
            .context_tokens = context_tokens,
            .cache_read_tokens = cache_read,
            .is_error = is_error,
        });
    }

    pub fn tool(self: *Tracer, name: []const u8, ms: i64, is_error: bool, result_bytes: usize, from_sub: bool) void {
        if (telemetry.g_telem) |t| t.countTool(is_error);
        const behavior_turn = if (self.behavior) |behavior|
            behavior.recordToolMetric(name, from_sub, ms, result_bytes, is_error)
        else
            0;
        self.write(.{
            .t = self.elapsedMs(),
            .ev = "tool",
            .turn = behavior_turn,
            .name = name,
            .ms = ms,
            .result_bytes = result_bytes,
            .is_error = is_error,
            .from_sub = from_sub,
        });
    }

    pub fn note(self: *Tracer, kind: []const u8, detail: []const u8) void {
        self.write(.{ .t = self.elapsedMs(), .ev = kind, .detail = detail });
    }

    pub fn elapsedMs(self: *Tracer) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    /// Serialize any struct as one JSON line. Best-effort: trace failures
    /// never disturb the session.
    pub fn write(self: *Tracer, event: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const w = self.out orelse return;
        if (!self.enabled) return;
        // Drop the writer on a file-write failure: a desynced offset would
        // otherwise corrupt later records (sparse NUL holes / spliced lines, #242).
        if (!writeJsonLine(self.gpa, w, self.identity, event)) self.out = null;
    }

    pub fn toggle(self: *Tracer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.enabled = !self.enabled;
        return self.enabled;
    }
};

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

const max_local_behavior_event_bytes = 64 * 1024;

/// Serialize a behavioral event as one flat JSON object. `fields` must be a
/// struct; its fields are appended after the common envelope. Building the
/// full line before writing prevents serialization failures from corrupting the
/// file. The fixed 64 KiB line buffer also prevents an opaque adapter value from
/// causing unbounded temporary allocation. A write failure disables the stream
/// so a partial tail is never joined to a later event.
fn writeBehaviorLine(gpa: Allocator, w: *Io.Writer, kind: BehaviorKind, seq: u64, ts: f64, run_id: []const u8, fields: anytype) bool {
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
    inline for (std.meta.fields(@TypeOf(fields))) |field| {
        comptime {
            if (std.mem.eql(u8, field.name, "kind") or
                std.mem.eql(u8, field.name, "seq") or
                std.mem.eql(u8, field.name, "ts") or
                std.mem.eql(u8, field.name, "run_id") or
                std.mem.eql(u8, field.name, "schema"))
            {
                @compileError("behavioral event field collides with the common envelope: " ++ field.name);
            }
        }
        s.objectField(field.name) catch return false;
        s.write(@field(fields, field.name)) catch return false;
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
fn commitmentRef(key: *const [32]u8, commitment_id: []const u8) [16]u8 {
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

    fn prepareFinish(self: *BehaviorTrace, status_name: []const u8) ?FinishState {
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

// ── Trajectory (DGM-style archive tree) ────────────────────────────────────

/// Session trajectory in the shape of the Darwin Gödel Machine's archive
/// tree (arXiv:2505.22954): one JSON node per agent run. Root turns form
/// the spine (each turn's parent is the previous turn); every subagent or
/// workflow task hangs off the turn that spawned it. Each node carries a
/// fingerprint of the system prompt it ran with, so prompt mutations —
/// set_system_prompt on the spine, per-child system_prompt overrides on the
/// fan-out — are visible as hash changes along edges, and a lineage can be
/// replayed or scored offline (see docs/hyperagents.md, arXiv:2603.19461).
/// Written to the invocation's unique trajectory file. Archive readers scan
/// the directory and also ingest the legacy single-file archive read-only.
pub const Trajectory = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    out: ?*Io.Writer,
    start: Io.Timestamp,
    identity: Identity = .{},
    path: []const u8 = "",
    next_id: u64 = 1, // node 0 is the session itself
    turn_node: u64 = 0, // current root-turn node: parent for spawned agents
    seen_shas: std.ArrayList([16]u8) = .empty, // prompts captured this session

    /// Reserve a node id (turns claim theirs before running so children can
    /// point at them).
    pub fn nextId(self: *Trajectory) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn setTurn(self: *Trajectory, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.turn_node = id;
    }

    pub fn currentTurn(self: *Trajectory) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.turn_node;
    }

    pub fn elapsedMs(self: *Trajectory) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    /// Serialize one node as a JSON line. Best-effort, like the Tracer.
    pub fn node(self: *Trajectory, rec: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.writeLocked(rec);
    }

    /// Capture the full prompt text behind a fingerprint, once per session
    /// (a `kind:"prompt"` record): the archive then maps sha → text so any
    /// lineage can be replayed or re-mutated offline. Dedup is per session;
    /// across sessions a sha repeats at most once per session — readers
    /// treat the records as an idempotent map.
    pub fn capturePrompt(self: *Trajectory, sha: [16]u8, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.out == null) return;
        for (self.seen_shas.items) |s| if (std.mem.eql(u8, &s, &sha)) return;
        self.seen_shas.append(self.gpa, sha) catch return;
        self.writeLocked(.{ .kind = "prompt", .prompt_sha = &sha, .text = text });
    }

    pub fn writeLocked(self: *Trajectory, rec: anytype) void {
        const w = self.out orelse return;
        // See Tracer.write: stop on a failed drain so a desynced offset can't
        // corrupt later records (#242).
        if (!writeJsonLine(self.gpa, w, self.identity, rec)) self.out = null;
    }

    pub fn deinit(self: *Trajectory) void {
        self.seen_shas.deinit(self.gpa);
    }
};

/// Set by main(); runSub and the REPL loop record nodes through this.
pub var g_traj: ?*Trajectory = null;

fn appendArchiveFile(io: Io, out: *Io.Writer, path: []const u8, remaining: *usize) bool {
    if (remaining.* == 0) return false;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    const size = std.math.cast(usize, stat.size) orelse return false;
    if (size == 0 or size > remaining.*) return false;
    var buf: [8 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    reader.interface.streamExact(out, size) catch return false;
    // A harmless blank separator also repairs a legacy file missing its final
    // newline, without retaining a second full-file copy just to inspect it.
    out.writeByte('\n') catch return false;
    remaining.* -= size;
    return true;
}

/// Read the local DGM archive across all run-scoped trajectory files. The old
/// `harness.trajectory.jsonl` is included read-only so existing scores remain
/// promotable after upgrading. Best-effort and capped across the whole archive.
pub fn readTrajectoryArchive(io: Io, arena: Allocator, max_bytes: usize) []const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    var remaining = max_bytes;

    var dir = Io.Dir.cwd().openDir(io, trajectories_dir, .{ .iterate = true }) catch
        return if (appendArchiveFile(io, &aw.writer, legacy_trajectory_path, &remaining)) aw.toOwnedSlice() catch "" else "";
    {
        defer dir.close(io);
        var it = dir.iterate();
        while (remaining > 0) {
            const entry = it.next(io) catch break;
            if (entry == null) break;
            if (entry.?.kind != .file or !std.mem.endsWith(u8, entry.?.name, ".jsonl")) continue;
            const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ trajectories_dir, entry.?.name }) catch continue;
            _ = appendArchiveFile(io, &aw.writer, path, &remaining);
        }
    }
    // Legacy rows remain readable, but current run files receive the cap first.
    _ = appendArchiveFile(io, &aw.writer, legacy_trajectory_path, &remaining);
    return aw.toOwnedSlice() catch "";
}

/// Begin one behavioral root turn at the common provider boundary, before any
/// model or tool work. Interactive mode may already have reserved a legacy DGM
/// node; one-shot and zigzag REPL modes deliberately leave that ledger unchanged.
pub fn beginRootTurn(tracer: ?*Tracer) u64 {
    const trajectory_node = if (g_traj) |tj| tj.currentTurn() else 0;
    const behavior = if (tracer) |tr| tr.behavior else null;
    return if (behavior) |bt| bt.beginTurn(trajectory_node) else 0;
}

/// End only the matching root-turn scope. Keeping this at the same provider
/// boundary prevents later administrative requests from inheriting its ID.
pub fn endRootTurn(tracer: ?*Tracer, turn: u64) void {
    const behavior = if (tracer) |tr| tr.behavior else null;
    if (behavior) |bt| bt.endTurn(turn);
}

/// Per-agent record of external tool calls (name + error flag, in call
/// order): the process signal behind "which tool combinations work" —
/// rendered into trajectory nodes and OTLP run events, joinable to scores
/// via prompt_sha. Tool fan-out is concurrent, so appends lock. Capped:
/// the first 64 calls are plenty for pattern mining.
pub const ToolSink = struct {
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { name: []const u8, err: bool };
    const cap = 64;

    pub fn add(self: *ToolSink, io: Io, gpa: Allocator, name: []const u8, err: bool) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.entries.items.len >= cap) return;
        self.entries.append(gpa, .{ .name = name, .err = err }) catch {};
    }

    /// "read_file,edit_file!,bash" — `!` marks a failed call. Allocated from
    /// `alloc`; "" when no tools ran. Call after the agent's tool futures
    /// are joined (no lock taken).
    pub fn render(self: *const ToolSink, alloc: Allocator) []const u8 {
        if (self.entries.items.len == 0) return "";
        var aw: Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) aw.writer.writeByte(',') catch return "";
            aw.writer.writeAll(e.name) catch return "";
            if (e.err) aw.writer.writeByte('!') catch return "";
        }
        return alloc.dupe(u8, aw.writer.buffered()) catch "";
    }

    pub fn errorCount(self: *const ToolSink) u64 {
        var total: u64 = 0;
        for (self.entries.items) |entry| total += @intFromBool(entry.err);
        return total;
    }

    pub fn clear(self: *ToolSink, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.entries.clearRetainingCapacity();
    }

    pub fn deinit(self: *ToolSink, gpa: Allocator) void {
        self.entries.deinit(gpa);
    }
};

fn expectObjectKeys(object: std.json.ObjectMap, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, object.count());
    for (expected) |key| try std.testing.expect(object.get(key) != null);
}

test "writeJsonLine: one complete newline-terminated JSON record per call" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const identity: Identity = .{ .run_id = "run-a", .pid = 42, .session_id = "session-a" };
    try std.testing.expect(writeJsonLine(std.testing.allocator, &aw.writer, identity, .{ .kind = "turn", .id = @as(u64, 7), .ok = true }));
    try std.testing.expect(writeJsonLine(std.testing.allocator, &aw.writer, identity, .{ .kind = "prompt", .text = "hi" }));
    const out = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    while (it.next()) |line| {
        var p = try std.json.parseFromSlice(Value, std.testing.allocator, line, .{});
        defer p.deinit();
        try std.testing.expect(p.value == .object); // each line parses as valid JSON
        try std.testing.expectEqualStrings("run-a", p.value.object.get("run_id").?.string);
        try std.testing.expectEqual(@as(i64, 42), p.value.object.get("pid").?.integer);
        try std.testing.expectEqualStrings("session-a", p.value.object.get("session_id").?.string);
    }
}

test "writeJsonLine signals a file-write failure so the tracer can disable (#242)" {
    // A fixed sink too small for a whole record forces the file write to fail.
    // writeJsonLine must return false so the caller drops the writer instead of
    // writing the next record at a desynced offset — the failure mode behind the
    // large NUL holes and prefix-less fragments in long sessions.
    const identity: Identity = .{ .run_id = "r", .pid = 1, .session_id = "s" };

    var tiny: [8]u8 = undefined;
    var wf = Io.Writer.fixed(&tiny);
    try std.testing.expect(!writeJsonLine(std.testing.allocator, &wf, identity, .{ .ev = "ws", .detail = "connecting" }));

    var big: [512]u8 = undefined;
    var wb = Io.Writer.fixed(&big);
    try std.testing.expect(writeJsonLine(std.testing.allocator, &wb, identity, .{ .ev = "ws", .detail = "connecting" }));
}

test "run-scoped paths separate traces and trajectories" {
    const trace_path = try tracePath(std.testing.allocator, "abc123");
    defer std.testing.allocator.free(trace_path);
    const trajectory_path = try trajectoryPath(std.testing.allocator, "abc123");
    defer std.testing.allocator.free(trajectory_path);
    try std.testing.expectEqualStrings(".graff/traces/abc123.jsonl", trace_path);
    try std.testing.expectEqualStrings(".graff/trajectories/abc123.jsonl", trajectory_path);
}

test "writeBehaviorLine: oversized adapter content is rejected before local allocation can grow" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const oversized = try gpa.alloc(u8, max_local_behavior_event_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expect(!writeBehaviorLine(gpa, &out.writer, .turn_committed, 1, 1.0, "0123456789abcdef", .{
        .turn = @as(u64, 1),
        .reason = oversized,
    }));
    try std.testing.expectEqual(@as(usize, 0), out.writer.buffered().len);
}

test "BehaviorTrace: events are flat, attributable, and ordered" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "run-test-1",
    };

    behavior.start("test", 1_234);
    behavior.start("ignored-duplicate", 9_999);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(7));
    behavior.recordExpectedAction(
        1,
        "commit-1",
        .{ .tool = "edit_file", .note = "line one\nline two ☃" },
        .{ .build = "passes", .attempts = @as(u64, 1) },
        "verify the edit compiles",
    );
    behavior.recordMisprediction(
        1,
        "commit-1",
        .{ .build = "passes" },
        .{ .build = "fails", .exit_code = @as(i64, 1) },
        "reported by a task-specific verifier",
    );
    behavior.finish(.closed);
    // Typed lifecycle methods cannot append after closure.
    behavior.recordExpectedAction(1, "late", .{ .tool = "bash" }, .{ .ok = true }, "too late");

    const out = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, out, "\n"));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');

    var started = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer started.deinit();
    try std.testing.expectEqualStrings("run_started", started.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), started.value.object.get("seq").?.integer);
    try std.testing.expect(started.value.object.get("ts").? == .float);
    try std.testing.expectEqualStrings("run-test-1", started.value.object.get("run_id").?.string);
    try std.testing.expectEqualStrings(behavior_schema, started.value.object.get("schema").?.string);
    try std.testing.expectEqualStrings("test", started.value.object.get("version").?.string);
    try std.testing.expectEqual(@as(i64, 1_234), started.value.object.get("unix_ms").?.integer);
    try std.testing.expect(started.value.object.get("payload") == null);

    var turn = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer turn.deinit();
    try std.testing.expectEqualStrings("turn_started", turn.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), turn.value.object.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 1), turn.value.object.get("turn").?.integer);
    try std.testing.expectEqual(@as(i64, 0), turn.value.object.get("parent_turn").?.integer);
    try std.testing.expectEqual(@as(i64, 7), turn.value.object.get("trajectory_node").?.integer);
    try std.testing.expectEqualStrings("run-test-1", turn.value.object.get("run_id").?.string);

    var committed = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer committed.deinit();
    try std.testing.expectEqualStrings("turn_committed", committed.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 3), committed.value.object.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 1), committed.value.object.get("turn").?.integer);
    try std.testing.expectEqualStrings("commit-1", committed.value.object.get("commitment_id").?.string);
    try std.testing.expectEqualStrings("line one\nline two ☃", committed.value.object.get("action").?.object.get("note").?.string);
    try std.testing.expectEqualStrings("passes", committed.value.object.get("expect").?.object.get("build").?.string);
    try std.testing.expectEqualStrings("verify the edit compiles", committed.value.object.get("reason").?.string);

    var mismatch = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer mismatch.deinit();
    try std.testing.expectEqualStrings("model_mispredicted", mismatch.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 4), mismatch.value.object.get("seq").?.integer);
    try std.testing.expectEqualStrings("commit-1", mismatch.value.object.get("commitment_id").?.string);
    try std.testing.expectEqualStrings("fails", mismatch.value.object.get("actual").?.object.get("build").?.string);
    try std.testing.expectEqualStrings("reported by a task-specific verifier", mismatch.value.object.get("detail").?.string);

    var finished = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer finished.deinit();
    try std.testing.expectEqualStrings("run_finished", finished.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 5), finished.value.object.get("seq").?.integer);
    try std.testing.expectEqualStrings("closed", finished.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("run-test-1", finished.value.object.get("run_id").?.string);
    try std.testing.expect(lines.next() == null);
}

test "BehaviorTrace: disabled writes do not consume sequence numbers" {
    const io = std.testing.io;
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = std.testing.allocator,
        .out = null,
        .run_id = "disabled-run",
    };

    behavior.start("test", 0);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(0));
    try std.testing.expectEqual(@as(u64, 0), behavior.seq);
    try std.testing.expectEqual(@as(u64, 1), behavior.currentTurn());
}

test "BehaviorTrace: typed APIs reject out-of-lifecycle adapter events" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "lifecycle-run",
    };

    try std.testing.expectEqual(@as(u64, 0), behavior.beginTurn(9));
    behavior.recordExpectedAction(1, "early", .{ .kind = "edit" }, .{ .ok = true }, "before start");
    behavior.start("test", 1);
    behavior.recordExpectedAction(1, "early", .{ .kind = "edit" }, .{ .ok = true }, "before turn");
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(9));
    behavior.recordExpectedAction(0, "zero-turn", .{ .kind = "edit" }, .{ .ok = true }, "invalid turn");
    behavior.recordExpectedAction(2, "future-turn", .{ .kind = "edit" }, .{ .ok = true }, "invalid turn");
    behavior.recordExpectedAction(1, "", .{ .kind = "edit" }, .{ .ok = true }, "empty commitment");
    behavior.recordMisprediction(1, "", .{ .ok = true }, .{ .ok = false }, "empty commitment");

    try std.testing.expectEqual(@as(u64, 2), behavior.seq);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, aw.writer.buffered(), "\n"));
    behavior.finish(.failed);
    behavior.finish(.closed); // the first terminal status wins
    try std.testing.expectEqual(@as(u64, 3), behavior.seq);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next();
    _ = lines.next();
    var finished = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer finished.deinit();
    try std.testing.expectEqualStrings("error", finished.value.object.get("status").?.string);
}

test "BehaviorTrace: a full upload queue cannot claim a complete terminal lifecycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('q'),
        .client_name = "harness",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .metadata,
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .upload = &upload,
        .run_id = "0123456789abcdef",
    };

    behavior.start("test", 1);
    try std.testing.expectEqual(@as(usize, 1), upload.events.items.len);
    const placeholder = upload.events.items[0][0..0];
    try upload.events.resize(gpa, behavior_upload.max_events);
    for (upload.events.items[1..]) |*event| event.* = placeholder;

    const state = behavior.prepareFinish("closed").?;
    try std.testing.expect(!state.complete);
    try std.testing.expectEqual(@as(u64, 1), upload.dropped_events);
    try std.testing.expectEqual(@as(usize, behavior_upload.max_events), upload.events.items.len);

    // Remove synthetic queue entries before normal deinit and payload parsing.
    upload.events.shrinkRetainingCapacity(1);
    const payload = try upload.buildPayload(state.complete, "closed");
    defer gpa.free(payload);
    var parsed = try std.json.parseFromSlice(Value, gpa, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("complete").?.bool);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("events").?.array.items.len);
}

test "BehaviorTrace: terminal allocation failure leaves upload incomplete" {
    const backing_gpa = std.testing.allocator;
    const io = std.testing.io;
    // run_started uses one allocation for its event and one for ArrayList
    // storage. Fail the next allocation, which is run_finished serialization.
    var failing = std.testing.FailingAllocator.init(backing_gpa, .{ .fail_index = 2 });
    const failing_gpa = failing.allocator();
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = failing_gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('a'),
        .client_name = "harness",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .metadata,
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = backing_gpa,
        .out = null,
        .upload = &upload,
        .run_id = "0123456789abcdef",
    };

    behavior.start("test", 1);
    try std.testing.expectEqual(@as(usize, 1), upload.events.items.len);
    const state = behavior.prepareFinish("error").?;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!state.complete);
    try std.testing.expectEqual(@as(u64, 1), upload.dropped_events);
    try std.testing.expectEqual(@as(usize, 1), upload.events.items.len);

    failing.fail_index = std.math.maxInt(usize);
    const payload = try upload.buildPayload(state.complete, "error");
    defer failing_gpa.free(payload);
    var parsed = try std.json.parseFromSlice(Value, backing_gpa, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("complete").?.bool);
}

test "BehaviorTrace: metadata-default upload is an exact content-free projection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var local: Io.Writer.Allocating = .init(gpa);
    defer local.deinit();
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('c'),
        .client_name = "test",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = behavior_upload.resolveMode(null, true),
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &local.writer,
        .upload = &upload,
        .run_id = "0123456789abcdef",
    };
    behavior.startWithMetadata("test", 1_234, .{
        .provider = "anthropic",
        .model = "test-model",
        .prompt_sha = "0011223344556677",
        .effort = "high",
    });
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(7));
    behavior.recordExpectedAction(
        1,
        "COMMITMENT_SECRET",
        .{ .source = "SOURCE_SECRET", .tool_args = "TOOL_ARGUMENT_SECRET" },
        .{ .tool_result = "TOOL_RESULT_SECRET" },
        "REASON_SECRET",
    );
    behavior.recordMisprediction(
        1,
        "COMMITMENT_SECRET",
        .{ .model_output = "MODEL_OUTPUT_SECRET" },
        .{ .workspace_path = "PRIVATE_PATH_SECRET" },
        "DETAIL_SECRET",
    );
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };
    tracer.api("repl", false, "test-model", 20, 100, 200, 300, 250, false);
    tracer.tool("mcp__private_server__lookup_customer", 7, true, 80, true);
    behavior.finish(.closed);
    behavior.finish(.failed);
    // Late callbacks may race terminal teardown. They must observe closure and
    // leave the uploader untouched after send can begin.
    try std.testing.expectEqual(@as(u64, 0), behavior.recordApiMetric(false, 99, 999, 999, 999, 999, true));
    try std.testing.expectEqual(@as(u64, 0), behavior.recordToolMetric("bash", false, 99, 999, true));

    const secrets = [_][]const u8{
        "COMMITMENT_SECRET",
        "SOURCE_SECRET",
        "TOOL_ARGUMENT_SECRET",
        "TOOL_RESULT_SECRET",
        "REASON_SECRET",
        "MODEL_OUTPUT_SECRET",
        "PRIVATE_PATH_SECRET",
        "DETAIL_SECRET",
        "0011223344556677",
        "private_server",
        "lookup_customer",
    };
    const local_jsonl = local.writer.buffered();
    for (secrets[0..9]) |secret| try std.testing.expect(std.mem.indexOf(u8, local_jsonl, secret) != null);

    const payload = try upload.buildPayload(true, "closed");
    defer gpa.free(payload);
    for (&secrets) |secret| try std.testing.expect(std.mem.indexOf(u8, payload, secret) == null);
    var parsed = try std.json.parseFromSlice(Value, gpa, payload, .{});
    defer parsed.deinit();
    const batch = parsed.value.object;
    try expectObjectKeys(batch, &.{
        "schema",
        "event_schema",
        "privacy",
        "run_id",
        "install_id",
        "client_name",
        "service_version",
        "complete",
        "terminal_status",
        "dropped_events",
        "dropped_metrics",
        "events",
        "turn_metrics",
    });
    try std.testing.expectEqualStrings("metadata", batch.get("privacy").?.string);
    const events = batch.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), events.len);
    try expectObjectKeys(events[0].object, &.{ "kind", "seq", "ts", "run_id", "schema", "version", "unix_ms", "provider", "model", "effort" });
    try expectObjectKeys(events[1].object, &.{ "kind", "seq", "ts", "run_id", "schema", "turn", "parent_turn", "trajectory_node" });
    try expectObjectKeys(events[2].object, &.{ "kind", "seq", "ts", "run_id", "schema", "turn", "commitment_ref" });
    try expectObjectKeys(events[3].object, &.{ "kind", "seq", "ts", "run_id", "schema", "turn", "commitment_ref" });
    try expectObjectKeys(events[4].object, &.{ "kind", "seq", "ts", "run_id", "schema", "status" });
    try std.testing.expectEqualStrings(events[2].object.get("commitment_ref").?.string, events[3].object.get("commitment_ref").?.string);

    const metrics = batch.get("turn_metrics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), metrics.len);
    try std.testing.expectEqual(@as(i64, 0), metrics[0].object.get("api_subagent_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), metrics[0].object.get("tool_subagent_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), metrics[0].object.get("tool_mcp").?.integer);
    try std.testing.expectEqual(@as(i64, 1), metrics[0].object.get("tool_errors").?.integer);
}

test "BehaviorTrace: prompt fingerprint stays local in content mode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var local: Io.Writer.Allocating = .init(gpa);
    defer local.deinit();
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('c'),
        .client_name = "harness",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .content,
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &local.writer,
        .upload = &upload,
        .run_id = "0123456789abcdef",
    };
    behavior.startWithMetadata("test", 1, .{ .prompt_sha = "0011223344556677" });
    try std.testing.expect(std.mem.indexOf(u8, local.writer.buffered(), "0011223344556677") != null);
    try std.testing.expectEqual(@as(usize, 1), upload.events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, upload.events.items[0], "0011223344556677") == null);
    try std.testing.expect(std.mem.indexOf(u8, upload.events.items[0], "prompt_sha") == null);
}

test "beginRootTurn: correlates without allocating a legacy node" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "root-turn-run",
    };
    var trajectory: Trajectory = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
    };
    defer trajectory.deinit();

    behavior.start("test", 1);
    const trajectory_node = trajectory.nextId();
    trajectory.setTurn(trajectory_node);
    const legacy_next_id = trajectory.next_id;
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };
    const previous_trajectory = g_traj;
    g_traj = &trajectory;
    defer g_traj = previous_trajectory;

    try std.testing.expectEqual(@as(u64, 1), beginRootTurn(&tracer));
    try std.testing.expectEqual(legacy_next_id, trajectory.next_id);
    try std.testing.expectEqual(trajectory_node, trajectory.currentTurn());

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next(); // run_started
    var turn = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer turn.deinit();
    try std.testing.expectEqual(@as(i64, 1), turn.value.object.get("turn").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(trajectory_node)), turn.value.object.get("trajectory_node").?.integer);
}

test "endRootTurn: clears attribution while preserving the dense parent chain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "root-scope-run",
    };
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };
    const previous_trajectory = g_traj;
    g_traj = null;
    defer g_traj = previous_trajectory;

    behavior.start("test", 1);
    const first = beginRootTurn(&tracer);
    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expectEqual(first, behavior.recordApiMetric(false, 1, 1, 1, 1, 1, false));
    try std.testing.expectEqual(first, behavior.recordToolMetric("bash", false, 1, 1, false));

    endRootTurn(&tracer, first);
    try std.testing.expectEqual(@as(u64, 0), behavior.currentTurn());
    try std.testing.expectEqual(@as(u64, 0), behavior.recordApiMetric(false, 1, 1, 1, 1, 1, false));
    try std.testing.expectEqual(@as(u64, 0), behavior.recordToolMetric("bash", false, 1, 1, false));
    behavior.recordExpectedAction(first, "late", .{ .tool = "bash" }, .{ .ok = true }, "outside the root turn");

    const second = beginRootTurn(&tracer);
    try std.testing.expectEqual(@as(u64, 2), second);
    endRootTurn(&tracer, first); // a stale scope cannot clear the new turn
    try std.testing.expectEqual(second, behavior.currentTurn());
    endRootTurn(&tracer, second);
    try std.testing.expectEqual(@as(u64, 0), behavior.currentTurn());
    try std.testing.expectEqual(@as(u64, 3), behavior.seq);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next(); // run_started
    _ = lines.next(); // first turn_started
    var second_started = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer second_started.deinit();
    try std.testing.expectEqual(@as(i64, 2), second_started.value.object.get("turn").?.integer);
    try std.testing.expectEqual(@as(i64, 1), second_started.value.object.get("parent_turn").?.integer);
    try std.testing.expect(lines.next() == null);
}
