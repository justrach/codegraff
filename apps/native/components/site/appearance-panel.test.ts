import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  APPEARANCE_PANEL_WIDTH,
  VIEWPORT_MARGIN,
  appearancePanelPosition,
} from "./appearance-panel.ts";

const sidebarGear = { left: 220, right: 252, top: 740, bottom: 772 };
const desktop = { width: 1280, height: 800 };

function fullyOnScreen(box: { top: number; left: number; width: number }, viewport = desktop, height = 420) {
  assert.ok(box.left >= VIEWPORT_MARGIN, `left ${box.left} clips the left edge`);
  assert.ok(box.left + box.width <= viewport.width - VIEWPORT_MARGIN, `right ${box.left + box.width} clips the right edge`);
  assert.ok(box.top >= VIEWPORT_MARGIN, `top ${box.top} clips the top edge`);
  assert.ok(box.top + Math.min(height, viewport.height) <= viewport.height || box.top <= viewport.height - VIEWPORT_MARGIN);
}

describe("appearance panel position", () => {
  it("opens to the right of a left-sidebar gear instead of hanging off the left", () => {
    const box = appearancePanelPosition(sidebarGear, desktop);
    fullyOnScreen(box);
    assert.equal(box.width, APPEARANCE_PANEL_WIDTH);
    assert.ok(box.left >= sidebarGear.right, "panel should sit to the trigger's right");
    // The old `right: innerWidth - trigger.right` placement put the left edge at
    // trigger.right - 310 = -58.
    assert.ok(box.left > 0);
  });

  it("opens to the left of a right-edge trigger instead of overflowing", () => {
    const trigger = { left: 1240, right: 1272, top: 740, bottom: 772 };
    const box = appearancePanelPosition(trigger, desktop);
    fullyOnScreen(box);
    assert.ok(box.left + box.width <= trigger.left, "panel should sit to the trigger's left when the right side has no room");
  });

  it("shrinks to the viewport on a narrow window", () => {
    const viewport = { width: 280, height: 500 };
    const trigger = { left: 12, right: 44, top: 400, bottom: 432 };
    const box = appearancePanelPosition(trigger, viewport);
    assert.equal(box.width, viewport.width - VIEWPORT_MARGIN * 2);
    assert.equal(box.left, VIEWPORT_MARGIN);
    fullyOnScreen(box, viewport, 420);
  });

  it("does not place the panel above the titlebar when there is room below", () => {
    const trigger = { left: 220, right: 252, top: 80, bottom: 112 };
    const box = appearancePanelPosition(trigger, desktop);
    assert.ok(box.top >= 48);
    fullyOnScreen(box);
  });
});
