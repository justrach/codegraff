"use client";
import { useRef } from "react";
import { browserNavigate } from "@/lib/browser-client";
import type { InlineReference } from "@/lib/inline-reference";

export async function dispatchInlineReference(target: string, root: string | undefined, actions: {
  file(path: string): void;
  browser(url: string): Promise<void>;
}, request: typeof fetch = fetch) {
  const params = new URLSearchParams({ path: target });
  if (root) params.set("root", root);
  const response = await request(`/api/inline-reference?${params}`, { cache: "no-store" });
  if (!response.ok) throw new Error("Could not resolve this reference. Try again.");
  const result = await response.json() as InlineReference;
  if (result.kind === "browser") await actions.browser(result.url);
  else actions.file(result.path);
}

export function useReferenceNavigation(options: {
  context(id?: number): { root?: string; chat: string; focus(): void };
  hideOtherPanes(): void;
  files(open: boolean): void;
  browser(open: boolean): void;
  request(path: string): void;
  error(message: string): void;
}) {
  const current = useRef(options); current.current = options;
  const sequence = useRef(0);
  const openPath = (path: string) => {
    sequence.current++;
    const o = current.current;
    o.hideOtherPanes(); o.browser(false); o.files(true); o.request(path);
  };
  const openReference = (path: string, id?: number) => {
    const ticket = ++sequence.current, o = current.current, context = o.context(id);
    o.error("");
    void dispatchInlineReference(path, context.root, {
      file: target => { if (ticket === sequence.current) { context.focus(); openPath(target); } },
      browser: async url => {
        if (ticket !== sequence.current) return;
        context.focus(); o.hideOtherPanes(); o.files(false); o.browser(true);
        await browserNavigate(context.chat, url);
      },
    }).catch(error => { if (ticket === sequence.current) o.error(error instanceof Error ? error.message : "Could not open reference."); });
  };
  return { openPath, openReference };
}
