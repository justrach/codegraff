import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { GET, POST } from "../app/api/account/route";
import { credentialPath, writeApiKey } from "./codegraff-login";

const temps: string[] = [];
const posts: Array<{ url: string; body: unknown }> = [];
const originalFetch = globalThis.fetch;
const originalHome = process.env.CODEGRAFF_HOME;
const originalBase = process.env.CODEGRAFF_DEVICE_BASE;

function isolate() {
  const dir = mkdtempSync(path.join(os.tmpdir(), "graff-account-"));
  temps.push(dir);
  process.env.CODEGRAFF_HOME = dir;
  process.env.CODEGRAFF_DEVICE_BASE = "https://gateway.test";
  return dir;
}

afterEach(() => {
  globalThis.fetch = originalFetch;
  if (originalHome === undefined) delete process.env.CODEGRAFF_HOME;
  else process.env.CODEGRAFF_HOME = originalHome;
  if (originalBase === undefined) delete process.env.CODEGRAFF_DEVICE_BASE;
  else process.env.CODEGRAFF_DEVICE_BASE = originalBase;
  posts.length = 0;
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function call(action: string, extra: Record<string, string> = {}) {
  return POST(new NextRequest("http://localhost/api/account", {
    method: "POST",
    body: JSON.stringify({ action, ...extra }),
  }));
}

test("GET reports signed-out status without a key file", async () => {
  isolate();
  const res = await GET();
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ signedIn: false, plan: null, provider: null });
});

test("start and poll store the key without returning it", async () => {
  const dir = isolate();
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    posts.push({ url, body });
    if (url.endsWith("/v1/device/start")) {
      return new Response(JSON.stringify({
        device_code: "dev-ui",
        user_code: "UI-CODE",
        verification_uri: "https://codegraff.com/cli/auth",
        interval: 2,
      }), { status: 200 });
    }
    return new Response(JSON.stringify({ status: "ok", api_key: "cg_sk_hidden" }), { status: 200 });
  }) as typeof fetch;

  const start = await call("start");
  expect(start.status).toBe(200);
  const started = await start.json() as { device_code: string; user_code: string; api_key?: string };
  expect(started.device_code).toBe("dev-ui");
  expect(started.user_code).toBe("UI-CODE");
  expect(started.api_key).toBeUndefined();

  const poll = await call("poll", { device_code: "dev-ui" });
  expect(poll.status).toBe(200);
  const polled = await poll.json();
  expect(polled).toEqual({ status: "ok" });
  expect(JSON.stringify(polled)).not.toContain("cg_sk_");
  expect(readFileSync(credentialPath(dir), "utf8")).toContain("cg_sk_hidden");
  expect(posts.map(item => item.url)).toEqual([
    "https://gateway.test/v1/device/start",
    "https://gateway.test/v1/device/poll",
  ]);

  const status = await (await GET()).json();
  expect(status).toEqual({ signedIn: true, plan: "Codegraff", provider: "codegraff" });
});

test("logout clears the harness file and pending stays pending", async () => {
  const dir = isolate();
  writeApiKey(dir, "cg_sk_out");
  const out = await call("logout");
  expect(await out.json()).toEqual({ signedIn: false, plan: null, provider: null });

  globalThis.fetch = (async () => new Response(JSON.stringify({ status: "pending" }), { status: 200 })) as typeof fetch;
  const poll = await call("poll", { device_code: "wait" });
  expect(await poll.json()).toEqual({ status: "pending" });
});

test("unknown actions and a missing device_code are client errors", async () => {
  isolate();
  expect((await call("nope")).status).toBe(400);
  expect((await call("poll")).status).toBe(400);
});
