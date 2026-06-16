import type { ComponentProps } from "react";

export interface PaneSurfaceProps extends ComponentProps<"section"> {
  framed?: boolean;
}

export interface SidebarContextProps {
  state: "expanded" | "collapsed";
  open: boolean;
  setOpen: (open: boolean | ((open: boolean) => boolean)) => void;
  toggleSidebar: () => void;
}
