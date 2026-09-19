import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { eventLabel, formatDuration, isTraceId, parseTraceLine, summarizeTrace } from "./run-traces.ts";

const sample = [
  JSON.stringify({ run_id: "abc", t: 12, ev: "api", model: "terra", ms: 400, is_error: false }),
  JSON.stringify({ t: 80, ev: "tool", name: "bash", ms: 20, is_error: false }),
  JSON.stringify({ t: 90, ev: "tool", name: "edit", ms: 8, is_error: true }),
  JSON.stringify({ t: 5, ev: "prompt", text: "secret user prompt" }),
  "{not json}",
  JSON.stringify({ t: 100, ev: "first_token", model: "terra", ms: 30 }),
].join("\n");

describe("run traces", () => {
  it("keeps allowlisted operational fields and drops prompt text", () => {
    const { summary, events } = summarizeTrace("abc", sample);
    assert.equal(summary.id, "abc");
    assert.equal(summary.events, 4);
    assert.equal(summary.errors, 1);
    assert.equal(summary.durationMs, 100);
    assert.deepEqual(summary.models, ["terra"]);
    assert.deepEqual(summary.tools, ["bash", "edit"]);
    assert.ok(!JSON.stringify(events).includes("secret"));
    assert.equal(parseTraceLine(JSON.stringify({ ev: "prompt", t: 1, text: "nope" })), null);
  });

  it("rejects path-shaped trace ids", () => {
    assert.equal(isTraceId("abc123"), true);
    assert.equal(isTraceId("../etc/passwd"), false);
    assert.equal(isTraceId("a/b"), false);
    assert.equal(isTraceId(""), false);
  });

  it("labels and formats the timeline", () => {
    assert.equal(eventLabel({ t: 1, ev: "tool", name: "bash" }), "bash");
    assert.equal(eventLabel({ t: 1, ev: "api", model: "terra" }), "api · terra");
    assert.equal(formatDuration(420), "420ms");
    assert.equal(formatDuration(12_400), "12s");
    assert.equal(formatDuration(90_000), "1m 30s");
  });
});
