import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

test("see-all conversations fades with sidebar copy when the rail collapses", () => {
  const src = readFileSync(join(import.meta.dir, "../components/primitives/SidebarNav.tsx"), "utf8");
  const match = src.match(/className="([^"]*)"[\s\S]{0,160}See all \{recentsTotal/);
  expect(match?.[1]).toContain("sidebar-copy");
  expect(match?.[1]).toContain("sidebar-row");
});
