//! POC showing what an OTel replacement for the current PostHog event flow
//! would look like, with explicit success/failure signals at three layers:
//!
//!   1. **Operational** — `Status::Ok | Status::Error` (built-in), plus
//!      `graff.request.outcome` enum and `graff.retry.attempts`.
//!   2. **Tool / argument** — `graff.tool.outcome` enum capturing whether the
//!      tool executor accepted the arguments and ran cleanly, plus
//!      `graff.tool.grammar.conforms` for custom-grammar tools.
//!   3. **Task** — `turn.outcome` enum and a `user.followup.kind`
//!      classification on the *next* turn (continuation | correction |
//!      approval | termination | none_observed), so we can compute a
//!      task-success rate offline.
//!
//! Three scenarios are simulated to show all three layers' signals:
//!   - happy_path:     everything succeeds cleanly
//!   - retry_to_ok:    upstream 503, retry succeeds — operational hiccup,
//!                     task ultimately fine
//!   - task_failure:   model called the wrong tool / produced a bad answer;
//!                     user's next prompt is classified as `correction`
//!
//! Output: /tmp/otel_poc.log (run with cargo test ... -- --nocapture)

#![cfg(test)]

use opentelemetry::trace::{Span, Status, Tracer, TracerProvider as _};
use opentelemetry::KeyValue;
use opentelemetry_sdk::Resource;
use opentelemetry_sdk::trace::TracerProvider;
use opentelemetry_stdout::SpanExporter;

fn init_provider() -> TracerProvider {
    let exporter = SpanExporter::default();
    let resource = Resource::new(vec![
        KeyValue::new("service.name", "graff"),
        KeyValue::new("service.version", env!("CARGO_PKG_VERSION")),
        KeyValue::new("client.id", "test-client-id-abc-123"),
        KeyValue::new("host.arch", std::env::consts::ARCH),
        KeyValue::new("os.name", std::env::consts::OS),
        KeyValue::new("process.runtime.name", "rust"),
    ]);
    TracerProvider::builder()
        .with_simple_exporter(exporter)
        .with_resource(resource)
        .build()
}

/// Scenario 1: clean success.
fn scenario_happy_path(tracer: &impl Tracer) {
    let mut turn = tracer.start("agent.turn");
    turn.set_attribute(KeyValue::new("scenario", "happy_path"));
    turn.set_attribute(KeyValue::new("conversation.id", "conv-001"));
    turn.set_attribute(KeyValue::new("turn.index", 1_i64));
    turn.add_event("user.prompt", vec![KeyValue::new("user.prompt.length_chars", 88_i64)]);

    let mut req = tracer.start("gen_ai.request");
    req.set_attribute(KeyValue::new("gen_ai.system", "openai"));
    req.set_attribute(KeyValue::new("gen_ai.request.model", "gpt-5.5"));
    req.set_attribute(KeyValue::new("gen_ai.usage.input_tokens", 800_i64));
    req.set_attribute(KeyValue::new("gen_ai.usage.output_tokens", 64_i64));
    req.set_attribute(KeyValue::new("graff.duration_ms", 1100_i64));
    req.set_attribute(KeyValue::new("graff.retry.attempts", 0_i64));
    req.set_attribute(KeyValue::new("graff.request.outcome", "ok"));
    req.set_status(Status::Ok);
    req.end();

    let mut tool = tracer.start("gen_ai.tool_call");
    tool.set_attribute(KeyValue::new("gen_ai.tool.name", "read"));
    tool.set_attribute(KeyValue::new("gen_ai.tool.format", "function"));
    tool.set_attribute(KeyValue::new("graff.tool.duration_ms", 8_i64));
    tool.set_attribute(KeyValue::new("graff.tool.outcome", "ok"));
    tool.set_status(Status::Ok);
    tool.end();

    turn.set_attribute(KeyValue::new("turn.outcome", "completed"));
    turn.set_attribute(KeyValue::new("turn.user_followup_kind", "continuation"));
    turn.set_attribute(KeyValue::new("turn.tool_calls", 1_i64));
    turn.set_attribute(KeyValue::new("turn.llm_requests", 1_i64));
    turn.set_status(Status::Ok);
    turn.end();
}

