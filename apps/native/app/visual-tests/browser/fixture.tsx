"use client";
import { useEffect, useState } from "react";
import ElectronBrowserPane from "@/components/site/ElectronBrowserPane";
import type { BrowserPin } from "@/lib/browser/annotations";
export default function BrowserFixture() {
  const [pins, setPins] = useState<BrowserPin[]>([]);
  const [url, setUrl] = useState("");
  useEffect(() => setUrl(new URLSearchParams(location.search).get("url") || ""), []);
  return <main className="flex h-screen justify-end gap-3 bg-page p-3 text-ink">
    <p role="status">{pins.length ? "Pin ready for your note" : "Browser fixture"}</p>
    {url && <ElectronBrowserPane chat="browser-test" pins={pins} onPinsChange={setPins} initialUrl={url} onAsk={() => {}} onClose={() => {}} />}
  </main>;
}
