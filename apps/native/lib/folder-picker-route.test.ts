import { test, expect } from "bun:test";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { GET, POST } from "../app/api/workspaces/route";

const create = (body: unknown) => POST(new NextRequest("http://localhost/api/workspaces", {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
}));

test("folder picker creates a directory, lists metadata, and refuses collisions and invalid names", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "folder-picker-route-"));
  try {
    const response = await create({ path: root, name: "new folder" });
    expect(response.status).toBe(200);
    expect((await response.json()).path).toBe(path.join(root, "new folder"));
    await mkdir(path.join(root, "new folder", ".git"));
    const listing = await GET(new NextRequest(`http://localhost/api/workspaces?${new URLSearchParams({ path: root })}`));
    const entry = (await listing.json()).entries[0];
    expect(entry.name).toBe("new folder");
    expect(entry.git).toBe(true);
    expect(entry.mtime).toBeGreaterThan(0);
    expect((await create({ path: root, name: "new folder" })).status).toBe(409);
    for (const name of ["", " ", "..", "../escape", "a/b", "a\\b", ".hidden", "node_modules"]) {
      expect((await create({ path: root, name })).status).toBe(400);
    }
    for (const body of [null, [], "folder"]) expect((await create(body)).status).toBe(400);
  } finally { await rm(root, { recursive: true, force: true }); }
});
