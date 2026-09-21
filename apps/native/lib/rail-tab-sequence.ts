/** Sequential focus for the workspace rail. `inert` and tabIndex < 0 both drop a control. */

export type SequentialControl = {
  id: string;
  tabIndex: number;
  inert?: boolean;
};

export function sequentialFocusIds(controls: SequentialControl[]): string[] {
  return controls.filter((control) => !control.inert && control.tabIndex >= 0).map((control) => control.id);
}

/** Footer / copy chrome when the icon rail is collapsed: out of the tab sequence. */
export function collapsedFooterFocus(collapsed: boolean): { tabIndex: number; inert: boolean; "aria-hidden": boolean } {
  return { tabIndex: collapsed ? -1 : 0, inert: collapsed, "aria-hidden": collapsed };
}
