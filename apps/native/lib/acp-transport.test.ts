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
  child.emit("close", 1, null); await assert.rejects(pending, /exited/);
});

test("an exit before stdout drains does not lose the terminal reply", async () => {
  const { child, transport } = fixture(); const pending = transport.request("session/prompt", {}, 1000);
  child.emit("exit", 0, null);
  child.stdout.write(JSON.stringify({ id: 1, result: { stopReason: "end_turn" } }) + "\n");
  child.emit("close", 0, null);
  assert.deepEqual(await pending, { stopReason: "end_turn" });
});
test("a large batch of individually valid lines is not an oversized line", async () => {
  const { child, transport } = fixture(); let count = 0;
  const pending = transport.request("session/prompt", {}, 5000, () => count++);
  const line = JSON.stringify({ method: "session/update", params: { text: "x".repeat(1024) } }) + "\n";
  child.stdout.write(line.repeat(8200) + JSON.stringify({id:1,result:{}}) + "\n");
  await pending; assert.equal(count, 8201);
});

test("an oversized protocol line marks its session unusable so bootstrap can replace it", async () => {
  const { child, transport } = fixture(); const pending = transport.request("session/prompt", {}, 1000);
  assert.equal(transport.usable, true);
  child.stdout.write("x".repeat(8 * 1024 * 1024 + 1));
  await assert.rejects(pending, /exceeds limit/); assert.equal(transport.usable, false);
  await assert.rejects(transport.request("session/prompt"), /exceeds limit/);
});
