import type { DockviewApi, DockviewGroupPanel } from "dockview-react";

// easeOutExpo — fast start, soft settle. Matches the chat-tile fade easings
// (cubic-bezier(0.16, 1, 0.3, 1)) so the pane fade and the size glide feel like
// one motion.
function easeOutExpo(t: number): number {
  return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t);
}

const OPEN_DURATION_MS = 300;
// Match the open glide so close animations have the same weight instead of
// snapping away faster than the pane content fade.
const CLOSE_DURATION_MS = 300;
// Start width/height the opening pane grows *from*. A few px (not 0) keeps the
// pane's own content mounted/measurable while still reading as "slides open".
const OPEN_START_PX = 8;
// Width/height the closing pane shrinks *to* before it is removed. Left non-zero
// so the splitview keeps a real view to animate instead of collapsing instantly.
const CLOSE_END_PX = 4;

export type ResizeAxis = "width" | "height";

export interface PaneResizeTween {
  /** Cancel the in-flight animation frame (does not revert sizes already set). */
  cancel(): void;
}

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

function setGroupSize(
  group: DockviewGroupPanel,
  axis: ResizeAxis,
  value: number,
): void {
  group.api.setSize(
    axis === "width" ? { width: value } : { height: value },
  );
}

function getGroupSize(group: DockviewGroupPanel, axis: ResizeAxis): number {
  const size = axis === "width" ? group.api.width : group.api.height;
  return typeof size === "number" ? size : 0;
}

function noopTween(): PaneResizeTween {
  return { cancel() {} };
}

/**
 * Glide a freshly added pane's group open by tweening its grid size from a small
 * start value up to the size dockview just settled it at. The chat (the flexible
 * sibling) reflows to fill the remaining space, so chat and the new pane move to
 * their final sizes together instead of the chat snapping in one frame.
 *
 * Call immediately after the `addPanel` that created `group` — `group.api`'s size
 * already reflects the target layout at that point.
 */
export function animatePaneOpen(
  group: DockviewGroupPanel,
  axis: ResizeAxis,
  onComplete?: () => void,
): PaneResizeTween {
  const target = getGroupSize(group, axis);
  if (prefersReducedMotion() || target <= OPEN_START_PX) {
    onComplete?.();
    return noopTween();
  }

  let frame: number | null = null;
  let start: number | null = null;
  let done = false;
  const finish = () => {
    if (done) {
      return;
    }
    done = true;
    onComplete?.();
  };
  setGroupSize(group, axis, OPEN_START_PX);

  const step = (now: number) => {
    if (start == null) {
      start = now;
    }
    const elapsed = now - start;
    const t = Math.min(1, elapsed / OPEN_DURATION_MS);
    const value = OPEN_START_PX + (target - OPEN_START_PX) * easeOutExpo(t);
    setGroupSize(group, axis, value);
    if (t < 1) {
      frame = window.requestAnimationFrame(step);
    } else {
      frame = null;
      finish();
    }
  };

  frame = window.requestAnimationFrame(step);

  return {
    cancel() {
      if (frame != null) {
        window.cancelAnimationFrame(frame);
        frame = null;
      }
      finish();
    },
  };
}

/**
 * Glide the closing pane's group down to a sliver so the chat reflows back to
 * full width/height smoothly instead of snapping back when the pane is removed.
 * The pane's content fade-out (AuxiliaryPaneShell) runs over the same window and
 * owns the actual `api.close()`; this only animates the surrounding reflow, so it
 * never removes the pane itself (avoids double-close races with the shell).
 *
 * Each frame re-resolves the group by panel id and bails the moment the pane is
 * gone, so it is safe even if the shell's `api.close()` lands mid-tween.
 *
 * Looks the group up by dockview panel id so the caller only needs the id from
 * the close-request event.
 */
export function animatePaneClose(
  api: DockviewApi,
  dockviewPanelId: string,
  axis: ResizeAxis,
): PaneResizeTween {
  const initialGroup = api.getPanel(dockviewPanelId)?.group ?? null;
  if (initialGroup == null || prefersReducedMotion()) {
    return noopTween();
  }

  const start = getGroupSize(initialGroup, axis);
  if (start <= CLOSE_END_PX) {
    return noopTween();
  }

  let frame: number | null = null;
  let startedAt: number | null = null;

  const step = (now: number) => {
    const group = api.getPanel(dockviewPanelId)?.group ?? null;
    if (group == null) {
      // Pane already removed (shell's fade completed and closed it) — done.
      frame = null;
      return;
    }
    if (startedAt == null) {
      startedAt = now;
    }
    const elapsed = now - startedAt;
    const t = Math.min(1, elapsed / CLOSE_DURATION_MS);
    const value = start + (CLOSE_END_PX - start) * easeOutExpo(t);
    setGroupSize(group, axis, value);
    if (t < 1) {
      frame = window.requestAnimationFrame(step);
    } else {
      frame = null;
    }
  };

  frame = window.requestAnimationFrame(step);

  return {
    cancel() {
      if (frame != null) {
        window.cancelAnimationFrame(frame);
        frame = null;
      }
    },
  };
}
