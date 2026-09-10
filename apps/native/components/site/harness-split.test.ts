import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { MAX_COLUMNS, SPLIT_LIMIT_MESSAGE, splitLimitReached } from "./harness-split.ts";

describe("split pane cap", () => {
  it("is four and names the readability limit", () => {
    assert.equal(MAX_COLUMNS, 4);
    assert.equal(splitLimitReached(3), false);
    assert.equal(splitLimitReached(4), true);
    assert.equal(splitLimitReached(5), true);
    assert.match(SPLIT_LIMIT_MESSAGE, /four panes/i);
  });
});
