import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { displayDirPath, joinDir, rankFolderEntries, sameBrowse, sameDir, splitFolderQuery } from "./folder-picker.ts";

describe("displayDirPath", () => {
  it("adds a single trailing separator and leaves root alone", () => {
    assert.equal(displayDirPath("/Users/example"), "/Users/example/");
    assert.equal(displayDirPath("/Users/example/"), "/Users/example/");
    assert.equal(displayDirPath("/"), "/");
    assert.equal(displayDirPath("~"), "~/");
  });
});

describe("joinDir / sameDir", () => {
  it("never emits a double slash", () => {
    assert.equal(joinDir("/Users/example", "src"), "/Users/example/src");
    assert.equal(joinDir("/Users/example/", "src"), "/Users/example/src");
    assert.equal(joinDir("/", "Users"), "/Users");
    assert.equal(joinDir("/", "/Users"), "/Users");
  });
  it("treats a trailing slash as the same directory", () => {
    assert.equal(sameDir("/Users/example", "/Users/example/"), true);
    assert.equal(sameDir("/", "/"), true);
    assert.equal(sameDir("/a", "/b"), false);
    assert.equal(sameDir("/a", null), false);
  });
  it("treats ~ as the listing home so the picker does not refetch", () => {
    assert.equal(sameBrowse("~", "/Users/example", "/Users/example"), true);
    assert.equal(sameBrowse("~/", "/Users/example/", "/Users/example"), true);
    assert.equal(sameBrowse("~", "/demo", "/Users/example"), false);
    assert.equal(sameBrowse("/Users/example/", "/Users/example", "/Users/example"), true);
  });
});

describe("splitFolderQuery", () => {
  it("keeps a resolved current path as browse, not parent + name", () => {
    assert.deepEqual(splitFolderQuery("/Users/example", "/Users/example"), {
      browse: "/Users/example",
      needle: "",
    });
    assert.deepEqual(splitFolderQuery("/Users/example/", "/Users/example"), {
      browse: "/Users/example",
      needle: "",
    });
  });
  it("splits a partial child off the parent directory", () => {
    assert.deepEqual(splitFolderQuery("/Users/example/cod", "/Users/example"), {
      browse: "/Users/example/",
      needle: "cod",
    });
    assert.deepEqual(splitFolderQuery("codegra", "/Users/example"), {
      browse: null,
      needle: "codegra",
    });
    assert.deepEqual(splitFolderQuery("~/proj"), { browse: "~/", needle: "proj" });
  });
});

describe("rankFolderEntries", () => {
  const entries = [
    { name: "README-notes", path: "/demo/README-notes" },
    { name: "codegraff", path: "/demo/codegraff" },
    { name: "codex-scratch", path: "/demo/codex-scratch" },
    { name: "lib", path: "/demo/lib" },
  ];
  it("keeps directory order when the needle is empty", () => {
    assert.deepEqual(rankFolderEntries(entries, "").map((e) => e.name), [
      "README-notes",
      "codegraff",
      "codex-scratch",
      "lib",
    ]);
  });
  it("ranks the closest folder name first, like /model", () => {
    assert.deepEqual(rankFolderEntries(entries, "code").map((e) => e.name), [
      "codegraff",
      "codex-scratch",
    ]);
    assert.deepEqual(rankFolderEntries(entries, "lib").map((e) => e.name), ["lib"]);
    assert.deepEqual(rankFolderEntries(entries, "zzz"), []);
  });
});
