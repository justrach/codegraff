import { chmodSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";

/** Same file `graff login` writes; the engine reads it on ACP spawn. */
export const CODEGRAFF_KEY_FILE = ".simple-harness-codegraff.json";
export const DEFAULT_DEVICE_BASE = "https://gateway.codegraff.com";

export type DeviceStart = {
  device_code: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete?: string;
  interval: number;
  expires_in: number;
};

export type DevicePoll =
  | { status: "ok"; api_key: string }
  | { status: "pending" | "denied" | "expired" | string };

export type AccountStatus = {
  signedIn: boolean;
  plan: string | null;
  provider: string | null;
};

export type JsonPost = (url: string, body: unknown) => Promise<Record<string, unknown>>;

export function deviceBase(env: NodeJS.ProcessEnv = process.env): string {
  const raw = env.CODEGRAFF_DEVICE_BASE?.trim();
  return raw && raw.length > 0 ? raw.replace(/\/$/, "") : DEFAULT_DEVICE_BASE;
}

export function credentialPath(home: string): string {
  return path.join(home, CODEGRAFF_KEY_FILE);
}

function stringField(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function readSimpleKey(home: string): string | null {
  try {
    const parsed: unknown = JSON.parse(readFileSync(credentialPath(home), "utf8"));
    if (!parsed || typeof parsed !== "object") return null;
    return stringField((parsed as { api_key?: unknown }).api_key);
  } catch {
    return null;
  }
}

/** Mirror the engine: harness login file first, then graff's forge store. */
function readForgeKey(home: string): string | null {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path.join(home, "forge/.credentials.json"), "utf8"));
    if (!Array.isArray(parsed)) return null;
    for (const entry of parsed) {
      if (!entry || typeof entry !== "object") continue;
      const rec = entry as { id?: unknown; auth_details?: { api_key?: unknown } };
      if (rec.id !== "codegraff") continue;
      const key = stringField(rec.auth_details?.api_key);
      if (key) return key;
    }
  } catch {
    /* Missing or damaged forge store is not an account. */
  }
  return null;
}

export function loadApiKey(home: string): string | null {
  return readSimpleKey(home) ?? readForgeKey(home);
}

export function readAccountStatus(home: string): AccountStatus {
  const signedIn = Boolean(loadApiKey(home));
  return {
    signedIn,
    plan: signedIn ? "Codegraff" : null,
    provider: signedIn ? "codegraff" : null,
  };
}

export function writeApiKey(home: string, key: string): void {
  const file = credentialPath(home);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify({ api_key: key })}\n`, { mode: 0o600 });
  chmodSync(file, 0o600);
}

export function clearApiKey(home: string): boolean {
  const file = credentialPath(home);
  if (!existsSync(file)) return false;
  unlinkSync(file);
  return true;
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

export function parseDeviceStart(raw: unknown): DeviceStart {
  const body = asObject(raw);
  const device_code = stringField(body.device_code);
  if (!device_code) throw new Error("device/start returned no device_code");
  return {
    device_code,
    user_code: stringField(body.user_code) ?? "",
    verification_uri: stringField(body.verification_uri) ?? "https://codegraff.com/cli/auth",
    verification_uri_complete: stringField(body.verification_uri_complete) ?? undefined,
    interval: Math.max(1, Number(body.interval) || 2),
    expires_in: Number(body.expires_in) || 600,
  };
}

export function parseDevicePoll(raw: unknown): DevicePoll {
  const body = asObject(raw);
  const status = stringField(body.status) ?? "pending";
  if (status === "ok") {
    const api_key = stringField(body.api_key);
    if (!api_key) throw new Error("approved but no api_key returned");
    return { status: "ok", api_key };
  }
  return { status };
}

/** Public poll result: never includes the key. */
export function publicPollStatus(poll: DevicePoll): { status: string } {
  return { status: poll.status };
}

async function defaultPost(url: string, body: unknown): Promise<Record<string, unknown>> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  const text = await res.text();
  let parsed: unknown = {};
  if (text) {
    try { parsed = JSON.parse(text); }
    catch { throw new Error(`device endpoint returned non-JSON (${res.status})`); }
  }
  if (!res.ok) {
    const message = stringField(asObject(parsed).error) ?? `device endpoint ${res.status}`;
    throw new Error(message);
  }
  return asObject(parsed);
}

export async function startDeviceLogin(post: JsonPost = defaultPost, env?: NodeJS.ProcessEnv): Promise<DeviceStart> {
  return parseDeviceStart(await post(`${deviceBase(env)}/v1/device/start`, { device_label: "codegraff-desktop" }));
}

export async function pollDeviceLogin(deviceCode: string, post: JsonPost = defaultPost, env?: NodeJS.ProcessEnv): Promise<DevicePoll> {
  return parseDevicePoll(await post(`${deviceBase(env)}/v1/device/poll`, { device_code: deviceCode }));
}

export function storeApprovedKey(home: string, poll: DevicePoll): { status: string } {
  if (poll.status === "ok") writeApiKey(home, poll.api_key);
  return publicPollStatus(poll);
}
