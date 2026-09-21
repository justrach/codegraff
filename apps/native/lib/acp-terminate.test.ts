import { expect, test } from "bun:test";
import { formatTermination, recentTerminations, recordTermination, resetTerminationsForTest, shouldReapPage } from "./acp-terminate";

test("every slot termination records the lifecycle reason and turn state", () => {
  resetTerminationsForTest();
  const entry = recordTermination({
    chat: "page:1",
    reason: "idle-park",
    turnActive: false,
    childAgeMs: 3_635_785,
    signal: "SIGTERM",
  });
  expect(recentTerminations()).toEqual([entry]);
  expect(formatTermination(entry)).toContain("reason=idle-park");
  expect(formatTermination(entry)).toContain("turnActive=false");
  expect(formatTermination(entry)).toContain("ageMs=3635785");
});

test("bfcache pagehide does not reap a live page", () => {
  expect(shouldReapPage({ persisted: true })).toBe(false);
  expect(shouldReapPage({ persisted: false })).toBe(true);
  expect(shouldReapPage({})).toBe(true);
});

test("pagehide must not be recorded as an idle park of an active turn", () => {
  resetTerminationsForTest();
  recordTermination({ chat: "page:2", reason: "dispose-page", turnActive: true, childAgeMs: 3_600_000, signal: "EOF" });
  expect(recentTerminations()[0]?.reason).toBe("dispose-page");
  expect(recentTerminations()[0]?.turnActive).toBe(true);
});
