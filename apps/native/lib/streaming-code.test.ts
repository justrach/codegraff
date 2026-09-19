import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import assert from "node:assert/strict";

describe("streaming code overflow", () => {
  it("puts horizontal overflow on the constrained open-fence body", () => {
    const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../components/primitives/StreamingCode.tsx"), "utf8");
    const body = src.match(/data-streamdown="code-block-body"[\s\S]*?className=\{`([^`]+)`\}/)?.[1] ?? "";
    assert.match(body, /min-w-0/);
    assert.match(body, /max-w-full/);
    assert.match(body, /overflow-x-auto/);
    assert.doesNotMatch(src, /sticky top-2 z-10 -mt-10/);
  });
});
