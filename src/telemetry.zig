//! Anonymous OTEL usage telemetry: the Telemetry sink — session counters
//! (api/tool/turn/error/score/fleet/run/workflow events) exported as one
//! best-effort OTLP/HTTP JSON batch POST at session end. Split out of main.zig
//! (600-line goal). Owns g_telem. utf8Prefix/unixMs live in util.zig and
//! loadOrCreateId in keys_cli.zig (this file was itself pushing past 600).
//! Back-imports main for harness_version and the live g_fleet toggle; pulls
//! g_cost from pricing.zig, utf8Prefix/unixMs from util.zig directly. main
//! re-exports Telemetry (fleet.zig back-imports it) and mod-qualifies
//! g_telem at its ~24 call sites.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const pricing = @import("pricing.zig");
const g_cost = &pricing.g_cost;

const util = @import("util.zig");
const utf8Prefix = util.utf8Prefix;
const unixMs = util.unixMs;

const root = @import("main.zig");
const harness_version = root.harness_version;

// ── Telemetry (OTEL) ────────────────────────────────────────────────────────
// ── Telemetry (OTEL) ────────────────────────────────────────────────────────

/// Anonymous usage telemetry, exported as OTLP/HTTP JSON log records in one
/// best-effort POST at session end. Off entirely unless an endpoint is
/// configured (OTEL_EXPORTER_OTLP_ENDPOINT or GRAFF_OTEL_ENDPOINT env);
/// GRAFF_NO_TELEMETRY or --no-telemetry forces it off regardless. Counters
/// feed from the same Tracer hooks that write harness.trace.jsonl, plus
/// workflow/ultracode/turn events from the orchestrator. A per-install
/// anonymous id (~/.simple-harness-install-id) identifies the install; SDKs
/// pass their own id via HARNESS_SDK_INSTALL_ID + HARNESS_CLIENT so SDK
/// users are counted separately. Flush failures never disturb the session.
pub const Telemetry = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    endpoint: []const u8, // base OTLP endpoint; "" → disabled
    client: ?*std.http.Client = null, // shared http client, set by main()
    install_id: [32]u8, // anonymous hex id for this install
    client_name: []const u8, // "harness", or "sdk-ts"/"sdk-py" via HARNESS_CLIENT
    sdk_install_id: []const u8, // the SDK's own install id, if driving us
    start: Io.Timestamp,
    start_unix_ms: i64,

    api_calls: u64 = 0,
    api_errors: u64 = 0,
    tool_calls: u64 = 0,
    tool_errors: u64 = 0,
    turns: u64 = 0,
    ultracode_turns: u64 = 0,
    workflows: u64 = 0,
    workflow_tasks: u64 = 0,
    prompt_variants: u64 = 0, // subagents spawned with a system-prompt override
    scores_recorded: u64 = 0, // evaluation write-backs via the score request
    models: std.ArrayList([]const u8) = .empty, // distinct models used (gpa-duped)
    events: std.ArrayList(Event) = .empty, // discrete error/workflow records

    /// One buffered log record. body "error": kind/detail set. body
    /// "workflow": phases/tasks/failed/duration set. body "score":
    /// detail = prompt_sha, score = the evaluation value.
    const Event = struct {
        t_ms: i64,
        body: []const u8, // "error" | "workflow" | "ultracode" | "score" (static)
        kind: []const u8 = "", // error source: "api" | "tool" | "turn" (static)
        detail: []const u8 = "", // gpa-duped, truncated
        extra: []const u8 = "", // gpa-duped: score → parent_sha, run → tool sequence
        run_id: []const u8 = "", // gpa-duped: score → run_id (signed)
        sig: []const u8 = "", // gpa-duped: score → HMAC signature ("" when unsigned)
        prov: []const u8 = "", // gpa-duped: score → "judge_id\tartifact_sha\teval_set_hash" (signed)
        phases: i64 = 0,
        tasks: i64 = 0,
        failed: i64 = 0,
        ms: i64 = 0,
        score: f64 = 0,
        flag: bool = true, // run → ok
        text: []const u8 = "", // gpa-duped: fleet:propose → the genome (persona prompt text)
    };
    const max_events = 64; // cap discrete records; counters keep full totals
    const max_detail = 200;

    pub fn on(self: *const Telemetry) bool {
        return self.endpoint.len > 0;
    }

    pub fn elapsedMs(self: *Telemetry) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    pub fn countApi(self: *Telemetry, model: []const u8, is_error: bool) void {
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.api_calls += 1;
        if (is_error) self.api_errors += 1;
        for (self.models.items) |m| if (std.mem.eql(u8, m, model)) return;
        const dup = self.gpa.dupe(u8, model) catch return;
        self.models.append(self.gpa, dup) catch self.gpa.free(dup);
    }

    pub fn countTool(self: *Telemetry, is_error: bool) void {
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.tool_calls += 1;
        if (is_error) self.tool_errors += 1;
    }

    pub fn countTurn(self: *Telemetry) void {
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.turns += 1;
    }

    pub fn ultracode(self: *Telemetry) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.ultracode_turns += 1;
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "ultracode" });
        }
        self.maybeFlushEvents();
    }

    /// Record an issue (API failure, tool failure, aborted turn) as an ERROR
    /// log record. `kind` and the truncated `detail` become attributes.
    pub fn errorEvent(self: *Telemetry, kind: []const u8, detail: []const u8) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "error", .kind = kind, .detail = self.dupDetail(detail) });
        }
        self.maybeFlushEvents();
    }

    /// Truncate to max_detail without splitting a UTF-8 codepoint, and force
    /// the copy to valid UTF-8 — std.json serializes an invalid []u8 as an
    /// ARRAY of integers, which is schema-invalid OTLP that makes a collector
    /// reject the entire batch. detail can carry raw provider bytes (e.g.
    /// "unparseable response: …"), so both the cut and the content matter.
    pub fn dupDetail(self: *Telemetry, detail: []const u8) []const u8 {
        var p = detail[0..@min(detail.len, max_detail)];
        var strips: usize = 0; // a split codepoint needs at most 3 byte strips
        while (strips < 3 and p.len > 0 and !std.unicode.utf8ValidateSlice(p)) : (strips += 1)
            p = p[0 .. p.len - 1];
        const dup = self.gpa.dupe(u8, p) catch return "";
        if (!std.unicode.utf8ValidateSlice(dup)) for (dup) |*b| {
            if (b.* >= 0x80) b.* = '?'; // invalid mid-string bytes: degrade to ASCII
        };
        return dup;
    }

    /// Count a subagent spawned with a system-prompt override (an agent-type
    /// persona or an inline variant) — the swarm's prompt diversity signal.
    pub fn countVariant(self: *Telemetry) void {
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.prompt_variants += 1;
    }

    /// Record an evaluation write-back (the DGM scoring phase) so the OTEL
    /// backend can validate that the evolution loop is actually running:
    /// one log record per score, prompt_sha + value as attributes.
    pub fn scoreEvent(self: *Telemetry, sha: []const u8, parent: []const u8, value: f64, run_id: []const u8, sig: []const u8, prov: []const u8) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.scores_recorded += 1;
            const dup = self.gpa.dupe(u8, sha[0..@min(sha.len, 32)]) catch "";
            const pdup = if (parent.len > 0) self.gpa.dupe(u8, parent[0..@min(parent.len, 32)]) catch "" else "";
            const rdup = if (run_id.len > 0) self.gpa.dupe(u8, run_id[0..@min(run_id.len, 64)]) catch "" else "";
            const sdup = if (sig.len > 0) self.gpa.dupe(u8, sig[0..@min(sig.len, 64)]) catch "" else "";
            const vdup = if (prov.len > 0) self.gpa.dupe(u8, utf8Prefix(prov, 256)) catch "" else "";
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "score", .detail = dup, .extra = pdup, .run_id = rdup, .sig = sdup, .prov = vdup, .score = value });
        }
        self.maybeFlushEvents();
    }

    /// Record a federated-fleet signal (docs/hyperagents.md §9): propose /
    /// submit / elite_pull. body="fleet" with a kind attr, mirroring the SDK
    /// _fleet_signal so the worker counts every client identically. signal is a
    /// static literal; the rest are duped/truncated like scoreEvent.
    pub fn fleetEvent(self: *Telemetry, signal: []const u8, niche: []const u8, prompt_sha: []const u8, parent_sha: []const u8, provider_class: []const u8, eval_set_hash: []const u8, n_elites: i64, prompt_text: []const u8) void {
        if (!self.on() or !root.g_fleet) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const ddet = if (prompt_sha.len > 0) self.gpa.dupe(u8, prompt_sha[0..@min(prompt_sha.len, 32)]) catch "" else "";
            const dnic = if (niche.len > 0) self.gpa.dupe(u8, utf8Prefix(niche, 64)) catch "" else "";
            const dpar = if (parent_sha.len > 0) self.gpa.dupe(u8, parent_sha[0..@min(parent_sha.len, 32)]) catch "" else "";
            var pbuf: [200]u8 = undefined;
            const provdup = if (provider_class.len > 0 or eval_set_hash.len > 0)
                self.gpa.dupe(u8, std.fmt.bufPrint(&pbuf, "{s}\t{s}", .{ provider_class, eval_set_hash }) catch "") catch ""
            else
                "";
            const dtext = if (prompt_text.len > 0) self.gpa.dupe(u8, utf8Prefix(prompt_text, 8192)) catch "" else "";
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "fleet", .kind = signal, .detail = ddet, .extra = dnic, .run_id = dpar, .prov = provdup, .tasks = n_elites, .text = dtext });
        }
        self.maybeFlushEvents();
    }

    /// Record a completed agent run (root turn or subagent) with its tool
    /// sequence — the process-mining signal behind "which tool combinations
    /// work". Lands as a generic body="run" record (attrs JSON) server-side.
    pub fn runEvent(self: *Telemetry, sha: []const u8, variant: bool, ok: bool, ms: i64, tools: []const u8) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const dsha = self.gpa.dupe(u8, sha[0..@min(sha.len, 32)]) catch "";
            const dtools = if (tools.len > 0) self.gpa.dupe(u8, utf8Prefix(tools, 600)) catch "" else "";
            self.push(.{
                .t_ms = self.elapsedMsLocked(),
                .body = "run",
                .kind = if (variant) "variant" else "default",
                .detail = dsha,
                .extra = dtools,
                .ms = ms,
                .flag = ok,
            });
        }
        self.maybeFlushEvents();
    }

    /// Record one workflow-tool run (the ultracode pipe): phase/task counts,
    /// failed task count, and wall-clock duration.
    pub fn workflowEvent(self: *Telemetry, phases: usize, tasks: usize, failed: usize, ms: i64) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.workflows += 1;
            self.workflow_tasks += tasks;
            self.push(.{
                .t_ms = self.elapsedMsLocked(),
                .body = "workflow",
                .phases = @intCast(phases),
                .tasks = @intCast(tasks),
                .failed = @intCast(failed),
                .ms = ms,
            });
        }
        self.maybeFlushEvents();
    }

    // Callers hold the mutex. elapsedMs duplicated without locking because
    // Io.Mutex is not reentrant.
    pub fn elapsedMsLocked(self: *Telemetry) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    pub fn push(self: *Telemetry, e: Event) void {
        self.events.append(self.gpa, e) catch {
            self.freeEvent(e);
        };
    }

    pub fn freeEvent(self: *Telemetry, e: Event) void {
        if (e.detail.len > 0) self.gpa.free(e.detail);
        if (e.extra.len > 0) self.gpa.free(e.extra);
        if (e.run_id.len > 0) self.gpa.free(e.run_id);
        if (e.sig.len > 0) self.gpa.free(e.sig);
        if (e.prov.len > 0) self.gpa.free(e.prov);
        if (e.text.len > 0) self.gpa.free(e.text);
    }

    /// When the event buffer reaches max_events, ship it mid-session as an
    /// events-only OTLP batch instead of dropping records — an evolution
    /// driver can emit hundreds of scores in one session, and a crash after
    /// a shipped batch loses at most max_events-1 events. Swaps the buffer
    /// out under the mutex, posts without holding it.
    pub fn maybeFlushEvents(self: *Telemetry) void {
        var batch: std.ArrayList(Event) = .empty;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.events.items.len < max_events) return;
            batch = self.events;
            self.events = .empty;
        }
        defer {
            for (batch.items) |e| self.freeEvent(e);
            batch.deinit(self.gpa);
        }
        self.sendBatch(batch.items, false);
    }

    pub fn deinit(self: *Telemetry) void {
        for (self.models.items) |m| self.gpa.free(m);
        self.models.deinit(self.gpa);
        for (self.events.items) |e| self.freeEvent(e);
        self.events.deinit(self.gpa);
    }

    /// Final flush at session end: the session summary plus any events not
    /// already shipped by a mid-session batch.
    pub fn flush(self: *Telemetry) void {
        self.sendBatch(self.events.items, true);
    }

    /// Build an OTLP/HTTP JSON payload for `events` (plus the session
    /// summary when `include_summary`) and POST it to <endpoint>/v1/logs
    /// (per the OTLP env spec the endpoint is a base URL; it's used verbatim
    /// only when it already ends in /v1/logs). The POST races a 3s deadline
    /// so a dead or wedged collector can never hang the session.
    /// Best-effort: any failure is swallowed.
    pub fn sendBatch(self: *Telemetry, events: []const Event, include_summary: bool) void {
        if (!self.on()) return;
        const client = self.client orelse return;
        if (events.len == 0 and !include_summary) return;
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        self.writeOtlp(&aw.writer, events, include_summary) catch return;
        var ubuf: [512]u8 = undefined;
        const trimmed = std.mem.trimEnd(u8, self.endpoint, "/");
        const url = if (std.mem.endsWith(u8, trimmed, "/v1/logs"))
            trimmed
        else
            std.fmt.bufPrint(&ubuf, "{s}/v1/logs", .{trimmed}) catch return;

        const Done = union(enum) { posted: void, deadline: void };
        var done_buf: [2]Done = undefined;
        var sel: Io.Select(Done) = .init(self.io, &done_buf);
        sel.concurrent(.posted, postOtlp, .{ client, url, aw.writer.buffered() }) catch return;
        sel.concurrent(.deadline, flushDeadline, .{self.io}) catch {
            _ = sel.await() catch {}; // no spare concurrency: wait unbounded
            sel.cancelDiscard();
            return;
        };
        _ = sel.await() catch {}; // first of POST / deadline wins
        sel.cancelDiscard(); // cancel the loser (fetch's socket ops are cancelation points)
    }

    pub fn postOtlp(client: *std.http.Client, url: []const u8, payload: []const u8) void {
        _ = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
        }) catch {};
    }

    pub fn flushDeadline(io: Io) void {
        io.sleep(.fromSeconds(3), .awake) catch {};
    }

    const AttrVal = union(enum) { str: []const u8, int: i64, num: f64 };

    pub fn attr(s: *std.json.Stringify, key: []const u8, v: AttrVal) !void {
        try s.beginObject();
        try s.objectField("key");
        try s.write(key);
        try s.objectField("value");
        try s.beginObject();
        switch (v) {
            .str => |x| {
                try s.objectField("stringValue");
                try s.write(x);
            },
            .int => |x| { // proto3 JSON maps int64 to a decimal string
                var b: [24]u8 = undefined;
                try s.objectField("intValue");
                try s.write(std.fmt.bufPrint(&b, "{d}", .{x}) catch unreachable);
            },
            .num => |x| { // doubleValue stays a JSON number
                try s.objectField("doubleValue");
                try s.write(x);
            },
        }
        try s.endObject();
        try s.endObject();
    }

    pub fn timeField(s: *std.json.Stringify, unix_ms: i64) !void {
        var b: [32]u8 = undefined;
        try s.objectField("timeUnixNano");
        try s.write(std.fmt.bufPrint(&b, "{d}", .{unix_ms * 1_000_000}) catch unreachable);
    }

    pub fn writeOtlp(self: *Telemetry, w: *Io.Writer, events: []const Event, include_summary: bool) !void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("resourceLogs");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("resource");
        try s.beginObject();
        try s.objectField("attributes");
        try s.beginArray();
        try attr(&s, "service.name", .{ .str = "simple-harness" });
        try attr(&s, "service.version", .{ .str = harness_version });
        try attr(&s, "os.type", .{ .str = @tagName(builtin.os.tag) });
        try attr(&s, "host.arch", .{ .str = @tagName(builtin.cpu.arch) });
        try attr(&s, "install.id", .{ .str = &self.install_id });
        try attr(&s, "client.name", .{ .str = self.client_name });
        if (self.sdk_install_id.len > 0) try attr(&s, "sdk.install.id", .{ .str = self.sdk_install_id });
        try s.endArray();
        try s.endObject();
        try s.objectField("scopeLogs");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("scope");
        try s.beginObject();
        try s.objectField("name");
        try s.write("simple-harness");
        try s.endObject();
        try s.objectField("logRecords");
        try s.beginArray();
        for (events) |e| {
            try s.beginObject();
            try timeField(&s, self.start_unix_ms + e.t_ms);
            try s.objectField("severityText");
            try s.write(if (std.mem.eql(u8, e.body, "error")) "ERROR" else "INFO");
            try s.objectField("body");
            try s.beginObject();
            try s.objectField("stringValue");
            try s.write(e.body);
            try s.endObject();
            try s.objectField("attributes");
            try s.beginArray();
            if (std.mem.eql(u8, e.body, "score")) {
                try attr(&s, "prompt_sha", .{ .str = e.detail });
                try attr(&s, "value", .{ .num = e.score });
                if (e.extra.len > 0) try attr(&s, "parent_sha", .{ .str = e.extra });
                if (e.run_id.len > 0) try attr(&s, "run_id", .{ .str = e.run_id });
                if (e.sig.len > 0) try attr(&s, "sig", .{ .str = e.sig });
                if (e.prov.len > 0) {
                    // prov = "judge_id\tartifact_sha\teval_set_hash" — split so
                    // the worker can recompute the HMAC over the same fields.
                    var it = std.mem.splitScalar(u8, e.prov, '\t');
                    if (it.next()) |j| if (j.len > 0) try attr(&s, "judge_id", .{ .str = j });
                    if (it.next()) |a| if (a.len > 0) try attr(&s, "artifact_sha", .{ .str = a });
                    if (it.next()) |h| if (h.len > 0) try attr(&s, "eval_set_hash", .{ .str = h });
                    if (it.next()) |pc| if (pc.len > 0) try attr(&s, "provider_class", .{ .str = pc });
                    if (it.next()) |nc| if (nc.len > 0) try attr(&s, "niche", .{ .str = nc });
                }
            } else if (std.mem.eql(u8, e.body, "run")) {
                try attr(&s, "prompt_sha", .{ .str = e.detail });
                try attr(&s, "variant", .{ .int = @intFromBool(std.mem.eql(u8, e.kind, "variant")) });
                try attr(&s, "ok", .{ .int = @intFromBool(e.flag) });
                try attr(&s, "duration_ms", .{ .int = e.ms });
                if (e.extra.len > 0) try attr(&s, "tools", .{ .str = e.extra });
            } else if (std.mem.eql(u8, e.body, "fleet")) {
                try attr(&s, "kind", .{ .str = e.kind });
                if (e.extra.len > 0) try attr(&s, "niche", .{ .str = e.extra });
                if (e.detail.len > 0) try attr(&s, "prompt_sha", .{ .str = e.detail });
                if (e.run_id.len > 0) try attr(&s, "parent_sha", .{ .str = e.run_id });
                if (e.prov.len > 0) {
                    var fit = std.mem.splitScalar(u8, e.prov, '\t');
                    if (fit.next()) |pc| if (pc.len > 0) try attr(&s, "provider_class", .{ .str = pc });
                    if (fit.next()) |eh| if (eh.len > 0) try attr(&s, "eval_set_hash", .{ .str = eh });
                }
                if (std.mem.eql(u8, e.kind, "elite_pull")) try attr(&s, "n_elites", .{ .int = e.tasks });
                if (e.text.len > 0) try attr(&s, "prompt_text", .{ .str = e.text });
            } else {
                if (e.kind.len > 0) try attr(&s, "kind", .{ .str = e.kind });
                if (e.detail.len > 0) try attr(&s, "detail", .{ .str = e.detail });
                if (std.mem.eql(u8, e.body, "workflow")) {
                    try attr(&s, "phases", .{ .int = e.phases });
                    try attr(&s, "tasks", .{ .int = e.tasks });
                    try attr(&s, "failed_tasks", .{ .int = e.failed });
                    try attr(&s, "duration_ms", .{ .int = e.ms });
                }
            }
            try s.endArray();
            try s.endObject();
        }
        // Session summary: the "general usage stats" record (final flush only).
        if (include_summary) {
            const models_joined = std.mem.join(self.gpa, ",", self.models.items) catch "";
            defer if (models_joined.len > 0) self.gpa.free(models_joined);
            try s.beginObject();
            try timeField(&s, unixMs(self.io));
            try s.objectField("severityText");
            try s.write("INFO");
            try s.objectField("body");
            try s.beginObject();
            try s.objectField("stringValue");
            try s.write("session");
            try s.endObject();
            try s.objectField("attributes");
            try s.beginArray();
            try attr(&s, "duration_ms", .{ .int = self.elapsedMs() });
            try attr(&s, "turns", .{ .int = @intCast(self.turns) });
            try attr(&s, "api_calls", .{ .int = @intCast(self.api_calls) });
            try attr(&s, "api_errors", .{ .int = @intCast(self.api_errors) });
            try attr(&s, "tool_calls", .{ .int = @intCast(self.tool_calls) });
            try attr(&s, "tool_errors", .{ .int = @intCast(self.tool_errors) });
            try attr(&s, "workflows", .{ .int = @intCast(self.workflows) });
            try attr(&s, "workflow_tasks", .{ .int = @intCast(self.workflow_tasks) });
            try attr(&s, "ultracode_turns", .{ .int = @intCast(self.ultracode_turns) });
            try attr(&s, "prompt_variants", .{ .int = @intCast(self.prompt_variants) });
            try attr(&s, "scores_recorded", .{ .int = @intCast(self.scores_recorded) });
            try attr(&s, "models", .{ .str = models_joined });
            const c = g_cost.snap(self.io);
            try attr(&s, "cost_usd", .{ .num = c.usd });
            try attr(&s, "tokens_in", .{ .int = @intCast(c.in_tokens) });
            try attr(&s, "tokens_cached", .{ .int = @intCast(c.cache_tokens) });
            try attr(&s, "tokens_out", .{ .int = @intCast(c.out_tokens) });
            try s.endArray();
            try s.endObject();
        }
        try s.endArray(); // logRecords
        try s.endObject(); // scopeLog entry
        try s.endArray(); // scopeLogs
        try s.endObject(); // resourceLog entry
        try s.endArray(); // resourceLogs
        try s.endObject();
    }
};

