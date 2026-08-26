import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { applyEvent, emptyTurn, parseEventLine } from "./graff-events.ts";

describe("parseEventLine", () => {
  it("skips blanks and noise", () => {
    assert.equal(parseEventLine(""), null);
    assert.equal(parseEventLine("not-json"), null);
  });

  it("parses a typed event", () => {
    const ev = parseEventLine('{"seq":1,"type":"text","text":"hi"}');
    assert.deepEqual(ev, { seq: 1, type: "text", text: "hi" });
  });
});

describe("applyEvent", () => {
  it("streams text and reasoning onto a live turn", () => {
    let turn = emptyTurn();
    turn = applyEvent(turn, { type: "started", provider: "openai", model: "gpt-5.5" });
    turn = applyEvent(turn, { type: "reasoning", text: "look around" });
    turn = applyEvent(turn, { type: "text", text: "Hello" });
    turn = applyEvent(turn, { type: "text", text: " world" });
    assert.equal(turn.model, "gpt-5.5");
    assert.equal(turn.reasoning, "look around");
    assert.equal(turn.text, "Hello world");
    assert.equal(turn.status, "streaming");
  });

  it("maps tool_call / tool_result onto chips and edit diffs", () => {
    let turn = emptyTurn();
    turn = applyEvent(turn, {
      type: "tool_call",
      name: "edit_file",
      input: { path: "src/main.zig", old_string: "foo", new_string: "bar" },
    });
    assert.equal(turn.tools[0]?.status, "running");
    assert.equal(turn.tools[0]?.chip, "src/main.zig");
    turn = applyEvent(turn, {
      type: "tool_result",
      name: "edit_file",
      is_error: false,
      text: "replaced 1 span",
    });
    assert.equal(turn.tools[0]?.status, "ok");
    assert.equal(turn.diffs[0]?.file, "src/main.zig");
  });

  it("surfaces ask_user and settles on turn", () => {
    let turn = emptyTurn();
    turn = applyEvent(turn, {
      type: "ask_user",
      call_id: "q1",
      question: "Apply the edit?",
      input: {},
    });
    assert.equal(turn.status, "ask");
    assert.equal(turn.ask?.callId, "q1");
    turn = applyEvent(turn, { type: "turn", text: "done", context_tokens: 1, cost_usd: 0.01 });
    assert.equal(turn.status, "done");
    assert.equal(turn.ask, undefined);
    assert.equal(turn.costUsd, 0.01);
  });

  it("lifts todo_write items into the side pane", () => {
    let turn = emptyTurn();
    turn = applyEvent(turn, {
      type: "tool_call",
      name: "todo_write",
      input: {
        todos: [
          { id: "a", content: "Read README", status: "completed" },
          { id: "b", content: "Edit main", status: "in_progress" },
        ],
      },
    });
    assert.equal(turn.todos.length, 2);
    assert.equal(turn.todos[1]?.status, "in_progress");
  });
});
