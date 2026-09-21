import { test, expect } from "bun:test";
import { emptyTurn, applyAcpUpdate, finishAcpTurn } from "./acp";
import { describeTurnError, turnActivity, workDuration } from "./turn-activity";
import { createTurnPainter } from "./turn-painter";
test("a saved snapshot does not claim the turn finished here (#839)", () => {
  const turn = { ...emptyTurn(), status: "done" as const, startedAt: 1000 };
  expect(turnActivity(turn, 2000).label).toBe("Worked for 0s");
  expect(turnActivity(turn, 2000, { snapshot: true }).label).toBe("Saved snapshot");
});
test("commentary followed by silence stays visibly waiting", () => {
  const turn = { ...emptyTurn(), status: "streaming" as const, text: "Preparing the change.", connected: true, startedAt: 1000, lastUpdateAt: 4000, activityKind: "agent_message_chunk" };
  expect(turnActivity(turn, 25000)).toMatchObject({ live: true, label: "Working for 24s", state: "waiting" });
  expect(turnActivity(turn, 25000).detail).toContain("21s");
});
test("active tools remain visible after commentary, with completed details collapsed separately", () => {
  let turn = applyAcpUpdate({ ...emptyTurn(), text: "Preparing the change." }, { sessionUpdate: "tool_call", toolCallId: "fixture", kind: "execute", status: "pending" });
  expect(turnActivity(turn, Date.now()).detail).toBe("Running 1 tool…");
  turn = applyAcpUpdate(turn, { sessionUpdate: "tool_call_update", toolCallId: "fixture", status: "completed" });
  expect(turnActivity(turn, Date.now()).label).toMatch(/^Working for /);
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
  expect(turnActivity(turn,Date.now()).label).toMatch(/^Working for /);
  expect(turnActivity({...turn,lastUpdateAt:1000},25000).detail).not.toContain('stop this turn');
});
test("elapsed work freezes at completion across remounts and repeated finalization", () => {
  const turn = finishAcpTurn({ ...emptyTurn(), startedAt: 1000 }, 560000);
  expect(turnActivity(turn, 900000).label).toBe("Worked for 9m 19s");
  expect(turnActivity(finishAcpTurn(turn, 1800000), 1800000).label).toBe("Worked for 9m 19s");
  expect(workDuration(59)).toBe("59s");
  expect(workDuration(60)).toBe("1m 0s");
  expect(workDuration(3601)).toBe("1h 0m");
});
test("streaming text reports tok/s; tools and MCP Apps wait instead", () => {
  const writing = {
    ...emptyTurn(), status: "streaming" as const, text: "x".repeat(80), connected: true,
    startedAt: 0, lastUpdateAt: 1000, activityKind: "agent_message_chunk",
  };
  expect(turnActivity(writing, 1000).detail).toMatch(/tok\/s/);
  const tools = applyAcpUpdate({ ...writing, text: "x".repeat(80) }, { sessionUpdate: "tool_call", toolCallId: "bash", kind: "execute", status: "in_progress" });
  expect(turnActivity(tools, 1000).detail).toBe("Running 1 tool…");
  expect(turnActivity(tools, 1000).detail).not.toMatch(/tok\/s/);
  const app = { ...tools, tools: [{ ...tools.tools[0], mcpAppId: "a".repeat(32) }] };
  expect(turnActivity(app, 1000).detail).toBe("Waiting on MCP App…");
  const done = finishAcpTurn({ ...writing, startedAt: 0 }, 1000);
  expect(turnActivity(done, 1000).detail).toMatch(/tok\/s/);
});

test("a mid-stream retry notice is live activity, not a failed turn", () => {
  const turn = {
    ...emptyTurn(),
    status: "streaming" as const,
    text: "",
    retryNotice: "provider error mid-response — retrying in 1s (1/3)",
    connected: true,
    startedAt: 1000,
    lastUpdateAt: 2000,
    activityKind: "agent_message_chunk",
  };
  expect(turnActivity(turn, 2000)).toMatchObject({
    live: true,
    state: "working",
    detail: "provider error mid-response — retrying in 1s (1/3)",
  });
});

test("a failed turn names the provider from the harness error and keeps its words as detail", () => {
  expect(describeTurnError("xai api error: Internal error during token parsing")).toEqual({ framing: "xai failed mid-response", message: "Internal error during token parsing" });
  expect(describeTurnError("api error (rate_limit_error): Too many requests", "anthropic")).toEqual({ framing: "anthropic failed mid-response", message: "Too many requests" });
  expect(describeTurnError("api error: quota").framing).toBe("The model provider failed mid-response");
  expect(describeTurnError("graff acp exited with code 1")).toEqual({ framing: "The agent stopped before finishing", message: "graff acp exited with code 1" });
  expect(describeTurnError("Preview inspection failed")).toEqual({ framing: "The request failed", message: "Preview inspection failed" });
  const failed = finishAcpTurn({ ...emptyTurn(), status: "error", error: "xai api error: boom", startedAt: 1000 }, 13000);
  expect(turnActivity(failed, 13000).detail).toMatch(/^After 12s\./);
});
});
