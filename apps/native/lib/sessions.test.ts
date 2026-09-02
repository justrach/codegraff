import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { dateGroup, groupSessions, sessionHint, transcriptFromMessages } from "./sessions.ts";

describe("transcriptFromMessages", () => {
  it("folds assistant + tool messages into one turn per user message", () => {
    const raw = [
      { role: "user", content: "write a haiku file" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          { id: "c1", type: "function", function: { name: "write_file", arguments: '{"path":"demo.md","content":"a\\nb\\nc"}' } },
        ],
      },
      { role: "tool", tool_call_id: "c1", content: "wrote 6 bytes to demo.md" },
      {
        role: "assistant",
        content: null,
        tool_calls: [{ id: "c2", type: "function", function: { name: "attempt_completion", arguments: '{"result":"Created demo.md."}' } }],
      },
      { role: "tool", tool_call_id: "c2", content: "completion recorded" },
      { role: "user", content: "thanks" },
      { role: "assistant", content: "You're welcome." },
    ];
    const out = transcriptFromMessages(raw, "glm-5.3-flash");
    assert.equal(out.length, 4);
    assert.deepEqual(out[0], { role: "user", text: "write a haiku file" });
    const first = out[1];
    assert.equal(first.role, "assistant");
    if (first.role !== "assistant") return;
    assert.equal(first.turn.status, "done");
    assert.equal(first.turn.model, "glm-5.3-flash");
    assert.equal(first.turn.text, "Created demo.md.");
    assert.equal(first.turn.tools.length, 1);
    const row = first.turn.tools[0];
    assert.equal(row.name, "Write file");
    assert.equal(row.icon, "write");
    assert.equal(row.path, "demo.md");
    assert.equal(row.status, "ok");
    assert.deepEqual(row.detail.map((d) => d.text), ["3 lines", "wrote 6 bytes to demo.md"]);
    assert.deepEqual(out[2], { role: "user", text: "thanks" });
    const last = out[3];
    if (last.role !== "assistant") return;
    assert.equal(last.turn.text, "You're welcome.");
  });

  it("marks failed tool results, keeps todos, and survives junk", () => {
    const raw = [
      { role: "user", content: [{ type: "text", text: "plan it" }] },
      {
        role: "assistant",
        content: "On it.",
        tool_calls: [
          { id: "t1", type: "function", function: { name: "todo_write", arguments: '{"todos":[{"content":"step one","status":"in_progress"}]}' } },
          { id: "b1", type: "function", function: { name: "bash", arguments: '{"command":"false"}' } },
          { id: "x1", type: "function", function: { name: "mcp__codedbpro__read", arguments: "not json" } },
        ],
      },
      { role: "tool", tool_call_id: "b1", content: "Error: exit 1" },
      "garbage",
      null,
      { role: "user", content: "" },
    ];
    const out = transcriptFromMessages(raw);
    assert.equal(out.length, 2);
    const turn = out[1];
    if (turn.role !== "assistant") return;
    assert.equal(turn.turn.text, "On it.");
    assert.deepEqual(turn.turn.todos, [{ id: "todo-0", content: "step one", status: "in_progress" }]);
    const bash = turn.turn.tools.find((t) => t.id === "b1");
    assert.equal(bash?.status, "error");
    assert.equal(bash?.icon, "run");
    const mcp = turn.turn.tools.find((t) => t.id === "x1");
    assert.equal(mcp?.name, "Read");
  });
});

describe("dateGroup", () => {
  it("buckets by calendar day relative to now", () => {
    const now = new Date(2026, 7, 30, 15, 0, 0).getTime();
    const day = 86_400_000;
    assert.equal(dateGroup(now - 3_600_000, now), "Today");
    assert.equal(dateGroup(now - day, now), "Yesterday");
    assert.equal(dateGroup(now - 3 * day, now), "Previous 7 days");
    assert.equal(dateGroup(now - 20 * day, now), "Previous 30 days");
    assert.match(dateGroup(now - 90 * day, now), /2026/);
  });
});

describe("groupSessions / sessionHint", () => {
  it("keeps date buckets consecutive and names an elsewhere origin", () => {
    const now = new Date(2026, 7, 30, 15, 0, 0).getTime();
    const rows = [
      { name: "a", title: "Today one", updatedMs: now, model: "glm-5", provider: null, size: 1, local: true },
      { name: "b", title: "Today two", updatedMs: now - 1_000, model: "kimi", provider: null, size: 1, local: false, origin: "~/notes" },
      { name: "c", title: "Older", updatedMs: now - 3 * 86_400_000, model: "glm-5", provider: null, size: 1, local: true },
    ];
    const groups = groupSessions(rows, now);
    assert.deepEqual(
      groups.map((g) => [g.group, g.items.length]),
      [
        ["Today", 2],
        ["Previous 7 days", 1],
      ],
    );
    assert.equal(sessionHint(rows[0], now), "glm-5 · just now");
    assert.equal(sessionHint(rows[1], now), "~/notes · kimi · just now");
  });
});
