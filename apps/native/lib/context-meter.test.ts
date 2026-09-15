import { expect, test } from "bun:test";
import { applyAcpUpdate, emptyTurn } from "./acp";
import { contextRemaining, parseContextMeter } from "./context-meter";

test("the ACP occupancy update drives remaining context, including compaction and over-cap readings", () => {
  let turn = applyAcpUpdate(emptyTurn(), { sessionUpdate: "gui_context_meter", used: 800, window: 1000 });
  expect(contextRemaining(turn.contextMeter)).toBe(20);
  turn = applyAcpUpdate(turn, { sessionUpdate: "gui_context_meter", used: 200, window: 1000 });
  expect(contextRemaining(turn.contextMeter)).toBe(80);
  expect(contextRemaining({ used: 1200, window: 1000 })).toBe(0);
  expect(contextRemaining({ used: 0, window: 1000 })).toBe(100);
});

test("missing or invalid usage cannot imply a full context window", () => {
  for (const value of [undefined, null, {}, {used:-1,window:1000}, {used:0,window:0},
    {used:Infinity,window:1000}, {used:1,window:NaN}, {used:"1",window:1000}]) {
    expect(parseContextMeter(value)).toBeUndefined();
  }
  expect(contextRemaining()).toBeUndefined();
});
