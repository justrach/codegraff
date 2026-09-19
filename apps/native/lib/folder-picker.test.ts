import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  cycleFolderSort,
  DEFAULT_FOLDER_VIEW,
  displayDirPath,
  FOLDER_VIEW_KEY,
  folderNameError,
  formatFolderAge,
  joinDir,
  loadFolderView,
  parseFolderView,
  presentFolderEntries,
  rankFolderEntries,
  sameBrowse,
  sameDir,
  saveFolderView,
  splitFolderQuery,
  uniqueFolderName,
} from "./folder-picker.ts";

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

describe("presentFolderEntries", () => {
  const entries = [
    { name: "zeta", path: "/demo/zeta", git: false, mtime: 400 },
    { name: "alpha", path: "/demo/alpha", git: true, mtime: 100 },
    { name: "beta", path: "/demo/beta", git: true, mtime: 300 },
  ];
  it("sorts by name or newest-modified, and git-only hides the rest", () => {
    assert.deepEqual(
      presentFolderEntries(entries, "", { sort: "name", reverse: false, gitOnly: false }).map((e) => e.name),
      ["alpha", "beta", "zeta"],
    );
    assert.deepEqual(
      presentFolderEntries(entries, "", { sort: "name", reverse: true, gitOnly: false }).map((e) => e.name),
      ["zeta", "beta", "alpha"],
    );
    assert.deepEqual(
      presentFolderEntries(entries, "", { sort: "modified", reverse: false, gitOnly: false }).map((e) => e.name),
      ["zeta", "beta", "alpha"],
    );
    assert.deepEqual(
      presentFolderEntries(entries, "", { sort: "modified", reverse: true, gitOnly: false }).map((e) => e.name),
      ["alpha", "beta", "zeta"],
    );
    assert.deepEqual(
      presentFolderEntries(entries, "", { sort: "name", reverse: false, gitOnly: true }).map((e) => e.name),
      ["alpha", "beta"],
    );
  });
  it("keeps fuzzy rank when a name is typed, still honoring git-only", () => {
    assert.deepEqual(
      presentFolderEntries(entries, "a", { sort: "modified", reverse: false, gitOnly: false }).map((e) => e.name),
      ["alpha", "zeta", "beta"],
    );
    assert.deepEqual(
      presentFolderEntries(entries, "a", { sort: "modified", reverse: false, gitOnly: true }).map((e) => e.name),
      ["alpha", "beta"],
    );
  });
});

describe("cycleFolderSort / folder view persistence", () => {
  it("selects a sort, then reverses on a second click", () => {
    const modified = cycleFolderSort(DEFAULT_FOLDER_VIEW, "modified");
    assert.deepEqual(modified, { sort: "modified", reverse: false, gitOnly: false });
    assert.deepEqual(cycleFolderSort(modified, "modified"), { sort: "modified", reverse: true, gitOnly: false });
    assert.deepEqual(cycleFolderSort(modified, "name"), { sort: "name", reverse: false, gitOnly: false });
  });
  it("loads a saved view and ignores junk", () => {
    const store = new Map<string, string>();
    const storage = {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
    };
    assert.deepEqual(loadFolderView(storage), DEFAULT_FOLDER_VIEW);
    saveFolderView(storage, { sort: "modified", reverse: true, gitOnly: true });
    assert.equal(store.get(FOLDER_VIEW_KEY), JSON.stringify({ sort: "modified", reverse: true, gitOnly: true }));
    assert.deepEqual(loadFolderView(storage), { sort: "modified", reverse: true, gitOnly: true });
    assert.deepEqual(parseFolderView({ sort: "nope", reverse: "yes", gitOnly: 1 }), DEFAULT_FOLDER_VIEW);
    store.set(FOLDER_VIEW_KEY, "{");
    assert.deepEqual(loadFolderView(storage), DEFAULT_FOLDER_VIEW);
  });
});

describe("formatFolderAge", () => {
  const now = Date.parse("2026-04-01T12:00:00Z");
  it("prints a compact age and blanks missing timestamps", () => {
    assert.equal(formatFolderAge(now, now), "now");
    assert.equal(formatFolderAge(now - 12 * 60_000, now), "12m");
    assert.equal(formatFolderAge(now - 3 * 60 * 60_000, now), "3h");
    assert.equal(formatFolderAge(now - 2 * 24 * 60 * 60_000, now), "2d");
    assert.equal(formatFolderAge(now - 3 * 7 * 24 * 60 * 60_000, now), "3w");
    assert.equal(formatFolderAge(now - 5 * 30 * 24 * 60 * 60_000, now), "5mo");
    assert.equal(formatFolderAge(now - 2 * 365 * 24 * 60 * 60_000, now), "2y");
    assert.equal(formatFolderAge(0, now), "");
  });
});

describe("folderNameError / uniqueFolderName", () => {
  it("rejects empty, dot, path, hidden, and overlong names", () => {
    assert.equal(folderNameError("  "), "Name this folder.");
    assert.equal(folderNameError("."), "That name isn't allowed.");
    assert.equal(folderNameError(".."), "That name isn't allowed.");
    assert.equal(folderNameError("a/b"), "A folder name can't contain /.");
    assert.equal(folderNameError("a\\b"), "A folder name can't contain /.");
    assert.equal(folderNameError(".hidden"), "Dot-folders stay hidden in this list.");
    assert.equal(folderNameError("node_modules"), "That name stays hidden in this list.");
    assert.equal(folderNameError("ok"), null);
    assert.equal(folderNameError("  src  "), null);
    assert.equal(folderNameError("x".repeat(256)), "That name is too long.");
  });
  it("adds a number when the default name is taken, case-insensitively", () => {
    assert.equal(uniqueFolderName([]), "untitled folder");
    assert.equal(uniqueFolderName(["untitled folder"]), "untitled folder 2");
    assert.equal(uniqueFolderName(["Untitled Folder", "untitled folder 2"]), "untitled folder 3");
    assert.equal(uniqueFolderName(["alpha"], "alpha"), "alpha 2");
  });
});
