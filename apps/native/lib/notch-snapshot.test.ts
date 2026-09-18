import { expect, test } from "bun:test";
import { emptyTurn } from "./acp";
import { NOTCH_ACTIVITY_LIMIT, agentCells, notchCell, notchSnapshot, usageCell } from "./notch-snapshot";

test("an empty workspace still has one idle cell so the notch is findable", () => {
  expect(notchSnapshot([], new Set(), 0)).toEqual([
    { id: 0, title: "Codegraff", caption: "idle", state: "idle", label: "Idle", detail: "", kind: "session" },
  ]);
});

test("ask and stalled live turns both read as waiting", () => {
  const ask = { id: 1, title: "Review", messages: [{ role: "assistant", turn: { ...emptyTurn(), status: "ask" as const } }] };
  expect(notchCell(ask, false, 0)).toMatchObject({ state: "waiting", caption: "ask" });
  const stalled = {
    id: 2,
    title: "Build",
    messages: [{
      role: "assistant",
      turn: { ...emptyTurn(), status: "streaming" as const, connected: true, startedAt: 1000, lastUpdateAt: 4000 },
    }],
  };
  expect(notchCell(stalled, false, 25000)).toMatchObject({ state: "waiting", caption: "ask", label: expect.stringMatching(/^Working for /) });
});

test("idle chats leave the notch; live work and errors stay", () => {
  const chats = [
    { id: 3, title: "Starting a casual conversation", messages: [{ role: "assistant", turn: { ...emptyTurn(), status: "done" as const, startedAt: 1, endedAt: 2 } }] },
    { id: 1, title: "Live", messages: [{ role: "assistant", turn: { ...emptyTurn(), status: "thinking" as const, connected: true, startedAt: 1, lastUpdateAt: 2, activityKind: "agent_thought_chunk" as const } }] },
    { id: 2, title: "Broke", messages: [{ role: "assistant", turn: { ...emptyTurn(), status: "error" as const, startedAt: 1 } }] },
  ];
  expect(notchSnapshot(chats, new Set(), 3).map((cell) => cell.id)).toEqual([1, 2]);
  expect(notchSnapshot(chats, new Set(), 3).map((cell) => cell.caption)).toEqual(["think", "err"]);
});

test("busy without a turn is starting only when nobody has spoken", () => {
  expect(notchCell({ id: 4, title: null, messages: [] }, true, 0)).toMatchObject({
    title: "Chat 4",
    caption: "work",
    state: "working",
    label: "Starting…",
  });
  expect(notchCell({
    id: 5,
    title: "Starting a casual conversation",
    messages: [{ role: "user", text: "hey there" }],
  }, true, 0)).toMatchObject({ caption: "work", label: "Working" });
});

test("a running tool caption is the tool, not the chat title", () => {
  const chat = {
    id: 8,
    title: "Starting a casual conversation",
    messages: [{
      role: "assistant" as const,
      turn: {
        ...emptyTurn(),
        status: "streaming" as const,
        connected: true,
        startedAt: 1,
        lastUpdateAt: 2,
        tools: [{ id: "1", name: "bash", icon: "run" as const, chip: "bash", status: "running" as const, detail: [] }],
      },
    }],
  };
  expect(notchCell(chat, true, 3)).toMatchObject({ caption: "bash", state: "working" });
});

test("the notch keeps at most four live chats, then usage", () => {
  const chats = Array.from({ length: 8 }, (_, i) => ({
    id: i + 1,
    title: `Chat ${i + 1}`,
    messages: [{ role: "assistant" as const, turn: { ...emptyTurn(), status: "thinking" as const, connected: true, startedAt: 1, lastUpdateAt: 1 } }],
  }));
  const usage = [usageCell("codex", "Codex", 42, "5h"), usageCell("grok", "Grok", 11, "3h")];
  const cells = notchSnapshot(chats, new Set(), 2, [], usage);
  expect(cells).toHaveLength(NOTCH_ACTIVITY_LIMIT + 2);
  expect(cells.slice(0, NOTCH_ACTIVITY_LIMIT).every((cell) => cell.kind === "session")).toBe(true);
  expect(cells.slice(NOTCH_ACTIVITY_LIMIT).map((cell) => cell.caption)).toEqual(["42%", "11%"]);
});

test("working ACP agents share the notch; idle ones do not", () => {
  const cells = agentCells([
    { session: "native-a", pid: 1, title: "Fix notch", task: "running bash", status: "working", workspace: "/tmp" },
    { session: "native-b", pid: 2, title: "Idle", task: "", status: "idle" },
  ]);
  expect(cells).toHaveLength(1);
  expect(cells[0]).toMatchObject({ caption: "running", state: "working", kind: "agent" });
});

test("long titles are clipped so the hover card stays a label", () => {
  const title = "x".repeat(120);
  expect(notchCell({ id: 1, title, messages: [] }, false, 0).title.length).toBeLessThanOrEqual(80);
  expect(notchCell({ id: 1, title, messages: [] }, false, 0).title.endsWith("…")).toBe(true);
});
