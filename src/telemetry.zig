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
const http = @import("http.zig");
const shutdown_trace = @import("shutdown_trace.zig"); // #364: teardown phase stamps

// For the session run id (score/run join key) and the propose-site
// fingerprint check. No cycle: scoring imports only std + pricing.
const scoring = @import("scoring.zig");
const telemetry_score = @import("telemetry_score.zig");
const learning_privacy = @import("learning_privacy.zig");

const root = @import("main.zig");
const harness_version = root.harness_version;

// ── Telemetry (OTEL) ────────────────────────────────────────────────────────

/// Anonymous usage telemetry, exported as OTLP/HTTP JSON log records in one
/// best-effort POST at session end. Off entirely unless an endpoint is
/// configured (OTEL_EXPORTER_OTLP_ENDPOINT or GRAFF_OTEL_ENDPOINT env);
/// GRAFF_NO_TELEMETRY or --no-telemetry forces it off regardless. Counters
/// feed from the same Tracer hooks that write `.graff/traces/<run-id>.jsonl`, plus
/// workflow/ultracode/turn events from the orchestrator. A per-install
/// anonymous id (~/.simple-harness-install-id) identifies the install; SDKs
/// pass their own id via HARNESS_SDK_INSTALL_ID + HARNESS_CLIENT so SDK
/// users are counted separately. Flush failures never disturb the session.
///
/// Transport helpers (collector key validation, signal-URL derivation, the
/// bounded-deadline POST path's mock collectors and tests) live in
/// telemetry_net.zig (600-line goal).
const telemetry_net = @import("telemetry_net.zig");
pub const validatedAuthKey = telemetry_net.validatedAuthKey;
const otlpLogsUrl = telemetry_net.otlpLogsUrl;
const obs = @import("obs.zig");

test {
    _ = telemetry_net;
    _ = @import("telemetry_tests.zig");
    _ = obs;
}

