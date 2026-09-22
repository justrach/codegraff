import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

const component = readFileSync(join(import.meta.dir, "../components/primitives/ModelEffortButtons.tsx"), "utf8");
const styles = readFileSync(join(import.meta.dir, "../components/primitives/EffortPicker.module.css"), "utf8");

test("reasoning effort popover keeps the selected compact dimensions", () => {
  expect(component).toContain("const effortPanelWidth = 200;");
  expect(component).toContain("width: effortPanelWidth");
  expect(component).toContain("calc(10px + (100% - 20px)");
  expect(styles).toMatch(/\.slider\s*\{[^}]*height: 20px;[^}]*margin-top: 6px;/s);
  expect(styles).toMatch(/\.range::-webkit-slider-thumb\s*\{[^}]*width: 20px;[^}]*height: 20px;/s);
  expect(styles).toMatch(/\.range::-moz-range-thumb\s*\{[^}]*width: 20px;[^}]*height: 20px;/s);
});
