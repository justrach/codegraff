"use client";
import { useEffect, useState, type ComponentProps } from "react";
import { desktop } from "@/lib/desktop";
import ElectronBrowserPane from "./ElectronBrowserPane";
import ExtensionBrowserPane from "./ExtensionBrowserPane";
type Props = ComponentProps<typeof ElectronBrowserPane>;

export default function DesktopBrowserPane(props: Props) {
  const [native, setNative] = useState<boolean | null>(null);
  useEffect(() => setNative(!!desktop()), []);
  if (native === null) return null;
  return native ? <ElectronBrowserPane {...props} /> : <ExtensionBrowserPane {...props} />;
}
