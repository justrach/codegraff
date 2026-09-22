import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { focusAfterClose, rememberActivation } from "./chat-activation.ts";

describe("chat activation history", () => {
  it("records the focused chat without depending on display order", () => {
    assert.deepEqual(rememberActivation([1, 3], 2, [1, 2, 3]), [1, 3, 2]);
    assert.deepEqual(rememberActivation([1, 2, 3], 2, [1, 2, 3]), [1, 3, 2]);
    assert.deepEqual(rememberActivation([1, 9, 3], 2, [1, 2, 3]), [1, 3, 2]);
  });

  it("closing the active chat returns to the most recently used remaining chat", () => {
    assert.equal(focusAfterClose([1, 3, 2], [1, 3], [1, 3], [{ id: 1 }, { id: 3 }]), 3);
    assert.equal(focusAfterClose([1, 3], [1], [1], [{ id: 1 }]), 1);
  });

  it("falls back to visible then remaining position when history is empty", () => {
    assert.equal(focusAfterClose([], [4, 5], [5], [{ id: 4 }, { id: 5 }]), 5);
    assert.equal(focusAfterClose([], [4, 5], [], [{ id: 4 }, { id: 5 }]), 5);
  });
});
