import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  basename,
  findWorkspace,
  loadActiveWorkspace,
  loadWorkspaces,
  monogram,
  removeWorkspace,
  saveActiveWorkspace,
  saveWorkspaces,
  shellQuote,
  upsertWorkspace,
  type Workspace,
} from "./workspaces.ts";

function memoryStorage(seed: Record<string, string> = {}) {
  const map = new Map(Object.entries(seed));
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
    dump: () => Object.fromEntries(map),
  };
}

describe("basename / monogram", () => {
  it("takes the last segment and survives trailing slashes", () => {
    assert.equal(basename("/Users/me/repo"), "repo");
    assert.equal(basename("/Users/me/repo/"), "repo");
    assert.equal(basename("/"), "/");
  });
  it("badges on the first letter or digit", () => {
    assert.equal(monogram("codegraff"), "C");
    assert.equal(monogram(".hidden-thing"), "H");
    assert.equal(monogram("2fast"), "2");
    assert.equal(monogram("   "), "?");
  });
});

describe("upsertWorkspace", () => {
  it("adds a row, defaulting the name to the folder", () => {
    const list = upsertWorkspace([], { path: "/a/b/", name: "  " });
    assert.deepEqual(list, [{ path: "/a/b", name: "b" }]);
  });
  it("updates in place when the path is already listed", () => {
    const one: Workspace[] = [{ path: "/a/b", name: "b" }, { path: "/c", name: "c" }];
    const next = upsertWorkspace(one, { path: "/a/b/", name: "Renamed", model: "grok-4.6", yolo: false });
    assert.equal(next.length, 2);
    assert.deepEqual(next[0], { path: "/a/b", name: "Renamed", model: "grok-4.6", yolo: false });
    assert.equal(next[1].path, "/c");
  });
  it("caps from the oldest end", () => {
    let list: Workspace[] = [];
    for (let i = 0; i < 5; i += 1) list = upsertWorkspace(list, { path: `/w${i}`, name: "" }, 3);
    assert.deepEqual(list.map((w) => w.path), ["/w2", "/w3", "/w4"]);
  });
  it("ignores an empty path", () => {
    assert.deepEqual(upsertWorkspace([{ path: "/x", name: "x" }], { path: "  ", name: "" }), [{ path: "/x", name: "x" }]);
  });
});

describe("remove / find", () => {
  const list: Workspace[] = [{ path: "/a", name: "a" }, { path: "/b", name: "b" }];
  it("removes by normalised path", () => {
    assert.deepEqual(removeWorkspace(list, "/a/"), [{ path: "/b", name: "b" }]);
  });
  it("finds by normalised path and tolerates null", () => {
    assert.equal(findWorkspace(list, "/b/")?.name, "b");
    assert.equal(findWorkspace(list, null), undefined);
    assert.equal(findWorkspace(list, "/zzz"), undefined);
  });
});

describe("storage", () => {
  it("round-trips the list and drops junk rows", () => {
    const store = memoryStorage();
    saveWorkspaces(store, [{ path: "/a", name: "a", yolo: true }]);
    assert.deepEqual(loadWorkspaces(store), [{ path: "/a", name: "a", yolo: true }]);
    const junk = memoryStorage({ "graff.native.workspaces": JSON.stringify([{ nope: 1 }, { path: "/ok", name: "ok" }, { path: "/ok/", name: "dupe" }, 42]) });
    assert.deepEqual(loadWorkspaces(junk), [{ path: "/ok", name: "dupe" }]);
    assert.deepEqual(loadWorkspaces(memoryStorage({ "graff.native.workspaces": "{not json" })), []);
    assert.deepEqual(loadWorkspaces(null), []);
  });
  it("remembers and forgets the active pick", () => {
    const store = memoryStorage();
    saveActiveWorkspace(store, "/a/b/");
    assert.equal(loadActiveWorkspace(store), "/a/b");
    saveActiveWorkspace(store, null);
    assert.equal(loadActiveWorkspace(store), null);
  });
});

describe("shellQuote", () => {
  it("leaves plain paths alone and quotes the rest", () => {
    assert.equal(shellQuote("/Users/me/repo"), "/Users/me/repo");
    assert.equal(shellQuote("/Users/me/my repo"), "'/Users/me/my repo'");
    assert.equal(shellQuote("/it's"), "'/it'\\''s'");
  });
});
