import { afterEach, expect, test } from "bun:test";
import { armIdle, cancelIdle, forgetPark, forgetParkMatching, idleMs, keepPark, parkCount, parkNow, parkedChats, takeParked } from "./acp-idle";

afterEach(() => {
  forgetPark("idle-test");
  forgetPark("page:1");
  forgetPark("page:2");
  delete process.env.GRAFF_ACP_IDLE_MS;
});

test("idleMs defaults to 0 so an open GUI tab is not parked", () => {
  delete process.env.GRAFF_ACP_IDLE_MS;
  expect(idleMs()).toBe(0);
  process.env.GRAFF_ACP_IDLE_MS = "0";
  expect(idleMs()).toBe(0);
  process.env.GRAFF_ACP_IDLE_MS = "40000";
  expect(idleMs()).toBe(40_000);
});

test("keepPark is only true, never an Array.map index", () => {
  expect(keepPark(true)).toBe(true);
  expect(keepPark(false)).toBe(false);
  expect(keepPark(undefined)).toBe(false);
  expect(keepPark(0)).toBe(false);
  expect(keepPark(1)).toBe(false);
});

test("armIdle parks a snapshot after the quiet period", async () => {
  process.env.GRAFF_ACP_IDLE_MS = "20";
  let killed = 0;
  armIdle("idle-test", { resume: "session-a", model: "mock", cwd: "/tmp", yolo: true, mcp: false }, () => { killed += 1; });
  expect(parkCount()).toBe(0);
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(killed).toBe(1);
  expect(takeParked("idle-test")).toEqual({ resume: "session-a", model: "mock", cwd: "/tmp", yolo: true, mcp: false });
  expect(parkCount()).toBe(0);
});

test("GRAFF_ACP_IDLE_MS=0 never parks", async () => {
  process.env.GRAFF_ACP_IDLE_MS = "0";
  let killed = 0;
  armIdle("idle-test", { resume: "session-z", model: null, cwd: "/tmp", yolo: true, mcp: false }, () => { killed += 1; });
  await new Promise(resolve => setTimeout(resolve, 40));
  expect(killed).toBe(0);
  expect(takeParked("idle-test")).toBeUndefined();
});

test("unset GRAFF_ACP_IDLE_MS never parks an open tab", async () => {
  delete process.env.GRAFF_ACP_IDLE_MS;
  let killed = 0;
  armIdle("idle-test", { resume: "session-open", model: null, cwd: "/tmp", yolo: true, mcp: false }, () => { killed += 1; });
  await new Promise(resolve => setTimeout(resolve, 40));
  expect(killed).toBe(0);
  expect(takeParked("idle-test")).toBeUndefined();
});

test("busy workers are rescheduled instead of parked", async () => {
  process.env.GRAFF_ACP_IDLE_MS = "20";
  let killed = 0;
  let busy = true;
  armIdle("idle-test", { resume: "session-busy", model: null, cwd: "/tmp", yolo: true, mcp: false }, () => { killed += 1; }, () => busy);
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(killed).toBe(0);
  busy = false;
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(killed).toBe(1);
});

test("forgetParkMatching drops a page of parked chats", () => {
  process.env.GRAFF_ACP_IDLE_MS = "0";
  armIdle("page:1", { resume: "a", model: null, cwd: "/tmp", yolo: true, mcp: false }, () => {});
  parkedChats();
  forgetParkMatching("page:");
  expect(takeParked("page:1")).toBeUndefined();
  expect(takeParked("page:2")).toBeUndefined();
});

test("parkNow keeps a dead worker resumable until dispose", () => {
  parkNow("idle-test", { resume: "session-dead", model: "mock", cwd: "/tmp", yolo: true, mcp: false });
  expect(parkCount()).toBe(1);
  expect(takeParked("idle-test")).toEqual({ resume: "session-dead", model: "mock", cwd: "/tmp", yolo: true, mcp: false });
  parkNow("idle-test", { resume: null, model: null, cwd: "/tmp", yolo: true, mcp: false });
  expect(takeParked("idle-test")).toBeUndefined();
});

test("cancelIdle and forgetPark do not kill a live worker", async () => {
  process.env.GRAFF_ACP_IDLE_MS = "20";
  let killed = 0;
  armIdle("idle-test", { resume: "session-b", model: null, cwd: "/tmp", yolo: true, mcp: true }, () => { killed += 1; });
  cancelIdle("idle-test");
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(killed).toBe(0);
  forgetPark("idle-test");
  expect(takeParked("idle-test")).toBeUndefined();
});
