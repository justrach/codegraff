import { test } from "node:test";
import assert from "node:assert/strict";
import { reviewLines } from "./review-lines";

test("new-file metadata is hidden and only added content contributes to counts", () => {
  const rows = reviewLines("diff --git a/new b/new\nnew file mode 100644\nindex 000..123\n--- /dev/null\n+++ b/new\n@@ -0,0 +1,2 @@\n+first\n+++ literal code\n\\ No newline at end of file\n");
  assert.deepEqual(rows, [
    { kind: "hunk", text: "", old: 0, next: 1 },
    { kind: "add", text: "first", next: 1 },
    { kind: "add", text: "++ literal code", next: 2 },
  ]);
});

test("replacement hunks preserve separate old and new line numbers", () => {
  const rows = reviewLines("@@ -10,2 +12,2 @@ function\n unchanged\n-old\n+new\n");
  assert.deepEqual(rows.slice(1), [
    { kind: "context", text: "unchanged", old: 10, next: 12 },
    { kind: "remove", text: "old", old: 11 },
    { kind: "add", text: "new", next: 13 },
  ]);
});
