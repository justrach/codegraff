"use client";
import { useEffect, useState, type CSSProperties } from "react";
export default function DesktopTitlebar() {
  const [enabled, setEnabled] = useState(false);
  useEffect(() => { if (window.graffDesktop) { setEnabled(true); document.documentElement.dataset.desktop = "true"; } }, []);
  return enabled ? <><style>{`html[data-desktop="true"] [data-graff-main] { height: calc(100dvh - 36px); }`}</style><div aria-hidden className="h-9 border-b border-line bg-canvas" style={{ WebkitAppRegion: "drag" } as CSSProperties} /></> : null;
}
