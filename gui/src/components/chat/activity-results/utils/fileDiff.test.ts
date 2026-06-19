import { describe, expect, test } from "bun:test";

import { getPatchStats } from "@codegraff/diffs";

import { buildRenderableFileDiffPatch } from "./fileDiff";

describe("fileDiff", () => {
  test("converts excerpt-style file diffs into unified git patches", () => {
    const patch = buildRenderableFileDiffPatch(
      "src/example.ts",
      ["1 1 | const before = true;", "2   |-removed();", "  2 |+added();"].join(
        "\n",
      ),
    );

    expect(patch).toContain("diff --git a/src/example.ts b/src/example.ts");
    expect(patch).toContain("@@ -1,2 +1,2 @@");
    expect(patch).toContain(" const before = true;");
    expect(patch).toContain("-removed();");
    expect(patch).toContain("+added();");
    expect(getPatchStats(patch)).toEqual({ additions: 1, deletions: 1 });
  });

  test("keeps surrounding edits when an excerpt contains an unparseable gap line", () => {
    // The harness inserts gap/ellipsis markers between non-contiguous regions; one
    // such line must not hide every real edit (regression: greet.ts rendered "File
    // updated" instead of its changes).
    const patch = buildRenderableFileDiffPatch(
      "src/example.ts",
      [
        "1 1 | const before = true;",
        "        ...",
        "5   |-removed();",
        "  5 |+added();",
      ].join("\n"),
    );

    expect(patch).toContain("diff --git a/src/example.ts b/src/example.ts");
    expect(patch).toContain(" const before = true;");
    expect(patch).toContain("-removed();");
    expect(patch).toContain("+added();");
  });

  test("splits non-contiguous edit regions into separate hunks", () => {
    const patch = buildRenderableFileDiffPatch(
      "src/example.ts",
      [
        "1 1 | first();",
        "2   |-old();",
        "  2 |+new();",
        "10 10 | tenth();",
        "11    |-gone();",
      ].join("\n"),
    );

    const hunkHeaders = patch
      .split("\n")
      .filter((line) => line.startsWith("@@"));
    expect(hunkHeaders).toHaveLength(2);
    // Each hunk starts at its own region's line numbers, not a single renumbered run.
    expect(hunkHeaders[0]).toContain("-1,");
    expect(hunkHeaders[1]).toContain("-10,");
  });

  test("leaves a byte-summary untouched so it routes to the placeholder path", () => {
    const summary = "wrote 42 bytes to config.json";
    expect(buildRenderableFileDiffPatch("config.json", summary)).toBe(summary);
    expect(getPatchStats(summary)).toBeNull();
  });

  test("keeps existing unified patches unchanged", () => {
    const patch = [
      "diff --git a/src/example.ts b/src/example.ts",
      "--- a/src/example.ts",
      "+++ b/src/example.ts",
      "@@ -1,1 +1,1 @@",
      "-old();",
      "+next();",
    ].join("\n");

    expect(buildRenderableFileDiffPatch("src/example.ts", patch)).toBe(patch);
    expect(getPatchStats(patch)).toEqual({ additions: 1, deletions: 1 });
  });
});
