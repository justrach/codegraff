//! Session metadata serialization, shared by immutable snapshot jobs. Message
//! bytes come from the chunk cache; only the empty array placeholder is emitted.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const session_peer = @import("session_peer.zig");
const subagent_ledger = @import("subagent_ledger.zig");
const protocol_seq = @import("protocol_seq.zig");
const http_headers = @import("http_headers.zig");
const unixMs = @import("util.zig").unixMs;

pub fn metadata(root: *Agent, gpa: Allocator, arena: Allocator, saved_msgs: std.json.Array, message_bytes: usize, title: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try @import("session_version.zig").write(&s); // ADR 0319: first, so a reader can refuse before the rest
    try @import("session_catalog.zig").write(root, &s);
    try @import("session_prompt.zig").write(root, &s);
    try s.objectField("provider");
    try s.write(root.provider.id);
    try s.objectField("model");
    try s.write(root.provider.model);
    try s.objectField("strict");
    try s.write(root.strict);
    try s.objectField("ultracode_mode");
    try s.write(root.ultracode_mode);
    try s.objectField("goal");
    if (root.goal) |g| {
        try s.beginObject();
        try s.objectField("objective");
        try s.write(g.objective);
        try s.objectField("status");
        try s.write(@tagName(g.status));
        try s.objectField("epoch");
        try s.write(g.epoch);
        try s.objectField("standing"); // a --goal objective resumes as one: the model still cannot retire it (#318)
        try s.write(g.standing);
        try s.objectField("created_ms");
        try s.write(g.created_ms);
        try s.objectField("updated_ms");
        try s.write(g.updated_ms);
        try s.endObject();
    } else try s.write(null);
    // #318: the checklist is durable, goal-scoped state - persist it with the
    // epoch that authored each item so resume cannot mix goals and checklists.
    try s.objectField("todos");
    try s.beginArray();
    for (root.todos.items) |t| {
        try s.beginObject();
        try s.objectField("content");
        try s.write(t.content);
        try s.objectField("status");
        try s.write(t.status);
        try s.objectField("epoch");
        try s.write(t.epoch);
        // #394: only when set, so a session with no retired history is written
        // exactly as before and older builds read it back unchanged.
        if (t.retired) {
            try s.objectField("retired");
            try s.write(true);
        }
        if (t.reason.len > 0) { // #1520: why a cancelled item was withdrawn; absent otherwise
            try s.objectField("reason");
            try s.write(t.reason);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("parent");
    if (root.session_parent) |parent| try s.write(parent) else try s.write(null);
    try s.objectField("title");
    try s.write(title);
    try s.objectField("updated_ms");
    try s.write(unixMs(root.io));
    try s.objectField("workspace");
    try s.write(@import("main.zig").g_cwd_display);
    try s.objectField("messages");
    try s.write(Value{ .array = std.json.Array.init(arena) });
    const context_estimate = root.contextEstimateFromInputBytes(message_bytes);
    // Preserve the last authoritative provider reading across resume. Responses
    // histories can contain compact encrypted-reasoning handles whose serialized
    // byte size substantially underestimates their server-side token cost; without
    // this floor a resumed near-limit session can miss pre-send compaction.
    try s.objectField("context_tokens");
    // std.json.Value represents parsed integers as i64, so keep the persisted
    // value inside the range loadSession can round-trip even if a malformed
    // provider once reported an extreme unsigned count.
    try s.write(@min(context_estimate.effective, @as(u64, std.math.maxInt(i64))));
    // Pair the provider reading with the locally measurable request component.
    // On resume we can preserve only their hidden-token delta while replacing
    // this component with today's prompt/tool-schema estimate.
    try s.objectField("context_local_tokens");
    try s.write(@min(context_estimate.local, @as(u64, std.math.maxInt(i64))));
    // #1686: the local component above uses this process's count of the
    // compaction state; a resume needs that count, not bytes/16.
    try @import("opaque_state_persist.zig").write(&s, root.provider, Value{ .array = saved_msgs });
    try root.compaction_window.write(&s);
    // #330: the --json protocol sequence high-water mark. A REPLACEMENT graff
    // resuming this session continues the numbering from here instead of
    // reissuing ids the supervisor has already read off the event log.
    try s.objectField("event_seq");
    try s.write(@min(protocol_seq.current(), @as(u64, std.math.maxInt(i64))));
    // kimi-code/codex key cache affinity on the durable conversation id; persisting ours keeps /resume warm.
    try s.objectField("cache_key");
    try s.write(http_headers.sessionId(root.io));
    try s.objectField("prompt_cache_key");
    try s.write(http_headers.projectRootId(root.io)); // idle-park resume must keep this partition
    try session_peer.writeFields(&s);
    try subagent_ledger.writeFields(&s, root.io);
    try s.endObject();

    return aw.toOwnedSlice();
}
