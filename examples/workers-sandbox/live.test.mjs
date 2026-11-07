// Opt-in real inference + real hosted VM. Never writes the API key to disk.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const expectedModel = process.env.GRAFF_SANDBOX_TEST_MODEL ?? "ultramarine-1-flash";
const requestedModels = new Set();
const token = process.env.CODEGRAFF_API_KEY;
if (!token) throw new Error("Set CODEGRAFF_API_KEY to opt into billed sandbox/model execution");
const cwd = fileURLToPath(new URL(".", import.meta.url));
assert.ok(existsSync(new URL("../../zig-out/bin/graff-worker.wasm", import.meta.url)), "Build zig build wasm-worker first");
const gateway = "https://gateway.codegraff.com";
const owned = new Set();
const errors = [];
const calls = { model: 0, create: 0, exec: 0, upload: 0, download: 0, destroy: 0 };
let child;
let childOutput = "";
async function bodyBytes(stream, cap) {
  let size = 0;
  const chunks = [];
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > cap) throw new Error("Bridge response/request exceeded limit");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}
const bridge = createServer(async (request, response) => {
  try {
    const path = request.url ?? "";
    const model = request.method === "POST" && path === "/v1/chat/completions";
    const create = request.method === "POST" && path === "/v1/sandboxes";
    const operation = /^\/v1\/sandboxes\/([^/]+)(?:\/(exec|upload|download))?$/.exec(path);
    if (!model && !create && (!operation || !owned.has(decodeURIComponent(operation[1])) ||
        (operation[2] ? request.method !== "POST" : request.method !== "DELETE"))) {
      response.writeHead(403); response.end(); return;
    }
    let bytes = await bodyBytes(request, 128 * 1024);
    if (model) {
      if (++calls.model > 8) throw new Error("Live model-call budget exceeded");
      const payload = JSON.parse(bytes.toString());
      assert.equal(payload.model, expectedModel, "Worker requested an unexpected model");
      requestedModels.add(payload.model);
      payload.max_tokens = 8192;
      bytes = Buffer.from(JSON.stringify(payload));
    } else if (create) {
      const payload = JSON.parse(bytes.toString());
      assert.equal(payload.provider, "fleet");
      assert.equal(payload.autoStopMinutes, 5);
      calls.create++;
    } else if (operation[2]) calls[operation[2]]++;
    const result = await fetch(gateway + path, {
      method: request.method, redirect: "error",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: request.method === "DELETE" ? undefined : bytes,
      signal: AbortSignal.timeout(create ? 100_000 : 65_000),
    });
    const data = await bodyBytes(result.body, 2 * 1024 * 1024);
    let json;
    try { json = JSON.parse(data.toString()); } catch { /* retain the protocol response */ }
    if (create) {
      const id = json?.id ?? json?.error?.sandboxId;
      if (typeof id === "string") owned.add(id);
    }
    if (operation && !operation[2] && result.ok) { owned.delete(decodeURIComponent(operation[1])); calls.destroy++; }
    if (!result.ok) {
      const code = json?.error?.type;
      errors.push({ route: model ? "model" : create ? "create" : operation?.[2] ?? "destroy", status: result.status,
        code: typeof code === "string" && /^[a-z0-9_]{1,80}$/.test(code) ? code : "upstream_error" });
    }
    response.writeHead(result.status, { "content-type": result.headers.get("content-type") ?? "application/json" });
    response.end(data);
  } catch {
    errors.push({ route: "bridge", code: "transport_error" });
    response.writeHead(502); response.end('{"error":{"type":"bridge_transport_error"}}');
  }
});

async function stopChild() {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, "exit");
  try { process.kill(-child.pid, "SIGTERM"); } catch { return; }
  const timer = setTimeout(() => { try { process.kill(-child.pid, "SIGKILL"); } catch {} }, 3000);
  timer.unref();
  await exited;
  clearTimeout(timer);
}

try {
  await new Promise(resolve => bridge.listen(0, "127.0.0.1", resolve));
  const env = { ...process.env, NO_COLOR: "1", CF_SEND_TELEMETRY: "false", WRANGLER_SEND_METRICS: "false",
    GRAFF_SANDBOX_TEST_BRIDGE: `http://127.0.0.1:${bridge.address().port}` };
  // The real credential exists only in this bridge process, not cf/Vite/Wasm/VM.
  delete env.CODEGRAFF_API_KEY;
  delete env.NODE_DEBUG;
  delete env.NODE_DEBUG_NATIVE;
  child = spawn(process.execPath, ["node_modules/cf/bin/cf", "dev"], { cwd, detached: true, stdio: ["ignore", "pipe", "pipe"], env });
  const local = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("cf dev readiness timed out")), 60_000);
    child.once("error", error => { clearTimeout(timer); reject(error); });
    child.once("exit", code => { clearTimeout(timer); reject(new Error(`cf dev exited before ready (${code})`)); });
    const collect = data => {
      childOutput = (childOutput + data.toString().replace(/\x1b\[[0-9;]*m/g, "")).slice(-16_384);
      const match = childOutput.match(/https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):\d+\/?/);
      if (match && /ready|listening/i.test(childOutput)) { clearTimeout(timer); resolve(match[0]); }
    };
    child.stdout.on("data", collect); child.stderr.on("data", collect);
  });
  const response = await fetch(local, { method: "POST", signal: AbortSignal.timeout(220_000) });
  const result = await response.json();
  // Report only synthetic task results and aggregate calls, never IDs/credentials.
  console.log(JSON.stringify({ status: response.status, result, requestedModels: [...requestedModels], calls, upstreamErrors: errors }, null, 2));
  assert.equal(response.status, 200, "Worker sandbox task failed");
  assert.equal(result.ok, true);
  assert.equal(result.model, expectedModel);
  assert.deepEqual([...requestedModels], [expectedModel]);
  assert.equal(result.baselineFailed, true);
  assert.equal(result.testsUnchanged, true);
  assert.equal(result.credentialIsolation, true);
  assert.equal(result.sandboxDestroyed, true);
  assert.equal(result.verification.exitCode, 0);
  assert.match(result.verification.result, /RANDOMIZED_CASES=2000/);
  assert.ok(result.sandboxToolCalls > 0 && calls.model >= 2 && calls.create === 1 && calls.destroy === 1);
  assert.equal(owned.size, 0);
  console.log("PASS: workerd Durable Object → Zig/Wasm → real model → Codegraff VM → verified repair; VM destroyed");
} finally {
  await stopChild();
  // Last-resort cleanup of ONLY VMs created by this live test, not other tasks.
  for (const id of owned) {
    const response = await fetch(`${gateway}/v1/sandboxes/${encodeURIComponent(id)}`, {
      method: "DELETE", redirect: "error", headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) throw new Error("Live test VM cleanup failed; its five-minute lease remains the fallback");
    owned.delete(id);
  }
  await new Promise(resolve => bridge.close(resolve));
}
