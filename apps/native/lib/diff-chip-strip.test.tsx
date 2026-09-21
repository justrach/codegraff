import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import ToolChips from "../components/primitives/ToolChips";

const prefix = "codegraff/.worktrees/desktop-task-workspaces/gui/src/";
const files = ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts", "g.ts", "h.ts"];

test("a long edit list stays a few short chips, not a path wall", () => {
  const html = renderToStaticMarkup(
    <ToolChips
      rows={[]}
      diffs={files.map((file) => ({ file: prefix + file, add: 1, del: 1 }))}
    />,
  );
  expect(html.match(/data-diffchip/g)?.length).toBe(3);
  expect(html).toContain("data-diff-more");
  expect(html).toContain("+5");
  expect(html).toContain(">a.ts</span>");
  expect(html).not.toContain(`>${prefix}`);
  expect(html).not.toContain("data-diff-stat");
});

test("a handful of files still shows a measured count", () => {
  const html = renderToStaticMarkup(
    <ToolChips rows={[]} diffs={[{ file: "flavors.css", add: 13, del: 0 }]} />,
  );
  expect(html.match(/data-diffchip/g)?.length).toBe(1);
  expect(html).not.toContain("data-diff-more");
  expect(html).toContain("data-diff-stat");
  expect(html).toContain("+13");
});

