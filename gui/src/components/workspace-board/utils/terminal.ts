import { WTerm } from "@wterm/dom";

import {
  DEFAULT_TERMINAL_COLS,
  DEFAULT_TERMINAL_ROWS,
  FONT_READY_TIMEOUT_MS,
  TERMINAL_STABLE_FRAME_ATTEMPTS,
  TERMINAL_STABLE_FRAME_COUNT,
} from "../constants/terminal";
import type { TerminalGridSize } from "../types/workspaceBoard";

export function applyTerminalAppearance(
  element: HTMLElement,
  isDarkTheme: boolean,
) {
  element.classList.remove("theme-light", "theme-solarized-dark");
  element.classList.add(isDarkTheme ? "theme-solarized-dark" : "theme-light");
  element.style.removeProperty("--term-bg");
  element.style.removeProperty("--term-font-family");
  element.style.removeProperty("--term-font-size");
  element.style.removeProperty("--term-line-height");
  element.style.removeProperty("--term-row-height");
  element.style.removeProperty("border-radius");
  element.style.removeProperty("box-shadow");
  element.style.removeProperty("padding");
}

export async function waitForStableTerminalSize(terminal: WTerm) {
  await waitForFontsReady();

  let stableFrames = 0;
  let stableSize = measureTerminalGridSize(terminal);

  for (
    let attempt = 0;
    attempt < TERMINAL_STABLE_FRAME_ATTEMPTS;
    attempt += 1
  ) {
    await nextFrame();
    const measuredSize = measureTerminalGridSize(terminal);
    if (measuredSize == null) {
      continue;
    }

    if (
      stableSize != null &&
      measuredSize.cols === stableSize.cols &&
      measuredSize.rows === stableSize.rows
    ) {
      stableFrames += 1;
      if (stableFrames >= TERMINAL_STABLE_FRAME_COUNT) {
        return measuredSize;
      }
      continue;
    }

    stableSize = measuredSize;
    stableFrames = 0;
  }

  return stableSize ?? normalizeTerminalSize(DEFAULT_TERMINAL_COLS, DEFAULT_TERMINAL_ROWS);
}

export function normalizeTerminalSize(
  cols: number,
  rows: number,
): TerminalGridSize {
  return {
    cols: Math.max(2, Math.floor(cols) || DEFAULT_TERMINAL_COLS),
    rows: Math.max(1, Math.floor(rows) || DEFAULT_TERMINAL_ROWS),
  };
}

export function measureTerminalGridSize(
  terminal: WTerm,
): TerminalGridSize | null {
  const element = terminal.element;
  if (element.clientWidth === 0 || element.clientHeight === 0) {
    return null;
  }

  const probeRow = document.createElement("div");
  probeRow.className = "term-row";
  probeRow.style.visibility = "hidden";
  probeRow.style.position = "absolute";

  const probeCell = document.createElement("span");
  probeCell.textContent = "W";
  probeRow.appendChild(probeCell);
  element.appendChild(probeRow);

  const charWidth = probeCell.getBoundingClientRect().width;
  const rowHeight = probeRow.getBoundingClientRect().height;

  probeRow.remove();

  if (charWidth <= 0 || rowHeight <= 0) {
    return null;
  }

  return normalizeTerminalSize(
    Math.floor(element.clientWidth / charWidth),
    Math.floor(element.clientHeight / rowHeight),
  );
}

async function waitForFontsReady() {
  const fonts = document.fonts;
  if (fonts == null) {
    return;
  }

  try {
    await Promise.race([
      fonts.ready,
      new Promise<void>((resolve) => {
        window.setTimeout(resolve, FONT_READY_TIMEOUT_MS);
      }),
    ]);
  } catch {
    // Ignore font loading failures and continue with best-effort metrics.
  }
}

function nextFrame() {
  return new Promise<void>((resolve) => {
    requestAnimationFrame(() => {
      resolve();
    });
  });
}
