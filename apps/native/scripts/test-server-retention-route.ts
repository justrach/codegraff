import { strict as assert } from "node:assert";
import { writeFileSync } from "node:fs";
import { NextRequest } from "next/server";
import { POST } from "../app/api/acp/route";

const cwd = process.env.GRAFF_RETENTION_WORKSPACE!;
const evidence = process.env.GRAFF_RETENTION_EVIDENCE!;
const chat = "retention-fixture:chat";
const slots = (globalThis as any).__graffAcpSlots as Map<string, any>;
async function request(method: string, params: object = {}) {
  const response = await POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({ chat, method, params }),
  }));
  const text = await response.text();
  assert.equal(response.status, 200, text);
  return text;
}
async function prompt(name: string, text: string) {
  const stream = await request("session/prompt", { prompt: [{ type: "text", text }] });
  writeFileSync(`${evidence}/${name}.jsonl`, stream);
  const events = stream.trim().split("\n").map(line => JSON.parse(line));
  assert(!events.some(event => event.error), stream);
  assert(events.some(event => event.result?.stopReason === "end_turn"), stream);
  assert(events.some(event => event.params?.update?.status === "completed" &&
    (JSON.stringify(event.params.update.content) ?? "").includes("listener ready")), stream);
}
async function waitExit(child: any) {
  const deadline = Date.now() + 10_000;
  while (child.exitCode === null && child.signalCode === null) {
    assert(Date.now() < deadline, "worker failed to retire");
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}
let first: any;
let second: any;
try {
  await request("bootstrap", { cwd, model: "lmstudio", mcp: false });
  first = slots.get(chat).child;
  await prompt("first-prompt", "Start the isolated listener and verify readiness.");
  await request("bootstrap", { cwd, model: "lmstudio", reset: true, mcp: false });
  second = slots.get(chat).child;
  const replacement = { oldPid: first.pid, newPid: second.pid, oldExit: first.exitCode, oldSignal: first.signalCode };
  writeFileSync(`${evidence}/replacement.json`, JSON.stringify(replacement, null, 2));
  assert(first.exitCode !== null || first.signalCode !== null, "replacement was ready while old worker was still alive");
  await prompt("second-prompt", "Verify the existing listener is still reachable.");
  await request("dispose");
  await waitExit(second);
  assert.equal(first.exitCode, 0, "old worker did not exit gracefully");
  assert.equal(second.exitCode, 0, "disposed worker did not exit gracefully");
  await request("shutdown");
  const refused = await POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({chat, method:"bootstrap", params:{cwd, model:"lmstudio", mcp:false}}),
  }));
  assert.equal(refused.status, 502);
  assert((await refused.text()).includes("shutting down"));
  assert.equal(slots.size, 0, "shutdown allowed a replacement worker");
  console.log("PASS GUI API: old worker exits before replacement is ready; listener remains reachable");
} finally {
  await request("dispose");
  for (const child of [first, second].filter(Boolean)) {
    try { child.stdin.end(); await waitExit(child); }
    catch { child.kill("SIGKILL"); }
  }
}
