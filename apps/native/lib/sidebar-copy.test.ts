import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

test("see-all conversations fades with sidebar copy when the rail collapses", () => {
  const src = readFileSync(join(import.meta.dir, "../components/primitives/SidebarNav.tsx"), "utf8");
  const match = src.match(/className="([^"]*)"[\s\S]{0,160}See all \{recentsTotal/);
  expect(match?.[1]).toContain("sidebar-copy");
  expect(match?.[1]).toContain("sidebar-row");
});

test("the account control stays outside the collapsed copy wrapper", () => {
  const src = readFileSync(join(import.meta.dir, "../components/primitives/SidebarNav.tsx"), "utf8");
  const account = src.match(/data-account-control[\s\S]{0,80}/)?.[0] ?? "";
  expect(account).toContain("data-account-control");
  expect(account).toContain("inert={collapsed}");
  expect(account).not.toContain("sidebar-copy");
  expect(src.indexOf("data-account-control")).toBeLessThan(src.indexOf("footerControls ?"));
});
