import { test, expect } from "bun:test";
import { emptyTurn, applyAcpUpdate, finishAcpTurn } from "./acp";
import { turnActivity } from "./turn-activity";
import { createTurnPainter } from "./turn-painter";
test("commentary followed by silence stays visibly waiting", () => {
  const turn = { ...emptyTurn(), status: "streaming" as const, text: "Preparing the change.", connected: true, startedAt: 1000, lastUpdateAt: 4000, activityKind: "agent_message_chunk" };
  expect(turnActivity(turn, 25000)).toMatchObject({ live: true, label: "Waiting for Graff…", state: "waiting" });
  expect(turnActivity(turn, 25000).detail).toContain("21s");
});
test("active tools remain visible after commentary, with completed details collapsed separately", () => {
  let turn = applyAcpUpdate({ ...emptyTurn(), text: "Preparing the change." }, { sessionUpdate: "tool_call", toolCallId: "fixture", kind: "execute", status: "pending" });
  expect(turnActivity(turn, Date.now()).label).toBe("Running 1 tool…");
  turn = applyAcpUpdate(turn, { sessionUpdate: "tool_call_update", toolCallId: "fixture", status: "completed" });
  expect(turnActivity(turn, Date.now()).label).toBe("Waiting for Graff…");
});
test("cancel and stream error settle pending tools without claiming success", () => {
  const pending = applyAcpUpdate(emptyTurn(), { sessionUpdate: "tool_call", toolCallId: "fixture", status: "pending" });
  const stopped = finishAcpTurn(applyAcpUpdate(pending, { sessionUpdate: "gui_turn_end", stopReason: "cancelled" }));
  expect(turnActivity(stopped, Date.now()).label).toBe("Stopped");
  expect(stopped.tools[0].status).toBe("interrupted");
  const failed = finishAcpTurn({ ...pending, status: "error", error: "Disconnected" });
  expect(turnActivity(failed, Date.now())).toMatchObject({ label: "Response interrupted", live: false });
  expect(failed.tools[0].status).toBe("interrupted");
});
test("turn painter commits if animation frames stop, and stale callbacks cannot undo an error", () => {
  const painted: string[] = [], frames: (() => void)[] = [], timers: (() => void)[] = [];
  const painter = createTurnPainter<string>(value => painted.push(value), { frame(callback) { frames.push(callback); return frames.length; }, cancelFrame() {}, delay(callback) { timers.push(callback); return timers.length as unknown as ReturnType<typeof setTimeout>; }, cancelDelay() {} });
  painter.update("first"); painter.update("latest");
  timers[0](); expect(painted).toEqual(["latest"]);
  frames[0](); expect(painted).toEqual(["latest"]);
  painter.update("working"); painter.finish("error");
  frames[1](); timers[1](); painter.update("late");
  expect(painted).toEqual(["latest", "error"]);
});
test("default painter calls browser cancellation APIs without a scheduler receiver", () => {
  const originalFrame = globalThis.requestAnimationFrame, originalCancel = globalThis.cancelAnimationFrame;
  let next: FrameRequestCallback | undefined;
  globalThis.requestAnimationFrame = callback => { next = callback; return 1; };
  globalThis.cancelAnimationFrame = function (this: unknown) {
    if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
  };
  try {
    const painted: string[] = [];
    const painter = createTurnPainter<string>(value => painted.push(value));
    painter.update("working"); next?.(0); painter.finish("done");
    expect(painted).toEqual(["working", "done"]);
  } finally { globalThis.requestAnimationFrame = originalFrame; globalThis.cancelAnimationFrame = originalCancel; }
});
test("parallel completions settle the right rows without a stale running count", () => {
  let turn = emptyTurn();
  for (const id of ['first','second']) turn = applyAcpUpdate(turn,{sessionUpdate:'tool_call',toolCallId:id,title:'read_file',status:'in_progress'});
  turn = applyAcpUpdate(turn,{sessionUpdate:'tool_call_update',toolCallId:'first',status:'completed'});
  expect(turn.tools.map(t=>t.status)).toEqual(['ok','running']);
  turn = applyAcpUpdate(turn,{sessionUpdate:'tool_call_update',toolCallId:'second',status:'completed'});
  expect(turn.tools.map(t=>t.status)).toEqual(['ok','ok']);
  expect(turnActivity(turn,Date.now()).label).toBe('Waiting for Graff…');
  expect(turnActivity({...turn,lastUpdateAt:1000},25000).detail).not.toContain('stop this turn');
});
