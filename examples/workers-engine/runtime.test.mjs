// Runs real workerd through cf; no substitute Wasm or native proxy.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const cwd = fileURLToPath(new URL(".", import.meta.url));
const wasm = new URL("../../zig-out/bin/graff-worker.wasm", import.meta.url);
async function start() {
  assert.ok(existsSync(wasm), "Build the actual engine first: zig build wasm-worker");
  const child = spawn(process.execPath, ["node_modules/cf/bin/cf", "dev"], {
    cwd, detached: true, stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, NO_COLOR: "1", CF_SEND_TELEMETRY: "false", WRANGLER_SEND_METRICS: "false" },
  });
  let output = "";
  const stop = async () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    const exited = once(child, "exit");
    try { process.kill(-child.pid, "SIGTERM"); } catch { return; }
    const timer = setTimeout(() => { try { process.kill(-child.pid, "SIGKILL"); } catch {} }, 3000);
    timer.unref();
    await exited;
    clearTimeout(timer);
  };
  try {
    const url = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`cf dev was not ready within 60s\n${output}`)), 60_000);
      const fail = error => { clearTimeout(timeout); reject(error); };
      child.once("error", fail);
      child.once("exit", code => fail(new Error(`cf dev exited (${code}) before ready\n${output}`)));
      const collect = data => {
        output = (output + data.toString().replace(/\x1b\[[0-9;]*m/g, "")).slice(-16_384);
        const local = output.match(/https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):\d+\/?/);
        // Wait for the dev server's readiness announcement, not a polling GET.
        if (local && /ready|listening/i.test(output)) {
          clearTimeout(timeout);
          resolve(local[0]);
        }
      };
      child.stdout.on("data", collect);
      child.stderr.on("data", collect);
    });
    return { url, stop };
  } catch (error) { await stop(); throw error; }
}

