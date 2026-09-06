"use client";
import dynamic from "next/dynamic";
import { useEffect, useState, type ComponentProps } from "react";
import { desktop } from "@/lib/desktop";
import ElectronBrowserPane from "./ElectronBrowserPane";
const RemoteBrowserPane = dynamic(() => import("./BrowserPane"), { ssr: false });
type Props = ComponentProps<typeof RemoteBrowserPane>;

export default function DesktopBrowserPane(props: Props) {
  const [native, setNative] = useState<boolean | null>(null);
  useEffect(() => setNative(!!desktop()), []);
  if (native === null) return null;
  return native ? <ElectronBrowserPane {...props} /> : <RemoteBrowserPane {...props} />;
}
