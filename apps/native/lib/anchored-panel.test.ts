import { test, expect } from "bun:test";
import { placeAnchoredPanel } from "./anchored-panel";

const panel = { width: 310, height: 420 };

test("sidebar gear opens the panel to the right instead of clipping left", () => {
  const placed = placeAnchoredPanel({ left: 12, right: 44, top: 720, bottom: 752 }, { width: 1440, height: 800 }, panel);
  expect(placed.left).toBeGreaterThanOrEqual(8);
  expect(placed.left + panel.width).toBeLessThanOrEqual(1440 - 8);
  expect(placed.left).toBe(52);
});

test("toolbar gear keeps the panel right-aligned when that still fits", () => {
  const placed = placeAnchoredPanel({ left: 1360, right: 1392, top: 48, bottom: 80 }, { width: 1440, height: 800 }, panel);
  expect(placed.left).toBe(1392 - 310);
  expect(placed.left + panel.width).toBeLessThanOrEqual(1440 - 8);
});

test("a narrow window clamps the panel inside the viewport", () => {
  const placed = placeAnchoredPanel({ left: 4, right: 36, top: 40, bottom: 72 }, { width: 320, height: 500 }, panel);
  expect(placed.left).toBeGreaterThanOrEqual(8);
  expect(placed.left + Math.min(panel.width, 320 - 16)).toBeLessThanOrEqual(320 - 8);
});
