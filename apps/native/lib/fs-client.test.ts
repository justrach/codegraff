import { test } from "node:test";
import assert from "node:assert/strict";
import { fsOpen, fsReveal } from "./fs-client.ts";

async function withFetch(fetcher: typeof fetch, check: () => Promise<void>) {
  const original = globalThis.fetch;
  globalThis.fetch = fetcher;
  try { await check(); } finally { globalThis.fetch = original; }
}

test("file actions preserve their path and workspace and accept an empty success body", async () => {
  const requests: unknown[] = [];
  await withFetch(async (url, options) => {
    requests.push({ url, method: options?.method, body: JSON.parse(String(options?.body)) });
    return new Response(null, { status: 204 });
  }, async () => { await fsOpen("notes.md", "/demo/one"); await fsReveal("src", "/demo/two"); });
  assert.deepEqual(requests, [
    { url: "/api/fs", method: "POST", body: { action: "open", path: "notes.md", root: "/demo/one" } },
    { url: "/api/fs", method: "POST", body: { action: "reveal", path: "src", root: "/demo/two" } },
  ]);
});

test("file actions reject HTTP failures with the server explanation", async () => {
  await withFetch(async () => new Response(JSON.stringify({ error: "No application can open this file" }), { status: 503 }), async () => {
    await assert.rejects(fsOpen("notes.md"), /No application can open this file/);
  });
});

test("file actions report non-JSON HTTP failures and network failures", async () => {
  await withFetch(async () => new Response("Unavailable", { status: 502 }), async () => {
    await assert.rejects(fsReveal("src"), /Could not reveal this item \(502\)/);
  });
  await withFetch(async () => { throw new Error("Connection lost"); }, async () => {
    await assert.rejects(fsOpen("notes.md"), /Connection lost/);
  });
});