pub const Telemetry = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    endpoint: []const u8, // base OTLP endpoint; "" → disabled
    client: ?*std.http.Client = null, // shared http client, set by main()
    auth_key: ?[]const u8 = null, // optional x-harness-key; never serialized
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
    pub const Event = struct {
        t_ms: i64,
        body: []const u8, // "error" | "workflow" | "ultracode" | "score" (static)
        kind: []const u8 = "", // error source: "api" | "tool" | "turn" (static)
        detail: []const u8 = "", // gpa-duped, truncated
        extra: []const u8 = "", // gpa-duped: score → parent_sha, run → tool sequence
        run_id: []const u8 = "", // gpa-duped: score → run_id (signed)
        sig: []const u8 = "", // gpa-duped: score → HMAC signature ("" when unsigned)
        prov: []const u8 = "", // gpa-duped: score provenance + optional aggregate grade
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
        obs.turn(.completed);
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.turns += 1;
    }

    /// Line-session / oneshot / ACP: length only, then the turn counter.
    pub fn beginTurn(self: *Telemetry, prompt_len: u32, model: []const u8) void {
        obs.prompt(prompt_len, model);
        countTurn(self);
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
    /// log record. Only the fixed call-site category leaves the process: raw
    /// provider/tool error text can echo prompts, paths, source, or secrets.
    pub fn errorEvent(self: *Telemetry, kind: []const u8, detail: []const u8) void {
        _ = detail;
        obs.fail(kind);
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "error", .kind = kind });
        }
        self.maybeFlushEvents();
    }

    /// Count a subagent spawned with a system-prompt override (an agent-type
    /// persona or an inline variant) — the swarm's prompt diversity signal.
    pub fn countVariant(self: *Telemetry) void {
        if (!self.on() or !learning_privacy.allowsAggregate()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.prompt_variants += 1;
    }

    /// Record an evaluation write-back (the DGM scoring phase) so the OTEL
    /// backend can validate that the evolution loop is actually running:
    /// one log record per score, prompt_sha + value as attributes.
    pub fn scoreEvent(self: *Telemetry, sha: []const u8, parent: []const u8, value: f64, run_id: []const u8, sig: []const u8, prov: []const u8) void {
        if (!self.on() or !learning_privacy.allowsAggregate()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.scores_recorded += 1;
            const dup = self.gpa.dupe(u8, sha[0..@min(sha.len, 32)]) catch "";
            const pdup = if (parent.len > 0) self.gpa.dupe(u8, parent[0..@min(parent.len, 32)]) catch "" else "";
            const rdup = if (run_id.len > 0) self.gpa.dupe(u8, run_id[0..@min(run_id.len, 64)]) catch "" else "";
            const sdup = if (sig.len > 0) self.gpa.dupe(u8, sig[0..@min(sig.len, 64)]) catch "" else "";
            // Learning receipts append a second signature plus fixed aggregate
            // metrics. Never truncate signed provenance in transport.
            const vdup = if (prov.len > 0) self.gpa.dupe(u8, utf8Prefix(prov, 2048)) catch "" else "";
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "score", .detail = dup, .extra = pdup, .run_id = rdup, .sig = sdup, .prov = vdup, .score = value });
        }
        self.maybeFlushEvents();
    }

    /// Full-genome cap for a fleet:propose (issue #168 review F6): 64 KiB.
    /// The backend validates a propose by recomputing the fingerprint over
    /// the carried prompt_text, so a truncated genome never matches its
    /// claimed prompt_sha and is dropped server-side — never send one.
    /// Personas over the cap skip the propose entirely; call sites holding a
    /// tracer note the skip ("propose skipped: genome > 64KB").
    pub const max_propose_text = 64 * 1024;

    /// Record a federated-fleet signal (docs/hyperagents.md §9): propose /
    /// submit / elite_pull. body="fleet" with a kind attr, mirroring the SDK
    /// _fleet_signal so the worker counts every client identically. signal is a
    /// static literal; the rest are duped/truncated like scoreEvent.
    pub fn fleetEvent(self: *Telemetry, signal: []const u8, niche: []const u8, prompt_sha: []const u8, parent_sha: []const u8, provider_class: []const u8, eval_set_hash: []const u8, n_elites: i64, prompt_text: []const u8) void {
        if (!self.on() or !root.g_fleet or !learning_privacy.allowsAggregate()) return;
        const admitted_text = learning_privacy.templateTextForUpload(self.io, prompt_text);
        // Review F6: never ship a truncated genome — skip the propose instead
        // (the fingerprint the scores reference stays computed over the full
        // text; only the genome-send is dropped).
        if (std.mem.eql(u8, signal, "propose") and admitted_text.len > max_propose_text) return;
        // Propose-site integrity (issue #168 Gap 3, debug builds only): the
        // genome text must hash to the fingerprint it claims — a promoted
        // cell would otherwise serve text that never earned its scores. This
        // asserts on exactly what will be sent: oversized proposes returned
        // above, so the utf8Prefix cap below can no longer truncate a genome.
        // The backend independently recomputes and rejects mismatches.
        if (builtin.mode == .Debug and std.mem.eql(u8, signal, "propose") and admitted_text.len > 0 and prompt_sha.len > 0) {
            const fp = scoring.promptFingerprint(admitted_text);
            std.debug.assert(std.mem.eql(u8, &fp, prompt_sha));
        }
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
            const dtext = if (admitted_text.len > 0) self.gpa.dupe(u8, utf8Prefix(admitted_text, max_propose_text)) catch "" else "";
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "fleet", .kind = signal, .detail = ddet, .extra = dnic, .run_id = dpar, .prov = provdup, .tasks = n_elites, .text = dtext });
        }
        self.maybeFlushEvents();
    }

    /// Record a completed agent run (root turn or subagent) with its tool
    /// sequence — the process-mining signal behind "which tool combinations
    /// work". Lands as a generic body="run" record (attrs JSON) server-side.
    pub fn runEvent(self: *Telemetry, sha: []const u8, variant: bool, ok: bool, ms: i64, tools: []const u8) void {
        if (!self.on() or !learning_privacy.allowsAggregate()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const dsha = self.gpa.dupe(u8, sha[0..@min(sha.len, 32)]) catch "";
            const dtools = if (tools.len > 0) self.gpa.dupe(u8, utf8Prefix(tools, 600)) catch "" else "";
            // Session run id (issue #168 Gap 6): stamp the same run_id score
            // records carry so operational outcome (duration/tools/success)
            // and evaluation fitness share a stable join key per execution.
            const drun = self.gpa.dupe(u8, &scoring.g_run_id) catch "";
            self.push(.{
                .t_ms = self.elapsedMsLocked(),
                .body = "run",
                .kind = if (variant) "variant" else "default",
                .detail = dsha,
                .extra = dtools,
                .run_id = drun,
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
        shutdown_trace.mark("telemetry-flush"); // #364: fires mid-session too, but the LAST one is the exit flush
        self.sendBatch(self.events.items, true);
    }

    /// Build an OTLP/HTTP JSON payload for `events` (plus the session
    /// summary when `include_summary`) and POST it to <endpoint>/v1/logs.
    /// Per the OTLP env spec the endpoint is a base URL; an existing /v1/logs
    /// path is retained, query parameters are preserved, and fragments are
    /// dropped. The POST races a 3s deadline so a dead or wedged collector can
    /// never hang the session.
    /// Best-effort: any failure is swallowed.
    pub fn sendBatch(self: *Telemetry, events: []const Event, include_summary: bool) void {
        self.sendBatchWithDeadline(events, include_summary, .fromSeconds(3));
    }

    pub fn sendBatchWithDeadline(self: *Telemetry, events: []const Event, include_summary: bool, deadline: Io.Duration) void {
        if (!self.on()) return;
        const client = self.client orelse return;
        if (events.len == 0 and !include_summary) return;
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        self.writeOtlp(&aw.writer, events, include_summary) catch return;
        const url = (otlpLogsUrl(self.gpa, self.endpoint) catch return) orelse return;
        defer self.gpa.free(url);

        const Done = union(enum) { posted: bool, deadline: void };
        var done_buf: [2]Done = undefined;
        var sel: Io.Select(Done) = .init(self.io, &done_buf);
        // Arm the deadline before starting network I/O. If no concurrency slot
        // remains for the POST, canceling this timer is bounded; starting the
        // POST first could otherwise leave teardown waiting without a bound.
        sel.concurrent(.deadline, flushDeadline, .{ self.io, deadline }) catch return;
        sel.concurrent(.posted, postOtlp, .{ client, url, aw.writer.buffered(), self.auth_key orelse "" }) catch {
            sel.cancelDiscard();
            return;
        };
        _ = sel.await() catch {};
        sel.cancelDiscard(); // cancel and synchronously join the loser
    }

    pub fn postOtlp(client: *std.http.Client, url: []const u8, payload: []const u8, auth_key: []const u8) bool {
        http.waitForClientReady(client.io);
        const auth_header = [_]std.http.Header{.{ .name = "x-harness-key", .value = auth_key }};
        const extra_headers: []const std.http.Header = if (auth_key.len > 0) &auth_header else &.{};
        const response = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = extra_headers,
        }) catch return false;
        const status = @intFromEnum(response.status);
        return status >= 200 and status < 300;
    }

    pub fn flushDeadline(io: Io, deadline: Io.Duration) void {
        io.sleep(deadline, .awake) catch {};
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
        // Consent is a live send-time decision, not only an enqueue decision.
        // A later `/privacy local` or `/fleet off` revokes buffered learning
        // events, and a template approval is rechecked for the exact bytes.
        const learning_allowed = root.g_fleet and learning_privacy.allowsAggregate();
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("resourceLogs");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("resource");
        try s.beginObject();
        try s.objectField("attributes");
        try s.beginArray();
        const explicit_learning = std.mem.eql(u8, self.client_name, "harness-learn");
        if (!explicit_learning) {
            try attr(&s, "service.name", .{ .str = "simple-harness" });
            try attr(&s, "service.version", .{ .str = harness_version });
            try attr(&s, "os.type", .{ .str = @tagName(builtin.os.tag) });
            try attr(&s, "host.arch", .{ .str = @tagName(builtin.cpu.arch) });
            try attr(&s, "install.id", .{ .str = &self.install_id });
        }
        try attr(&s, "client.name", .{ .str = self.client_name });
        if (!explicit_learning and self.sdk_install_id.len > 0) try attr(&s, "sdk.install.id", .{ .str = self.sdk_install_id });
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
            const learning_event = std.mem.eql(u8, e.body, "score") or std.mem.eql(u8, e.body, "run") or std.mem.eql(u8, e.body, "fleet");
            if (learning_event and !learning_allowed) continue;
            if (std.mem.eql(u8, e.body, "fleet") and
                !std.mem.eql(u8, e.kind, "propose") and
                !std.mem.eql(u8, e.kind, "submit") and
                !std.mem.eql(u8, e.kind, "elite_pull")) continue;
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
                try telemetry_score.write(&s, e);
            } else if (std.mem.eql(u8, e.body, "run")) {
                try attr(&s, "prompt_sha", .{ .str = e.detail });
                try attr(&s, "variant", .{ .int = @intFromBool(std.mem.eql(u8, e.kind, "variant")) });
                try attr(&s, "ok", .{ .int = @intFromBool(e.flag) });
                try attr(&s, "duration_ms", .{ .int = e.ms });
                // Session run id (issue #168 Gap 6): the same run_id score
                // records carry, so outcome and fitness rows join per execution.
                if (e.run_id.len > 0) try attr(&s, "run_id", .{ .str = e.run_id });
                if (e.extra.len > 0) try attr(&s, "tools", .{ .str = e.extra });
            } else if (std.mem.eql(u8, e.body, "fleet")) {
                try attr(&s, "kind", .{ .str = e.kind });
                var niche_buf: [23]u8 = undefined;
                const niche = scoring.telemetryNiche(&niche_buf, e.extra);
                if (niche.len > 0) try attr(&s, "niche", .{ .str = niche });
                var hash_buf: [16]u8 = undefined;
                const prompt_sha = scoring.telemetryHash(&hash_buf, e.detail, 16);
                if (prompt_sha.len > 0) try attr(&s, "prompt_sha", .{ .str = prompt_sha });
                const parent_sha = scoring.telemetryHash(&hash_buf, e.run_id, 16);
                if (parent_sha.len > 0) try attr(&s, "parent_sha", .{ .str = parent_sha });
                if (e.prov.len > 0) {
                    var fit = std.mem.splitScalar(u8, e.prov, '\t');
                    if (fit.next()) |pc| if (scoring.telemetryProviderClass(pc)) |projected| try attr(&s, "provider_class", .{ .str = projected });
                    if (fit.next()) |eh| {
                        const eval_hash = scoring.telemetryHash(&hash_buf, eh, 8);
                        if (eval_hash.len > 0) try attr(&s, "eval_set_hash", .{ .str = eval_hash });
                    }
                }
                if (std.mem.eql(u8, e.kind, "elite_pull")) try attr(&s, "n_elites", .{ .int = @min(@max(e.tasks, 0), 1000) });
                const admitted_text = learning_privacy.templateTextForUpload(self.io, e.text);
                if (admitted_text.len > 0) try attr(&s, "prompt_text", .{ .str = admitted_text });
            } else {
                if (e.kind.len > 0) try attr(&s, "kind", .{ .str = e.kind });
                if (e.detail.len > 0) try attr(&s, "detail", .{ .str = e.detail });
                if (std.mem.eql(u8, e.body, "task")) {
                    // task_outcome.zig goal events: effort rides as numeric
                    // attrs; the worker stores the attrs JSON verbatim.
                    try attr(&s, "turns", .{ .int = e.tasks });
                    try attr(&s, "calls", .{ .int = e.phases });
                    try attr(&s, "compactions", .{ .int = e.failed });
                    try attr(&s, "duration_ms", .{ .int = e.ms });
                }
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
        try obs.writeOtlp(&s, self.start_unix_ms);
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
            try attr(&s, "prompt_variants", .{ .int = @intCast(if (learning_allowed) self.prompt_variants else 0) });
            try attr(&s, "scores_recorded", .{ .int = @intCast(if (learning_allowed) self.scores_recorded else 0) });
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
