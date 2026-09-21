import { afterEach, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  clearApiKey,
  credentialPath,
  deviceBase,
  DEFAULT_DEVICE_BASE,
  parseDevicePoll,
  parseDeviceStart,
  publicPollStatus,
  readAccountStatus,
  startDeviceLogin,
  storeApprovedKey,
  writeApiKey,
} from "./codegraff-login";

const temps: string[] = [];
function home(): string {
  const dir = mkdtempSync(path.join(os.tmpdir(), "graff-login-"));
  temps.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

test("deviceBase uses the documented gateway unless overridden", () => {
  expect(deviceBase({})).toBe(DEFAULT_DEVICE_BASE);
  expect(deviceBase({ CODEGRAFF_DEVICE_BASE: "https://example.test/" })).toBe("https://example.test");
});

test("a missing home is signed out and never invents a plan", () => {
  expect(readAccountStatus(home())).toEqual({ signedIn: false, plan: null, provider: null });
});

test("the harness login file signs in without exposing the key", () => {
  const dir = home();
  writeApiKey(dir, "cg_sk_fixture");
  expect(readAccountStatus(dir)).toEqual({ signedIn: true, plan: "Codegraff", provider: "codegraff" });
  const stored = JSON.parse(readFileSync(credentialPath(dir), "utf8")) as { api_key: string };
  expect(stored.api_key).toBe("cg_sk_fixture");
  expect(readFileSync(credentialPath(dir), "utf8")).not.toContain("signedIn");
});

test("the written login file is owner-only", () => {
  const dir = home();
  writeApiKey(dir, "cg_sk_perm");
  expect(statSync(credentialPath(dir)).mode & 0o777).toBe(0o600);
});

test("forge credentials count as signed in when the harness file is absent", () => {
  const dir = home();
  mkdirSync(path.join(dir, "forge"), { recursive: true });
  writeFileSync(path.join(dir, "forge/.credentials.json"), JSON.stringify([
    { id: "other", auth_details: { api_key: "nope" } },
    { id: "codegraff", auth_details: { api_key: "cg_sk_forge" } },
  ]));
  expect(readAccountStatus(dir).signedIn).toBe(true);
});

test("logout removes only the harness file", () => {
  const dir = home();
  writeApiKey(dir, "cg_sk_out");
  mkdirSync(path.join(dir, "forge"), { recursive: true });
  writeFileSync(path.join(dir, "forge/.credentials.json"), "[]");
  expect(clearApiKey(dir)).toBe(true);
  expect(readAccountStatus(dir).signedIn).toBe(false);
  expect(readFileSync(path.join(dir, "forge/.credentials.json"), "utf8")).toBe("[]");
  expect(clearApiKey(dir)).toBe(false);
});

test("start and poll parse the device-code shape and hide the key", () => {
  const start = parseDeviceStart({
    device_code: "dev-1",
    user_code: "ABCD-EFGH",
    verification_uri: "https://codegraff.com/cli/auth",
    verification_uri_complete: "https://codegraff.com/cli/auth?code=ABCD-EFGH",
    interval: 3,
    expires_in: 90,
  });
  expect(start.user_code).toBe("ABCD-EFGH");
  expect(start.interval).toBe(3);
  const ok = parseDevicePoll({ status: "ok", api_key: "cg_sk_secret" });
  expect(ok).toEqual({ status: "ok", api_key: "cg_sk_secret" });
  expect(publicPollStatus(ok)).toEqual({ status: "ok" });
  expect(parseDevicePoll({ status: "pending" })).toEqual({ status: "pending" });
});

test("an approved poll writes the shared store and returns status only", async () => {
  const dir = home();
  const calls: Array<{ url: string; body: unknown }> = [];
  const start = await startDeviceLogin(async (url, body) => {
    calls.push({ url, body });
    return { device_code: "dev-9", user_code: "WXYZ-1234", verification_uri: "https://codegraff.com/cli/auth", interval: 2 };
  }, { CODEGRAFF_DEVICE_BASE: "https://gateway.test" });
  expect(start.device_code).toBe("dev-9");
  expect(calls[0]?.url).toBe("https://gateway.test/v1/device/start");
  const published = storeApprovedKey(dir, { status: "ok", api_key: "cg_sk_stored" });
  expect(published).toEqual({ status: "ok" });
  expect(readAccountStatus(dir).signedIn).toBe(true);
});

test("a damaged login file is signed out instead of throwing", () => {
  const dir = home();
  writeFileSync(credentialPath(dir), "{");
  chmodSync(credentialPath(dir), 0o600);
  expect(readAccountStatus(dir).signedIn).toBe(false);
});
