import { describe, expect, test } from "bun:test";

import { parsePatch, getPatchStats } from "../src/parse";
import { tokenizeLine, languageFromPath } from "../src/highlight";
import { diffWords } from "../src/wordDiff";

const SIMPLE = `diff --git a/src/foo.ts b/src/foo.ts
index 1111111..2222222 100644
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -1,3 +1,3 @@
 const a = 1;
-const b = 2;
+const b = 3;
 const c = 4;
`;

const NEW_FILE = `diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+hello
+world
`;

const TWO_FILES = `diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1,1 +1,2 @@
 x
+y
diff --git a/b.ts b/b.ts
--- a/b.ts
+++ b/b.ts
@@ -1,2 +1,1 @@
 m
-n
`;

describe("parsePatch", () => {
  test("parses a single-file modification with correct line numbers", () => {
    const parsed = parsePatch(SIMPLE);
    expect(parsed.files).toHaveLength(1);
    const file = parsed.files[0]!;
    expect(file.path).toBe("src/foo.ts");
    expect(file.stats).toEqual({ additions: 1, deletions: 1 });

    const lines = file.hunks[0]!.lines;
    expect(lines.map((l) => l.kind)).toEqual([
      "context",
      "deletion",
      "addition",
      "context",
    ]);
    // Context line keeps both numbers; deletion only "before", addition only "after".
    expect(lines[0]).toMatchObject({ beforeLineNumber: 1, afterLineNumber: 1 });
    expect(lines[1]).toMatchObject({ beforeLineNumber: 2, afterLineNumber: null });
    expect(lines[2]).toMatchObject({ beforeLineNumber: null, afterLineNumber: 2 });
    expect(lines[3]).toMatchObject({ beforeLineNumber: 3, afterLineNumber: 3 });
  });

  test("detects new files", () => {
    const file = parsePatch(NEW_FILE).files[0]!;
    expect(file.isNew).toBe(true);
    expect(file.path).toBe("new.txt");
    expect(file.stats).toEqual({ additions: 2, deletions: 0 });
  });

  test("parses multiple files and aggregates stats", () => {
    const parsed = parsePatch(TWO_FILES);
    expect(parsed.files.map((f) => f.path)).toEqual(["a.ts", "b.ts"]);
    expect(parsed.stats).toEqual({ additions: 1, deletions: 1 });
  });

  test("getPatchStats returns null for non-git input", () => {
    expect(getPatchStats("just some text")).toBeNull();
    expect(getPatchStats(SIMPLE)).toEqual({ additions: 1, deletions: 1 });
  });

  test("does not treat a `-- ` deletion inside a hunk as a `--- ` file header", () => {
    // A deleted SQL/Lua `-- comment` is emitted by git as the raw line
    // `--- FIXME: drop this` (marker `-` + text `-- FIXME: drop this`).
    // It must be parsed as a deletion, not swallowed as an old-file header.
    const PATCH = `diff --git a/app.lua b/app.lua
--- a/app.lua
+++ b/app.lua
@@ -1,2 +1,1 @@
--- FIXME: drop this
 local x = 1
`;
    const file = parsePatch(PATCH).files[0]!;
    expect(file.path).toBe("app.lua");
    expect(file.stats).toEqual({ additions: 0, deletions: 1 });
    const lines = file.hunks[0]!.lines;
    expect(lines.map((l) => l.kind)).toEqual(["deletion", "context"]);
    expect(lines[0]).toMatchObject({
      kind: "deletion",
      beforeLineNumber: 1,
      afterLineNumber: null,
      text: "-- FIXME: drop this",
    });
  });

  test("does not treat an `++ ` addition inside a hunk as a `+++ ` file header", () => {
    const PATCH = `diff --git a/app.txt b/app.txt
--- a/app.txt
+++ b/app.txt
@@ -1,1 +1,2 @@
 keep
+++ incremented
`;
    const file = parsePatch(PATCH).files[0]!;
    expect(file.path).toBe("app.txt");
    expect(file.stats).toEqual({ additions: 1, deletions: 0 });
    const lines = file.hunks[0]!.lines;
    expect(lines.map((l) => l.kind)).toEqual(["context", "addition"]);
    expect(lines[1]).toMatchObject({
      kind: "addition",
      beforeLineNumber: null,
      afterLineNumber: 2,
      text: "++ incremented",
    });
  });
});

describe("tokenizeLine", () => {
  test("colors keywords, strings and comments in TS", () => {
    const lang = languageFromPath("foo.ts");
    expect(lang).toBe("ts");
    const tokens = tokenizeLine('const name = "joe"; // hi', lang);
    const byType = (type: string) => tokens.filter((t) => t.type === type).map((t) => t.value);
    expect(byType("keyword")).toContain("const");
    expect(byType("string")).toContain('"joe"');
    expect(byType("comment")).toContain("// hi");
  });

  test("plain language returns a single plain token", () => {
    expect(tokenizeLine("anything here", "plain")).toEqual([
      { type: "plain", value: "anything here" },
    ]);
  });
});

describe("diffWords", () => {
  test("marks only the changed word", () => {
    const { before, after } = diffWords("const b = 2;", "const b = 3;");
    expect(before.filter((s) => s.kind === "removed").map((s) => s.value)).toEqual(["2"]);
    expect(after.filter((s) => s.kind === "added").map((s) => s.value)).toEqual(["3"]);
    // Shared prefix preserved.
    expect(before.find((s) => s.kind === "same")?.value).toContain("const");
  });
});
