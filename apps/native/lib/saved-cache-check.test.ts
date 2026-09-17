import { test, expect } from "bun:test";
import { assessSavedCache, checkSavedCache } from "./saved-cache-check";

test("matching saved settings never promise a cache hit", () => {
  const result = assessSavedCache({ model: "demo", workspace: "/work/" }, { model: "demo", cwd: "/work" });
  expect(result.status).toBe("unknown");
  expect(result.summary).toContain("unverified");
  expect(result.reasons).toEqual(["The selected model matches the save.", "The workspace matches the save."]);
  expect(result.next).toContain("Continue will send");
});

test("model and workspace changes flag risk; absent legacy metadata stays unknown", () => {
  expect(assessSavedCache({ model: "old", workspace: "/work" }, { model: "new", cwd: "/work" }).status).toBe("changed");
  expect(assessSavedCache({ model: "demo", workspace: "/old" }, { model: "demo", cwd: "/new" }).status).toBe("changed");
  const legacy = assessSavedCache({ model: null }, {});
  expect(legacy.status).toBe("unknown");
  expect(legacy.reasons).toEqual(["Model comparison unavailable.", "Workspace comparison unavailable."]);
});

test("preflight reads uncached metadata with cancellation and never bootstraps an agent", async () => {
  const original = globalThis.fetch;
  const controller = new AbortController();
  const calls: string[] = [];
  globalThis.fetch = (async (url, options) => {
    calls.push(String(url));
    expect(options?.cache).toBe("no-store");
    expect(options?.signal).toBe(controller.signal);
    const parsed = new URL(String(url), "http://localhost");
    expect(parsed.pathname).toBe("/api/sessions");
    expect(parsed.searchParams.get("view")).toBe("metadata");
    expect(parsed.searchParams.get("name")).toBe("saved");
    expect(parsed.searchParams.get("root")).toBe("/work");
    return Response.json({ model: "demo", workspace: "/work" });
  }) as typeof fetch;
  try {
    expect((await checkSavedCache("saved", { model: "demo", cwd: "/work" }, controller.signal)).status).toBe("unknown");
    expect(calls.length).toBe(1);
    globalThis.fetch = (async () => new Response("missing", { status: 404 })) as typeof fetch;
    await expect(checkSavedCache("saved", {})).rejects.toThrow("Could not read");
  } finally { globalThis.fetch = original; }
});


test("server-resolved workspace identity overrides spelling; unavailable identity is not a mismatch", () => {
  expect(assessSavedCache({ model: "demo", workspace: "/private/tmp/work", cacheWorkspaceMatches: true }, { model: "demo", cwd: "/tmp/work" }).status).toBe("unknown");
  const missing = assessSavedCache({ model: "demo", workspace: "/gone", cacheWorkspaceMatches: null }, { model: "demo", cwd: "/work" });
  expect(missing.status).toBe("unknown");
  expect(missing.reasons).toContain("Workspace comparison unavailable.");
});
