import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { DIFF_CHIP_CAP, diffChipLabels, fileBase, meaningfulDiffStat, shortPath } from "./diff-chip-label.ts";

const prefix = "codegraff/.worktrees/desktop-task-workspaces/gui/src/";

describe("diff chip labels", () => {
  it("uses the basename, not the worktree prefix", () => {
    assert.equal(fileBase(prefix + "styles/core.css"), "core.css");
    assert.deepEqual(diffChipLabels([prefix + "styles/core.css", prefix + "lib.rs"]), ["core.css", "lib.rs"]);
  });

  it("keeps the parent when basenames collide", () => {
    const files = [prefix + "dto/mod.rs", prefix + "runtime/mod.rs", prefix + "app/mod.rs"];
    assert.deepEqual(diffChipLabels(files), ["dto/mod.rs", "runtime/mod.rs", "app/mod.rs"]);
    assert.equal(shortPath(files[1], files), "runtime/mod.rs");
  });

  it("treats the placeholder +1 −1 as not a measured stat", () => {
    assert.equal(meaningfulDiffStat(1, 1), false);
    assert.equal(meaningfulDiffStat(1, 0), false);
    assert.equal(meaningfulDiffStat(13, 0), true);
    assert.equal(meaningfulDiffStat(2, 4), true);
    assert.equal(DIFF_CHIP_CAP, 3);
  });
});
