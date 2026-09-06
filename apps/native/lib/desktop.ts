import type { BrowserPin, KuriHandle } from "./browser/annotations";
import type { PageInfo } from "./browser-client";

export type DesktopEvent = { type: string; chat?: string; info?: PageInfo; pin?: BrowserPin };
export type DesktopBridge = {
  browser<T = PageInfo | null>(chat: string, method: string, params?: Record<string, unknown>): Promise<T>;
  activity(): Promise<{ rssMiB: number; cpuPercent: number; processes: number; browsers: number }>;
  subscribe(callback: (event: DesktopEvent) => void): () => void;
};
declare global { interface Window { graffDesktop?: DesktopBridge } }
export function desktop(): DesktopBridge | undefined {
  return typeof window !== "undefined" ? window.graffDesktop : undefined;
}
export type BrowserHandle = KuriHandle;
