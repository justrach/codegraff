import { test, expect } from "bun:test";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { NextRequest } from "next/server";
import { GET } from "../app/api/inline-reference/route";
import { dispatchInlineReference } from "../components/site/useReferenceNavigation";

async function fixture(run: (root: string, git: (args: string[]) => string) => Promise<void>) {
  const root = await mkdtemp(path.join(os.tmpdir(), "inline-reference-"));
  const git = (args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  try {
    git(["init", "-q"]);
    git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "Fixture"]);
    git(["branch", "release/v1.2.3"]);
    git(["remote", "add", "origin", "git@github.com:example/project.git"]);
    await run(root, git);
  } finally { await rm(root, { recursive: true, force: true }); }
}
const request: typeof fetch = async input => GET(new NextRequest(new URL(String(input), "http://localhost")));

test("inline branch click dispatches through the API to Browser, never Files", async () => {
  await fixture(async root => {
    const files: string[] = [], pages: string[] = [];
    await dispatchInlineReference("release/v1.2.3", root, {
      file: value => { files.push(value); }, browser: async value => { pages.push(value); },
    }, request);
    expect(files).toEqual([]);
    expect(pages).toEqual(["https://github.com/example/project/tree/release/v1.2.3"]);
    await mkdir(path.join(root, "release")); await writeFile(path.join(root, "release/v1.2.3"), "real file");
    await dispatchInlineReference("release/v1.2.3", root, {
      file: value => { files.push(value); }, browser: async value => { pages.push(value); },
    }, request);
    expect(files).toEqual(["release/v1.2.3"]);
    expect(pages).toHaveLength(1);
  });
});

test("remote-only branches resolve; unknown refs and unsupported remotes do not invent URLs", async () => {
  await fixture(async (root, git) => {
    git(["update-ref", "refs/remotes/origin/fix/navigation", "HEAD"]);
    const route = async (target: string) => (await request(`/api/inline-reference?${new URLSearchParams({ root, path: target })}`)).json();
    expect(await route("fix/navigation")).toEqual({ kind: "browser", url: "https://github.com/example/project/tree/fix/navigation" });
    for (const target of ["unknown/path", "release/v1.2.3~1", "--help", "../outside"]) expect((await route(target)).kind).toBe("file");
    git(["remote", "set-url", "origin", "https://example.invalid/project.git"]);
    expect((await route("release/v1.2.3")).kind).toBe("file");
  });
});

test("browser navigation failure surfaces instead of falling back to the files pane", async () => {
  await fixture(async root => {
    const files: string[] = [];
    await expect(dispatchInlineReference("release/v1.2.3", root, {
      file: value => { files.push(value); }, browser: async () => { throw new Error("Browser unavailable"); },
    }, request)).rejects.toThrow("Browser unavailable");
    expect(files).toEqual([]);
  });
});
