//! Public schema types and limits shared by the behavioral trace producer.

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
pub const max_tool_args_bytes = 4096;
pub const max_text_delta_bytes = 2048;

/// A dropped line failed before any byte reached the file. A sink failure may
/// have written a partial tail, so the producer must stop using that sink.
pub const LineResult = enum { written, dropped, sink_failed };
