import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { workingAgentCount } from "./agents.ts";

describe("working agent occupancy", () => {
  it("counts working peers and ignores idle ones", () => {
    assert.equal(workingAgentCount(undefined), 0);
    assert.equal(workingAgentCount([]), 0);
    assert.equal(workingAgentCount([{ status: "waiting" }, { status: "working" }, { status: "working" }]), 2);
  });
});
