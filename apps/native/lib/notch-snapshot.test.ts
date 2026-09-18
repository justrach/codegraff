import { expect, test } from "bun:test";
import { emptyTurn } from "./acp";
import { NOTCH_CELL_LIMIT, notchCell, notchSnapshot } from "./notch-snapshot";

test("an empty workspace still has one idle cell so the notch is findable", () => {
  expect(notchSnapshot([], new Set(), 0)).toEqual([
    { id: 0, title: "Codegraff", state: "idle", label: "Idle", detail: "" },
  ]);
});

test("ask and stalled live turns both read as waiting", () => {
  const ask = { id: 1, title: "Review", messages: [{ role: "assistant", turn: { ...emptyTurn(), status: "ask" as const } }] };
  expect(notchCell(ask, false, 0).state).toBe("waiting");
  const stalled = {
    id: 2,
    title: "Build",
    messages: [{
      role: "assistant",
      turn: { ...emptyTurn(), status: "streaming" as const, connected: true, startedAt: 1000, lastUpdateAt: 4000 },
    }],
  };
  expect(notchCell(stalled, false, 25000)).toMatchObject({ state: "waiting", label: expect.stringMatching(/^Working for /) });
});

test("a running turn beats idle siblings and errors stay visible", () => {
  const chats = [
    { id: 3, title: "Done", messages: [{ role: "assistant", turn: { ...emptyTurn(), status: "done" as const, startedAt: 1, endedAt: 2 } }] },
    { id: 1, title: "Live", messages: [{ role: "assistant", turn: { ...emptyTurn(), status: "thinking" as const, connected: true, startedAt: 1, lastUpdateAt: 2 } }] },
    { id: 2, title: "Broke", messages: [{ role: "assistant", turn: { ...emptyTurn(), status: "error" as const, startedAt: 1 } }] },
  ];
  expect(notchSnapshot(chats, new Set(), 3).map((cell) => cell.id)).toEqual([1, 2, 3]);
  expect(notchSnapshot(chats, new Set(), 3).map((cell) => cell.state)).toEqual(["working", "error", "idle"]);
});

test("busy without a turn is starting, and untitled chats keep a stable name", () => {
  expect(notchCell({ id: 4, title: null, messages: [] }, true, 0)).toMatchObject({
    title: "Chat 4",
    state: "working",
    label: "Starting…",
  });
});

test("the notch keeps at most six cells, live first", () => {
  const chats = Array.from({ length: 8 }, (_, i) => ({
    id: i + 1,
    title: `Chat ${i + 1}`,
    messages: i === 7
      ? [{ role: "assistant" as const, turn: { ...emptyTurn(), status: "thinking" as const, connected: true, startedAt: 1, lastUpdateAt: 1 } }]
      : [],
  }));
  const cells = notchSnapshot(chats, new Set(), 2);
  expect(cells).toHaveLength(NOTCH_CELL_LIMIT);
  expect(cells[0]).toMatchObject({ id: 8, state: "working" });
});

test("long titles are clipped so the hover card stays a label", () => {
  const title = "x".repeat(120);
  expect(notchCell({ id: 1, title, messages: [] }, false, 0).title.length).toBeLessThanOrEqual(80);
  expect(notchCell({ id: 1, title, messages: [] }, false, 0).title.endsWith("…")).toBe(true);
});
