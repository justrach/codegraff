import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { AcpTransport } from "./acp-transport";
function fixture() {
  const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stdin: new PassThrough() });
  return { child, transport: new AcpTransport(child as never) };
}
test("catalog replies cannot steal assistant notifications or close the prompt stream", async () => {
  const { child, transport } = fixture(); const lines: string[] = [];
  const prompt = transport.request("session/prompt", {}, 1000, line => lines.push(line));
  const catalog = transport.request("graff/models", {}, 1000);
  const wire = [{ method: "session/update", params: { text: "hello 🦊" } }, { id: 2, result: { models: [] } }, { method: "session/update", params: { text: "world" } }, { id: 1, result: { stopReason: "end_turn" } }].map(row => JSON.stringify(row)).join("\n") + "\n";
  const data = Buffer.from(wire); const split = data.indexOf(Buffer.from('🦊')) + 2;
  child.stdout.write(data.subarray(0, split)); child.stdout.write(data.subarray(split));
  await Promise.all([prompt, catalog]);
  assert.equal(lines.length, 3); assert.match(lines[0], /hello 🦊/); assert.match(lines[1], /world/);
  child.stdout.write(JSON.stringify({ method: "session/update", params: {} }) + "\n");
  assert.equal(lines.length, 3); assert.equal(child.stdout.listenerCount("data"), 1);
});
test("a child exit rejects pending requests instead of leaving a blank conversation", async () => {
  const { child, transport } = fixture(); const pending = transport.request("session/prompt", {}, 1000);
  child.emit("exit", 1, null); await assert.rejects(pending, /exited/);
});
