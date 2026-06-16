// Throbber frame data — animated braille "thinking" indicators.
//
// Frames captured verbatim from @zane-chen/agents-are-thinking (MIT,
// https://github.com/czl9707/agents-are-thinking). Each effect is a
// deterministic finite cycle of fixed-width (9-char) braille strings, so we
// vendor the sequences here and cycle them with a plain timer instead of
// pulling in the upstream WASM runtime.

export type ThrobberVariant = "thinking" | "tool" | "spinner" | "pulse";

export const THROBBER_FRAMES: Record<ThrobberVariant, readonly string[]> = {
  // Classic single-glyph braille spinner — one tidy spinner (1 char wide) for
  // status lines like the "Working for…" header.
  spinner: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
  // Compact breathe — the centre 3 columns of BrailleBreathe. Same pulsing feel
  // as the full effect but narrow enough for the composer pill.
  pulse: ["⠁⠀⠁", "⠇⠁⠇", "⠏⠇⠏", "⠿⠏⠿", "⠿⠿⠿", "⠏⠿⠏", "⠇⠏⠇", "⠁⠇⠁", "⠀⠁⠀"],
  // BrailleBreathe
  thinking: [
    "⠿⠏⠇⠁⠀⠁⠇⠏⠿",
    "⠿⠿⠏⠇⠁⠇⠏⠿⠿",
    "⠏⠿⠿⠏⠇⠏⠿⠿⠏",
    "⠇⠏⠿⠿⠏⠿⠿⠏⠇",
    "⠁⠇⠏⠿⠿⠿⠏⠇⠁",
    "⠀⠁⠇⠏⠿⠏⠇⠁⠀",
    "⠁⠀⠁⠇⠏⠇⠁⠀⠁",
    "⠇⠁⠀⠁⠇⠁⠀⠁⠇",
    "⠏⠇⠁⠀⠁⠀⠁⠇⠏",
  ],
  // BrailleScanner
  tool: [
    "⡇⠀⠀⠀⠀⠀⠀⠀⠀",
    "⣾⠀⠀⠀⠀⠀⠀⠀⠀",
    "⠿⡇⠀⠀⠀⠀⠀⠀⠀",
    "⣿⢿⠀⠀⠀⠀⠀⠀⠀",
    "⡪⣽⡇⠀⠀⠀⠀⠀⠀",
    "⠀⣙⢿⠀⠀⠀⠀⠀⠀",
    "⠊⢦⡝⡇⠀⠀⠀⠀⠀",
    "⠐⣃⢙⣿⠀⠀⠀⠀⠀",
    "⠐⠑⠳⣼⡇⠀⠀⠀⠀",
    "⠀⠀⠤⣼⣽⠀⠀⠀⠀",
    "⠀⠈⢐⣻⣿⡇⠀⠀⠀",
    "⠀⠀⠀⢬⡂⣿⠀⠀⠀",
    "⠀⠀⢀⠘⣰⣿⡇⠀⠀",
    "⠀⠀⠀⠄⠠⣾⣿⠀⠀",
    "⠀⠀⠀⢀⠀⢏⡾⡇⠀",
    "⠀⠀⠀⠀⠁⡠⠽⢿⠀",
    "⠀⠀⠀⠀⠀⠸⠋⣿⡇",
    "⠀⠀⠀⠀⠀⠜⢰⡸⣿",
    "⠀⠀⠀⠀⠀⠀⢅⢹⣷",
    "⠀⠀⠀⠀⠀⠀⢀⠭⡱",
    "⠀⠀⠀⠀⠀⠀⠀⣢⡿",
    "⠀⠀⠀⠀⠀⠀⠀⠀⣹",
    "⠀⠀⠀⠀⠀⠀⠀⠈⠼",
    "⠀⠀⠀⠀⠀⠀⠀⠀⢨",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠠",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀",
  ],
};