/// Scenario 2: operational failure (upstream 503), retried, ultimately succeeds.
fn scenario_retry_to_ok(tracer: &impl Tracer) {
    let mut turn = tracer.start("agent.turn");
    turn.set_attribute(KeyValue::new("scenario", "retry_to_ok"));
    turn.set_attribute(KeyValue::new("conversation.id", "conv-002"));

    // First request — upstream is overloaded, fails fast
    let mut req1 = tracer.start("gen_ai.request");
    req1.set_attribute(KeyValue::new("gen_ai.request.model", "gpt-5.5"));
    req1.set_attribute(KeyValue::new("graff.retry.attempts", 0_i64));
    req1.set_attribute(KeyValue::new("graff.request.outcome", "transient_error"));
    req1.set_status(Status::error("upstream HTTP 503"));
    req1.add_event(
        "exception",
        vec![
            KeyValue::new("exception.type", "upstream_unavailable"),
            KeyValue::new("exception.retryable", true),
        ],
    );
    req1.end();

    // Retry — works
    let mut req2 = tracer.start("gen_ai.request");
    req2.set_attribute(KeyValue::new("gen_ai.request.model", "gpt-5.5"));
    req2.set_attribute(KeyValue::new("graff.retry.attempts", 1_i64));
    req2.set_attribute(KeyValue::new("graff.request.outcome", "ok"));
    req2.set_attribute(KeyValue::new("gen_ai.usage.input_tokens", 1024_i64));
    req2.set_attribute(KeyValue::new("gen_ai.usage.output_tokens", 56_i64));
    req2.set_status(Status::Ok);
    req2.end();

    let mut tool = tracer.start("gen_ai.tool_call");
    tool.set_attribute(KeyValue::new("gen_ai.tool.name", "fs_search"));
    tool.set_attribute(KeyValue::new("gen_ai.tool.format", "function"));
    tool.set_attribute(KeyValue::new("graff.tool.outcome", "ok"));
    tool.set_status(Status::Ok);
    tool.end();

    turn.set_attribute(KeyValue::new("turn.outcome", "completed_with_retry"));
    turn.set_attribute(KeyValue::new("turn.user_followup_kind", "approval"));
    turn.set_attribute(KeyValue::new("turn.tool_calls", 1_i64));
    turn.set_attribute(KeyValue::new("turn.llm_requests", 2_i64));
    turn.set_status(Status::Ok);
    turn.end();
}

/// Scenario 3: task failure — model produced a wrong answer, user corrected
/// in the next turn. Operational signals all green; only `turn.user_followup_kind`
/// = "correction" reveals the failure.
fn scenario_task_failure(tracer: &impl Tracer) {
    let mut turn = tracer.start("agent.turn");
    turn.set_attribute(KeyValue::new("scenario", "task_failure"));
    turn.set_attribute(KeyValue::new("conversation.id", "conv-003"));

    let mut req = tracer.start("gen_ai.request");
    req.set_attribute(KeyValue::new("gen_ai.request.model", "gpt-5.5"));
    req.set_attribute(KeyValue::new("graff.request.outcome", "ok"));
    req.set_attribute(KeyValue::new("gen_ai.usage.input_tokens", 950_i64));
    req.set_attribute(KeyValue::new("gen_ai.usage.output_tokens", 71_i64));
    req.set_status(Status::Ok);
    req.end();

    // Tool call ran cleanly at the executor level...
    let mut tool = tracer.start("gen_ai.tool_call");
    tool.set_attribute(KeyValue::new("gen_ai.tool.name", "timestamp_parse"));
    tool.set_attribute(KeyValue::new("gen_ai.tool.format", "custom"));
    tool.set_attribute(KeyValue::new("graff.tool.grammar.syntax", "regex"));
    tool.set_attribute(KeyValue::new("graff.tool.grammar.conforms", true));
    tool.set_attribute(KeyValue::new("graff.tool.outcome", "ok"));
    tool.set_status(Status::Ok);
    tool.end();

    // ... but the *content* was wrong. Detected only by user correction next turn.
    turn.set_attribute(KeyValue::new("turn.outcome", "completed"));
    turn.set_attribute(KeyValue::new("turn.user_followup_kind", "correction"));
    turn.set_attribute(KeyValue::new("turn.user_followup_signal", "next_prompt_starts_with_no_or_actually"));
    turn.set_attribute(KeyValue::new("turn.tool_calls", 1_i64));
    turn.set_attribute(KeyValue::new("turn.llm_requests", 1_i64));
    turn.set_status(Status::Ok); // operational success — task failure is a separate signal
    turn.end();
}

#[test]
fn show_otel_shape() {
    let provider = init_provider();
    let tracer = provider.tracer("graff");

    scenario_happy_path(&tracer);
    scenario_retry_to_ok(&tracer);
    scenario_task_failure(&tracer);

    let _ = provider.force_flush();
}
