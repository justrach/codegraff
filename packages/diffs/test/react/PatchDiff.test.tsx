import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { PatchDiff } from "../../src/react/PatchDiff";

function makePatch(changedText: string): string {
  return [
    "diff --git a/file.txt b/file.txt",
    "--- a/file.txt",
    "+++ b/file.txt",
    "@@ -1,1 +1,1 @@",
    `-${changedText}`,
    `+${changedText} next`,
  ].join("\n");
}

test("hides very large patches behind an explicit render action", () => {
  const patch = makePatch("x".repeat(200_001));
  const html = renderToStaticMarkup(<PatchDiff patch={patch} />);

  expect(html).toContain("Large diff hidden");
  expect(html).toContain("Render full diff");
  expect(html).not.toContain("cgd-line--addition");
});

test("disables word-level diff spans for large but renderable patches", () => {
  const patch = makePatch("x".repeat(60_001));
  const html = renderToStaticMarkup(<PatchDiff patch={patch} />);

  expect(html).toContain("cgd-line--addition");
  expect(html).not.toContain("cgd-word--added");
  expect(html).not.toContain("cgd-word--removed");
});
