import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { distanceFromTail, isFollowingTail, pinScrollerTail, TAIL_SLACK_PX } from "./follow-scroll.ts";

function box(scrollTop: number, scrollHeight = 1000, clientHeight = 400) {
  return { scrollTop, scrollHeight, clientHeight };
}

describe("follow-scroll", () => {
  it("treats the exact tail as following", () => {
    assert.equal(distanceFromTail(box(600)), 0);
    assert.equal(isFollowingTail(box(600)), true);
  });

  it("lets the reader leave once they scroll past the slack", () => {
    assert.equal(isFollowingTail(box(600 - TAIL_SLACK_PX - 1)), false);
    assert.equal(isFollowingTail(box(600 - TAIL_SLACK_PX)), true);
  });

  it("does not pin when the reader has scrolled away", () => {
    const el = { scrollTop: 10, scrollHeight: 1000, clientHeight: 400 };
    pinScrollerTail(el as HTMLElement, false);
    assert.equal(el.scrollTop, 10);
    pinScrollerTail(el as HTMLElement, true);
    assert.equal(el.scrollTop, 1000);
  });
});
