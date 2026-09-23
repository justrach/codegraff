"use client";
import { useEffect, useState, type CSSProperties } from "react";
export default function DesktopTitlebar() {
  const [enabled, setEnabled] = useState(false);
  useEffect(() => {
    const bridge = window.graffDesktop;
    if (!bridge) return;
    document.documentElement.dataset.desktop = "true";
    if (bridge.frame === "system") {
      document.documentElement.dataset.desktopFrame = "system";
      return;
    }
    setEnabled(true);
  }, []);
  return enabled ? <><style>{`
    html[data-desktop="true"] { --desktop-title-height: 36px; }
    html[data-desktop-fullscreen="true"] { --desktop-title-height: 0px; }
    html[data-desktop="true"] [data-graff-main] { height: calc(100dvh - var(--desktop-title-height)); }
    [data-desktop-titlebar] { height: var(--desktop-title-height); }
    html[data-desktop-fullscreen="true"] [data-desktop-titlebar] { display: none; }
  `}</style><div data-desktop-titlebar aria-hidden className="shrink-0 border-b border-line bg-canvas" style={{ WebkitAppRegion: "drag" } as CSSProperties} /></> : null;
}
