/** Placement for the Appearance dialog (#977). */

export const APPEARANCE_PANEL_WIDTH = 310;
export const APPEARANCE_PANEL_MIN_HEIGHT = 420;
export const VIEWPORT_MARGIN = 8;
export const TITLEBAR_OFFSET = 48;

export type TriggerRect = { left: number; right: number; top: number; bottom: number };
export type Viewport = { width: number; height: number };
export type PanelBox = { top: number; left: number; width: number };

/**
 * Keep the 310px Appearance dialog fully on-screen.
 * A left-sidebar gear used to set `right: window.innerWidth - trigger.right`,
 * which pinned the panel's right edge to the trigger and hung the rest off
 * the left of the viewport. Prefer the trigger's right, then clamp.
 */
export function appearancePanelPosition(
  trigger: TriggerRect,
  viewport: Viewport,
  panel: { width?: number; height?: number } = {},
): PanelBox {
  const margin = VIEWPORT_MARGIN;
  const width = Math.min(panel.width ?? APPEARANCE_PANEL_WIDTH, Math.max(0, viewport.width - margin * 2));
  const height = Math.min(panel.height ?? APPEARANCE_PANEL_MIN_HEIGHT, Math.max(0, viewport.height - margin * 2));

  let left = trigger.right + margin;
  if (left + width > viewport.width - margin) left = trigger.left - margin - width;
  if (left < margin) left = margin;
  if (left + width > viewport.width - margin) left = Math.max(margin, viewport.width - margin - width);

  const below = trigger.bottom + margin;
  const maxTop = Math.max(margin, viewport.height - height - margin);
  let top = Math.min(below, maxTop);
  top = Math.max(Math.min(TITLEBAR_OFFSET, maxTop), top);
  if (top < margin) top = margin;

  return { top, left, width };
}
