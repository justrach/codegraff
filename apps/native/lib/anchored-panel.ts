/** Place a fixed panel next to a trigger without clipping the viewport. */
export type Box = { left: number; right: number; top: number; bottom: number };
export type Viewport = { width: number; height: number };

export function placeAnchoredPanel(
  trigger: Box,
  viewport: Viewport,
  panel: { width: number; height: number } = { width: 310, height: 420 },
): { top: number; left: number } {
  const margin = 8;
  const width = Math.min(panel.width, Math.max(0, viewport.width - margin * 2));
  let left = trigger.right - width;
  if (left < margin) left = trigger.right + margin;
  left = Math.max(margin, Math.min(left, viewport.width - width - margin));
  const top = Math.max(48, Math.min(trigger.bottom + margin, viewport.height - panel.height));
  return { top, left };
}
