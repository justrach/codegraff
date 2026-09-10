import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { deferredFocusStillActive } from "./deferred-focus.ts";

describe("deferred shortcut focus (#842)", () => {
  it("applies only while the captured chat is still active", () => {
    assert.equal(deferredFocusStillActive(2, 2), true);
    assert.equal(deferredFocusStillActive(3, 2), false);
  });
});