test("isolate-native model → host tool → model", { timeout: 90_000 }, async t => {
  const server = await start();
  t.after(server.stop);
  async function run(scenario, query = "") {
    const response = await fetch(new URL(`?scenario=${scenario}${query}`, server.url), { signal: AbortSignal.timeout(10_000) });
    return { response, body: await response.json() };
  }
  await t.test("async tool result returns to the model and produces the final answer", async () => {
    const { response, body } = await run("normal");
    assert.equal(response.status, 200, JSON.stringify(body));
    assert.equal(body.ok, true);
    assert.equal(body.telemetry, undefined, "telemetry is opt-in");
    assert.equal(body.text, "Found value:alpha");
    assert.equal(body.modelCalls, 2);
    assert.equal(body.toolCalls, 1);
    assert.deepEqual(body.observed, { modelCalls: 2, executed: 1, events: ["model", "tool", "model"] });
  });
  for (const scenario of ["unknown", "malformed", "bad-json"]) {
    await t.test(`${scenario} tool call never executes and is returned as a tool error`, async () => {
      const { response, body } = await run(scenario);
      assert.equal(response.status, 200, JSON.stringify(body));
      assert.equal(body.ok, true);
      assert.equal(body.text, "Tool rejected safely");
      assert.equal(body.modelCalls, 2);
      assert.deepEqual(body.observed, { modelCalls: 2, executed: 0, events: ["model", "model"] });
    });
  }
  await t.test("cancellation reaches an asynchronous host tool", async () => {
    const { response, body } = await run("cancel");
    assert.equal(response.status, 200, JSON.stringify(body));
    assert.equal(body.cancelled, true);
    assert.equal(body.toolAborted, true);
    assert.deepEqual(body.observed, { modelCalls: 1, executed: 1, events: ["model", "tool"] });
  });
  function traceSpans(body, codes, dropped = 0) {
    const { telemetry } = body;
    assert.equal(telemetry.dropped, dropped);
    assert.equal(telemetry.payloads.length, 1);
    const payload = telemetry.payloads[0];
    assert.deepEqual(payload.resourceSpans[0].resource.attributes,
      [{ key: "service.name", value: { stringValue: "codegraff-sdk" } }]);
    const spans = payload.resourceSpans[0].scopeSpans[0].spans;
    assert.equal(spans.length, codes.length);
    assert.equal(telemetry.spans.length, codes.length);
    for (const [i, span] of spans.entries()) {
      assert.equal(span.name, "graff.turn");
      assert.match(span.traceId, /^[0-9a-f]{32}$/);
      assert.match(span.spanId, /^[0-9a-f]{16}$/);
      assert.notEqual(BigInt(`0x${span.traceId}`), 0n);
      assert.notEqual(BigInt(`0x${span.spanId}`), 0n);
      assert.match(span.startTimeUnixNano, /^\d+$/);
      assert.match(span.endTimeUnixNano, /^\d+$/);
      assert.ok(BigInt(span.startTimeUnixNano) > 1_000_000_000_000_000_000n);
      assert.ok(BigInt(span.endTimeUnixNano) >= BigInt(span.startTimeUnixNano));
      assert.deepEqual(span.status, { code: codes[i] });
      const keys = ["traceId", "spanId", "name", "startTimeUnixNano", "endTimeUnixNano", "status"];
      const success = codes[i] === 1;
      if (success) keys.push("attributes");
      assert.deepEqual(Object.keys(span).sort(), keys.sort());
      assert.deepEqual(Object.keys(telemetry.spans[i]).sort(), keys.sort());
      if (success) {
        assert.deepEqual(span.attributes, [{ key: "graff.api_calls", value: { intValue: "2" } }]);
        assert.deepEqual(telemetry.spans[i].attributes, { "graff.api_calls": 2 });
      }
    }
    const encoded = JSON.stringify({ payloads: telemetry.payloads, spans: telemetry.spans });
    for (const excluded of ["Look up alpha", "Found value:alpha", "lookup", "lookup_1", "alpha",
      "mock-model", "mock.invalid", "collector.invalid", "synthetic-model-token", "synthetic-collector-token",
      "synthetic-observer-error", "Agent request failed", "Worker engine failed", "Agent cancelled",
      "synthetic-concurrent-prompt", "synthetic-poisoned-prompt", "Use lookup when a value is requested"]) {
      assert.equal(encoded.includes(excluded), false, `trace contains excluded content: ${excluded}`);
    }
    assert.equal(new Set(spans.map(span => span.traceId)).size, spans.length);
    assert.equal(new Set(spans.map(span => span.spanId)).size, spans.length);
    return spans;
  }
  await t.test("shared OTLP exporter observes a content-free turn without changing execution", async () => {
    const first = await run("normal", "&observe=export");
    assert.equal(first.response.status, 200);
    assert.equal(first.body.text, "Found value:alpha");
    assert.equal(first.body.modelCalls, 2);
    assert.equal(first.body.toolCalls, 1);
    assert.deepEqual(first.body.observed, { modelCalls: 2, executed: 1, events: ["model", "tool", "model"] });
    const [span] = traceSpans(first.body, [1]);
    const second = await run("normal", "&observe=export&probe=concurrent");
    assert.equal(second.response.status, 200);
    assert.equal(second.body.text, first.body.text);
    assert.deepEqual(second.body.observed, first.body.observed);
    assert.equal(second.body.telemetry.concurrentRejected, true);
    const [next] = traceSpans(second.body, [1]); // rejected concurrent prompt must not create a span
    assert.notEqual(next.traceId, span.traceId);
    assert.notEqual(next.spanId, span.spanId);
  });
  for (const observation of ["throw", "reject", "pending", "collector-fail"]) {
    await t.test(`${observation} observer/collector cannot change or block a completed turn`, async () => {
      const { response, body } = await run("normal", `&observe=${observation}`);
      assert.equal(response.status, 200);
      assert.equal(body.text, "Found value:alpha");
      assert.deepEqual(body.observed, { modelCalls: 2, executed: 1, events: ["model", "tool", "model"] });
      traceSpans(body, [1], observation === "collector-fail" ? 1 : 0);
    });
  }
  await t.test("failed and cancelled turns stay failed/poisoned with observational spans", async () => {
    for (const observation of ["throw", "reject", "pending"]) {
      for (const scenario of ["oversize", "cancel"]) {
        const { response, body } = await run(scenario, `&observe=${observation}&probe=poison`);
        assert.equal(response.status, scenario === "cancel" ? 200 : 500);
        assert.equal(body.ok, scenario === "cancel");
        assert.equal(body.telemetry.poisonedRejected, true);
        assert.deepEqual(body.observed, scenario === "cancel"
          ? { modelCalls: 1, executed: 1, events: ["model", "tool"] }
          : { modelCalls: 1, executed: 0, events: ["model"] });
        if (scenario === "cancel") {
          assert.equal(body.cancelled, true);
          assert.equal(body.toolAborted, true);
        }
        traceSpans(body, [2, 2]);
      }
    }
  });
  await t.test("model body is bounded without trusting Content-Length", async () => {
    const { response, body } = await run("oversize");
    assert.equal(response.status, 500);
    assert.equal(body.ok, false);
    assert.deepEqual(body.observed, { modelCalls: 1, executed: 0, events: ["model"] });
  });
});
