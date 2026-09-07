import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { fuzzyScore, fuzzySubseq } from "./fuzzy.ts";

describe("fuzzySubseq", () => {
  it("matches across punctuation gaps", () => {
    assert.equal(fuzzySubseq("gpt-5.5", "gpt5.5"), true);
    assert.equal(fuzzySubseq("claude-opus-4-8", "opus"), true);
    assert.equal(fuzzySubseq("anything", ""), true);
    assert.equal(fuzzySubseq("gpt-5.5", "xyz"), false);
    assert.equal(fuzzySubseq("abc", "abcd"), false);
  });
});

describe("fuzzyScore", () => {
  it("ranks basename prefix above substring above subsequence", () => {
    const demo = fuzzyScore("sdk/py/demo.py", "dem");
    const readme = fuzzyScore("README.md", "dem");
    assert.ok(demo != null && readme != null && demo > readme);
    const sub = fuzzyScore(".graff/traces/run.jsonl", "trace");
    const seq = fuzzyScore("t-r-a-c-e.txt", "trace");
    assert.ok(sub != null && seq != null && sub > seq);
    const basePre = fuzzyScore("src/main.zig", "main");
    const mid = fuzzyScore("domain.zig", "main");
    assert.ok(basePre != null && mid != null && basePre > mid);
    assert.ok((fuzzyScore("sdk/ts/harness.ts", "sdk") ?? 0) >= 300_000 - 200);
    assert.ok((fuzzyScore("gpt-5.6-sol", "5.6 sol") ?? 0) > (fuzzyScore("gpt-5.6", "5.6") ?? 0));
    assert.equal(fuzzyScore("abc", "xyz"), null);
    assert.equal(fuzzyScore("abc", ""), 0);
  });
});
