import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { childElapsed, composerChildren, workingAgentCount } from "./agents.ts";

describe("working agent occupancy", () => {
  it("counts working peers and ignores idle ones", () => {
    assert.equal(workingAgentCount(undefined), 0);
    assert.equal(workingAgentCount([]), 0);
    assert.equal(workingAgentCount([{ status: "waiting" }, { status: "working" }, { status: "working" }]), 2);
  });
});

describe("composer subagent chips", () => {
  it("hides completed children and keeps failed ones", () => {
    assert.deepEqual(composerChildren([
      { id: "a", label: "Scout", task: "read", status: "working", updatedAt: 1, truncated: false },
      { id: "b", label: "Done", task: "write", status: "completed", updatedAt: 1, truncated: false },
      { id: "c", label: "Broke", task: "run", status: "failed", updatedAt: 1, truncated: false },
    ]).map(child => child.id), ["a", "c"]);
  });
  it("formats elapsed the way the dock prints it", () => {
    assert.equal(childElapsed(0, 45_000), "45s");
    assert.equal(childElapsed(0, 90_000), "1m 30s");
    assert.equal(childElapsed(0, 5_427_000), "1h 30m 27s");
  });
});
