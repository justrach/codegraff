import type { CSSProperties, ReactNode, SVGProps } from "react";

/** Free stroke icons that stand in for the commercial `@central-icons-react`
 *  set. Same `size` / `className` surface SidebarNav already uses. */
type IconProps = {
  size?: number;
  className?: string;
  style?: CSSProperties;
};

function Svg({
  size = 18,
  className,
  style,
  children,
  fill = "none",
}: IconProps & { children: ReactNode; fill?: string }) {
  const props: SVGProps<SVGSVGElement> = {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill,
    stroke: fill === "none" ? "currentColor" : "none",
    strokeWidth: fill === "none" ? 1.8 : undefined,
    strokeLinecap: "round",
    strokeLinejoin: "round",
    className,
    style,
    "aria-hidden": true,
  };
  return <svg {...props}>{children}</svg>;
}

export function IconHome(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M4 10.5 12 4l8 6.5V20a1 1 0 0 1-1 1h-5v-6H10v6H5a1 1 0 0 1-1-1z" />
    </Svg>
  );
}

export function IconUserAdd(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M15 19a6 6 0 0 0-12 0" />
      <circle cx="9" cy="8" r="3.2" />
      <path d="M18 8v6M15 11h6" />
    </Svg>
  );
}

export function IconPlusMedium(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M12 5v14M5 12h14" />
    </Svg>
  );
}

export function IconSettingsGear1(p: IconProps) {
  return (
    <Svg {...p}>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9c.3.7.9 1.2 1.6 1.3H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" />
    </Svg>
  );
}

export function IconArrowBoxLeft(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M10 7H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-4" />
      <path d="M14 4h6v6M20 4l-9 9" />
    </Svg>
  );
}

export function IconCheckmark1Small(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M20 6 9 17l-5-5" />
    </Svg>
  );
}

export function IconChevronDownSmall(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M6 9l6 6 6-6" />
    </Svg>
  );
}

export function IconCrossSmall(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M18 6 6 18M6 6l12 12" />
    </Svg>
  );
}

export function IconEditBig(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z" />
    </Svg>
  );
}

export function IconMagnifyingGlass(p: IconProps) {
  return (
    <Svg {...p}>
      <circle cx="11" cy="11" r="7" />
      <path d="M21 21l-4.3-4.3" />
    </Svg>
  );
}

/** Collapse the sidebar: a panel with the chevron centred in the content
 * half, pointing at the rail. The old glyph put the chevron on the divider
 * and rotated the whole panel to mean "expand", which drew the rail on the
 * wrong side. */
export function IconSidebarLeftArrow(p: IconProps) {
  return (
    <Svg {...p}>
      <rect x="3" y="3" width="18" height="18" rx="2.5" />
      <path d="M9 3v18M16 15l-3-3 3-3" />
    </Svg>
  );
}

/** Expand the sidebar: same panel, chevron pointing away from the rail. */
export function IconSidebarLeftOpen(p: IconProps) {
  return (
    <Svg {...p}>
      <rect x="3" y="3" width="18" height="18" rx="2.5" />
      <path d="M9 3v18M14 9l3 3-3 3" />
    </Svg>
  );
}

/** The sidecar browser. */
export function IconGlobe(p: IconProps) {
  return (
    <Svg {...p}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17M12 3.5c2.7 2.7 2.7 14.3 0 17M12 3.5c-2.7 2.7-2.7 14.3 0 17" />
    </Svg>
  );
}

/** Brand mark — graff G instead of the paid popsicle. */
export function IconPopsicle2(p: IconProps) {
  return (
    <Svg {...p} fill="currentColor">
      <path d="M7 4.5A5 5 0 0 1 17 8v6.5a2 2 0 0 1-2 2h-1.2V20a1.3 1.3 0 0 1-2.6 0v-3.5H9a2 2 0 0 1-2-2z" />
    </Svg>
  );
}

export function IconFolder(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M3 7.5A2 2 0 0 1 5 5.5h4.2l1.6 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
    </Svg>
  );
}

export function IconChat(p: IconProps) {
  return (
    <Svg {...p}>
      <path d="M5 6.5A2.5 2.5 0 0 1 7.5 4h9A2.5 2.5 0 0 1 19 6.5v7A2.5 2.5 0 0 1 16.5 16H12l-4.2 3.2A.6.6 0 0 1 7 18.7V16H7.5A2.5 2.5 0 0 1 5 13.5z" />
    </Svg>
  );
}
