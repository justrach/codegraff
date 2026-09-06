import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { applyAcpUpdate, emptyTurn, finishAcpTurn, parseRpcLine, turnBlocks } from "./acp.ts";

describe("parseRpcLine", () => {
  it("skips blanks and noise", () => {
    assert.equal(parseRpcLine(""), null);
    assert.equal(parseRpcLine("not-json"), null);
  });

  it("parses a session/update notification", () => {
    const line = parseRpcLine(
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}',
    );
    assert.ok(line && "method" in line && line.method === "session/update");
    assert.equal(line.params.update.sessionUpdate, "agent_message_chunk");
  });
});

describe("applyAcpUpdate", () => {
  it("keeps the file chip when a completion update omits its title and input", () => {
    let turn = applyAcpUpdate(emptyTurn(), {sessionUpdate:'tool_call', toolCallId:'read-one', title:'read_file', kind:'read', rawInput:{path:'navigation.ts'}, status:'in_progress'});
    turn = applyAcpUpdate(turn, {sessionUpdate:'tool_call_update', toolCallId:'read-one', status:'completed'});
    assert.equal(turn.tools[0].name, 'Read file');
    assert.equal(turn.tools[0].chip, 'navigation.ts');
    assert.equal(turn.tools[0].path, 'navigation.ts');
  });
  it("streams thought then text onto a live turn", () => {
    let turn = emptyTurn();
    turn = applyAcpUpdate(turn, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "look around" } });
    assert.equal(turn.reasoning, "look around");
    assert.equal(turn.status, "thinking");
    turn = applyAcpUpdate(turn, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hello" } });
    turn = applyAcpUpdate(turn, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: " world" } });
    assert.equal(turn.text, "Hello world");
    assert.equal(turn.status, "streaming");
  });

  it("pairs tool_call and tool_call_update onto one chip", () => {
    let turn = emptyTurn();
    turn = applyAcpUpdate(turn, {
      sessionUpdate: "tool_call",
      toolCallId: "call-1",
      title: "src/main.zig",
      kind: "read",
      status: "pending",
      rawInput: { path: "src/main.zig" },
    });
    assert.equal(turn.tools[0]?.status, "running");
    assert.equal(turn.tools[0]?.chip, "src/main.zig");
    assert.equal(turn.tools[0]?.name, "Read");
    turn = applyAcpUpdate(turn, {
      sessionUpdate: "tool_call_update",
      toolCallId: "call-1",
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: "fn main" } }],
    });
    assert.equal(turn.tools[0]?.status, "ok");
    assert.equal(turn.tools[0]?.id, "call-1");
    assert.match(turn.tools[0]?.detail.at(-1)?.text ?? "", /fn main/);
  });

  it("lifts todo_write items and edit diffs", () => {
    let turn = emptyTurn();
    turn = applyAcpUpdate(turn, {
      sessionUpdate: "tool_call",
      toolCallId: "call-2",
      title: "src/main.zig",
      kind: "edit",
      status: "pending",
      rawInput: { path: "src/main.zig", old_string: "foo", new_string: "bar" },
    });
    turn = applyAcpUpdate(turn, {
      sessionUpdate: "tool_call_update",
      toolCallId: "call-2",
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: "replaced 1 span" } }],
    });
    assert.equal(turn.diffs[0]?.file, "src/main.zig");

    turn = applyAcpUpdate(turn, {
      sessionUpdate: "tool_call",
      toolCallId: "call-3",
      title: "todo_write",
      kind: "think",
      status: "pending",
      rawInput: {
        todos: [
          { id: "a", content: "Read README", status: "completed" },
          { id: "b", content: "Edit main", status: "in_progress" },
        ],
      },
    });
    assert.equal(turn.todos.length, 2);
    assert.equal(turn.todos[1]?.status, "in_progress");
  });

  it("interleaves tools at the text cursor they landed on", () => {
    let turn = emptyTurn();
    turn = applyAcpUpdate(turn, {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "Hello" },
    });
    turn = applyAcpUpdate(turn, {
      sessionUpdate: "tool_call",
      toolCallId: "c1",
      title: "codedb",
      kind: "read",
      status: "pending",
      rawInput: { command: "context how does auth work" },
    });
    assert.equal(turn.tools[0]?.atChars, 5);
    assert.equal(turn.tools[0]?.name, "Codedb");
    assert.equal(turn.tools[0]?.chip, "context how does auth work");
    turn = applyAcpUpdate(turn, {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: " more" },
    });
    const blocks = turnBlocks(turn.text, turn.tools);
    assert.equal(blocks[0]?.kind, "text");
    if (blocks[0]?.kind === "text") assert.equal(blocks[0].text, "Hello");
    assert.equal(blocks[1]?.kind, "tools");
    assert.equal(blocks[2]?.kind, "text");
  });

  it("finishAcpTurn stops unresolved chips without inventing success", () => {
    let turn = emptyTurn();
    turn = applyAcpUpdate(turn, {
      sessionUpdate: "tool_call",
      toolCallId: "call-9",
      title: "ls",
      kind: "execute",
      status: "in_progress",
    });
    turn = finishAcpTurn(turn);
    assert.equal(turn.status, "done");
    assert.equal(turn.tools[0]?.status, "interrupted");
  });
});
