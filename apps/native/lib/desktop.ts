import type { BrowserPin, KuriHandle } from "./browser/annotations";
import type { PageInfo } from "./browser-client";

export type DesktopEvent = { type: string; chat?: string; info?: PageInfo; pin?: BrowserPin };
export type TerminalEvent = { id: string; seq: number; data?: string; exit?: number };
export type UpdateState = { status: 'idle' | 'unavailable' | 'checking' | 'current' | 'downloading' | 'ready' | 'installing' | 'error'; currentVersion: string; version?: string; percent?: number; automatic: boolean; interactive: boolean; message?: string };
export type DesktopBridge = {
  updates?(action: 'state' | 'check' | 'restart'): Promise<UpdateState>;
  updateSubscribe?(callback: (state: UpdateState) => void): () => void;
  terminal?(action: string, params?: Record<string, unknown>): Promise<{id: string; seq: number; history: string; exit: number | null}>;
  terminalSubscribe?(callback: (event: TerminalEvent) => void): () => void;
  windowControl?(action: "fullscreen" | "zoom-in" | "zoom-out" | "reset-zoom"): Promise<void>;
  browser<T = PageInfo | null>(chat: string, method: string, params?: Record<string, unknown>): Promise<T>;
  activity(): Promise<{ rssMiB: number; cpuPercent: number; processes: number; browsers: number }>;
  subscribe(callback: (event: DesktopEvent) => void): () => void;
};
declare global { interface Window { graffDesktop?: DesktopBridge } }
export function desktop(): DesktopBridge | undefined {
  return typeof window !== "undefined" ? window.graffDesktop : undefined;
}
export type BrowserHandle = KuriHandle;
