"use client";

import { useEffect } from "react";
import { browserWarm } from "@/lib/browser-client";

/** Start Kuri's Chrome with the window, so opening the pane is not a wait. */
export function BrowserWarm() {
  useEffect(() => {
    void browserWarm().catch(() => undefined);
  }, []);
  return null;
}
