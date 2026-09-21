import { normalizeBrowserTarget } from "./browser-links";
import type { AccountStatus, DeviceStart } from "./codegraff-login";

export type { AccountStatus, DeviceStart };
export type PublicPoll = { status: string };

const ACCOUNT = "/api/account";

async function readJson<T>(res: Response): Promise<T> {
  const body = await res.json().catch(() => ({})) as T & { error?: string };
  if (!res.ok) throw new Error(body.error ?? `account ${res.status}`);
  return body;
}

export async function fetchAccount(): Promise<AccountStatus> {
  const res = await fetch(ACCOUNT, { method: "GET", cache: "no-store" });
  return readJson<AccountStatus>(res);
}

export async function startLogin(): Promise<DeviceStart> {
  const res = await fetch(ACCOUNT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "start" }),
    cache: "no-store",
  });
  return readJson<DeviceStart>(res);
}

export async function pollLogin(device_code: string): Promise<PublicPoll> {
  const res = await fetch(ACCOUNT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "poll", device_code }),
    cache: "no-store",
  });
  return readJson<PublicPoll>(res);
}

export async function logoutAccount(): Promise<AccountStatus> {
  const res = await fetch(ACCOUNT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "logout" }),
    cache: "no-store",
  });
  return readJson<AccountStatus>(res);
}

export function openVerification(url: string): boolean {
  const href = normalizeBrowserTarget(url);
  if (!href) return false;
  window.open(href, "_blank", "noopener,noreferrer");
  return true;
}

export const LOGIN_EVENT = "graff-open-login";
export const ONBOARDING_EVENT = "graff-open-onboarding";
export const ACCOUNT_EVENT = "graff-account-changed";

export function requestLogin(): void {
  window.dispatchEvent(new CustomEvent(LOGIN_EVENT));
}

export function requestOnboarding(): void {
  window.dispatchEvent(new CustomEvent(ONBOARDING_EVENT));
}

export function notifyAccountChanged(): void {
  window.dispatchEvent(new CustomEvent(ACCOUNT_EVENT));
}
