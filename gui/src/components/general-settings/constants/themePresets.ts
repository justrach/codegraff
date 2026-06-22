import type { ThemePresetId } from "@/app/themeStore";

export type ThemePresetMeta = {
  id: ThemePresetId;
  name: string;
  description: string;
  // Dark-mode swatch used only for the picker preview chips.
  swatch: { bg: string; surface: string; accent: string; text: string };
};

export const THEME_PRESETS: ThemePresetMeta[] = [
  {
    id: "warm-graphite",
    name: "Warm Graphite",
    description: "Warm near-black and amber — the codegraff default.",
    swatch: { bg: "#16140f", surface: "#1f1c16", accent: "#e8a33d", text: "#edeae2" },
  },
  {
    id: "slate",
    name: "Slate",
    description: "Cool neutral graphite with a steel-blue accent.",
    swatch: { bg: "#14171b", surface: "#1c2026", accent: "#6aa0e0", text: "#e6e9ee" },
  },
  {
    id: "nord",
    name: "Ocean",
    description: "Arctic blues and a calm teal accent.",
    swatch: { bg: "#11181c", surface: "#18222a", accent: "#6fc0cc", text: "#dfe9ee" },
  },
  {
    id: "forest",
    name: "Forest",
    description: "Warm-neutral base with a sage-green accent.",
    swatch: { bg: "#14160f", surface: "#1d2018", accent: "#82b06a", text: "#e8ebe0" },
  },
  {
    id: "mono",
    name: "Mono",
    description: "Pure black & white — monochrome, no hue.",
    swatch: { bg: "#0a0a0a", surface: "#161618", accent: "#fafafa", text: "#fafafa" },
  },
  {
    id: "rose",
    name: "Rose",
    description: "Soft pinks with a bright rose accent.",
    swatch: { bg: "#1a0e14", surface: "#251521", accent: "#ff6b9d", text: "#f7dde7" },
  },
];