/// Set once in main() when telemetry is configured; Tracer and the workflow
/// runner feed it through this. Null → every hook is a no-op.
pub var g_telem: ?*Telemetry = null;
test "telemetry dupDetail never yields invalid UTF-8" {
    var t: Telemetry = .{
        .io = undefined, // dupDetail only touches gpa
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = undefined,
        .start_unix_ms = 0,
    };
    // The 200-byte cap lands mid-codepoint: 199 ASCII bytes + 2-byte 'é'.
    var buf: [201]u8 = undefined;
    @memset(buf[0..199], 'a');
    buf[199] = 0xC3;
    buf[200] = 0xA9;
    const cut = t.dupDetail(&buf);
    defer std.testing.allocator.free(cut);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqual(@as(usize, 199), cut.len); // split lead byte dropped
    // Raw invalid bytes mid-string (unparseable provider response) degrade
    // to ASCII instead of corrupting the OTLP payload.
    const garbage = t.dupDetail("ok\xff\xfe more text here");
    defer std.testing.allocator.free(garbage);
    try std.testing.expect(std.unicode.utf8ValidateSlice(garbage));
    try std.testing.expect(std.mem.startsWith(u8, garbage, "ok??"));
}
test "telemetry writeOtlp emits a fleet record with kind + split prov attrs" {
    var t: Telemetry = .{
        .io = undefined, // writeOtlp(.., include_summary=false) never touches io
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = undefined,
        .start_unix_ms = 0,
    };
    const events = [_]Telemetry.Event{.{
        .t_ms = 0,
        .body = "fleet",
        .kind = "propose",
        .detail = "abcd1234", // prompt_sha
        .extra = "reviewer", // niche
        .run_id = "deadbeef", // parent_sha
        .prov = "frontier\ta9134381", // provider_class \t eval_set_hash
    }};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try t.writeOtlp(&aw.writer, &events, false);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stringValue\":\"fleet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"propose\"") != null); // kind
    try std.testing.expect(std.mem.indexOf(u8, out, "\"reviewer\"") != null); // niche
    try std.testing.expect(std.mem.indexOf(u8, out, "parent_sha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"frontier\"") != null); // provider_class (split from prov)
    try std.testing.expect(std.mem.indexOf(u8, out, "\"a9134381\"") != null); // eval_set_hash (split from prov)
}
