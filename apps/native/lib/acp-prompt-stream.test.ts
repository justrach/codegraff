import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { AcpTransport } from "./acp-transport";
import { createPromptStream } from "./acp-prompt-stream";
import { prompt } from "./acp-client";
import { applyAcpUpdate, emptyTurn, finishAcpTurn } from "./acp";
import { turnActivity } from "./turn-activity";

const updates = [
  { sessionUpdate: "tool_call", toolCallId: "write", title: "Update layout", status: "in_progress" },
  { sessionUpdate: "tool_call_update", toolCallId: "write", status: "completed" },
  { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The preview is ready." } },
  { sessionUpdate: "tool_call", toolCallId: "inspect", title: "Inspect preview", status: "in_progress" },
];

for (const outcome of ["end_turn", "cancelled", "error", "exit"] as const) {
  for (const delayedReader of [false, true]) {
    test(`${outcome} preserves results with ${delayedReader ? "buffered" : "live"} delivery`, async () => {
      const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stdin: new PassThrough() });
      const transport = new AcpTransport(child as never);
      let cancellations = 0;
      const { stream, pending } = createPromptStream(transport, {}, () => cancellations++);
      const original = globalThis.fetch;
      globalThis.fetch = async () => new Response(stream);
      let turn = emptyTurn();
      const read = async () => {
        try {
          for await (const update of prompt("fixture", "fixture", "hello")) turn = applyAcpUpdate(turn, update);
          turn = finishAcpTurn(turn);
        } catch (error) {
          turn = finishAcpTurn({ ...turn, status: "error", error: (error as Error).message });
        }
      };
      try {
        const reading = delayedReader ? null : read();
        for (const update of updates) child.stdout.write(JSON.stringify({ method: "session/update", params: { update } }) + "\n");
        if (outcome === "exit") child.emit("close", 1, null);
        else child.stdout.write(JSON.stringify(outcome === "error"
          ? { id: 1, error: { code: -32603, message: "Preview inspection failed" } }
          : { id: 1, result: { stopReason: outcome } }) + "\n");
        await pending.catch(() => {});
        // Let the rejection handler run before reading: controller.error used
        // to discard this entire batch, including the real error reply.
        await (reading ?? read());
        assert.equal(turn.text, "The preview is ready.");
        assert.deepEqual(turn.tools.map(tool => tool.status), ["ok", "interrupted"]);
        assert.equal(cancellations, 0, "terminal reader cleanup must not cancel a finished prompt");
        const activity = turnActivity(turn, Date.now());
        if (outcome === "error" || outcome === "exit") {
          assert.equal(activity.label, "Response interrupted");
          assert.match(activity.detail, /Completed tool results are kept/);
          assert.match(turn.error!, outcome === "error" ? /Preview inspection failed/ : /graff acp exited/);
        } else {
          assert.match(activity.label, outcome === "cancelled" ? /^Stopped$/ : /^Worked for /);
          assert.equal(turn.error, undefined);
        }
      } finally { globalThis.fetch = original; }
    });
  }
}

test("closing a live HTTP reader cancels once, and later failure cannot write into it", async () => {
  const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stdin: new PassThrough() });
  const transport = new AcpTransport(child as never);
  let cancellations = 0;
  const { stream, pending } = createPromptStream(transport, {}, () => cancellations++);
  await stream.cancel();
  child.emit("close", 0, null);
  await assert.rejects(pending, /exited/);
  assert.equal(cancellations, 1);
});
