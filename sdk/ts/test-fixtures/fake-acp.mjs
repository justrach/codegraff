#!/usr/bin/env node
// Fake `graff acp`: JSON-RPC 2.0 on stdio, one message per line.
import { createInterface } from "node:readline";

const write = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);
const result = (id, value) => write({ jsonrpc: "2.0", id, result: value });
const fail = (id, code, message) => write({ jsonrpc: "2.0", id, error: { code, message } });
const update = (sessionId, payload) =>
  write({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: payload } });

let sessionId = null;

createInterface({ input: process.stdin }).on("line", (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  const { id, method, params } = msg;
  if (method === "initialize") {
    const requested = params?.protocolVersion ?? 1;
    result(id, {
      protocolVersion: Math.min(Number(requested) || 1, 1),
      agentCapabilities: {
        loadSession: false,
        promptCapabilities: { image: false, audio: false, embeddedContext: true },
      },
      agentImplementation: { name: "graff", title: "graff", version: "test" },
    });
    return;
  }
  if (method === "session/new") {
    sessionId = "acp-test-1";
    result(id, { sessionId });
    update(sessionId, {
      sessionUpdate: "available_commands_update",
      availableCommands: [{ name: "never", description: "List standing constraints.", input: { hint: "" } }],
    });
    return;
  }
  if (method === "session/cancel") {
    if (id !== undefined) result(id, {});
    return;
  }
  if (method === "session/prompt") {
    const sid = params?.sessionId ?? sessionId ?? "";
    const text = Array.isArray(params?.prompt)
      ? params.prompt.map((b) => b.text ?? "").join("\n")
      : "";
    if (text === "die") {
      fail(id, -32603, "boom");
      return;
    }
    update(sid, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "thinking" } });
    update(sid, {
      sessionUpdate: "tool_call",
      toolCallId: "call-1",
      title: "ls",
      kind: "execute",
      status: "pending",
      rawInput: { command: "ls" },
    });
    update(sid, {
      sessionUpdate: "tool_call_update",
      toolCallId: "call-1",
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: "ok" } }],
    });
    update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `echo:${text}` } });
    result(id, { stopReason: "end_turn" });
    return;
  }
  if (id !== undefined) fail(id, -32601, `method not found: ${method}`);
});
