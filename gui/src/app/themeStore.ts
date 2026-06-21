import { create } from "zustand";

export type ThemeMode = "light" | "dark";
export type ThemePresetId = "warm-graphite" | "slate" | "nord" | "forest";

export const THEME_PRESET_IDS: ThemePresetId[] = [
  "warm-graphite",
  "slate",
  "nord",
  "forest",
];

const MODE_STORAGE_KEY = "codegraff:theme";
const PRESET_STORAGE_KEY = "codegraff:theme-preset";

type PersistedThemeSettings = {
  mode: ThemeMode | null;
  preset: ThemePresetId | null;
};

function readStoredMode(): ThemeMode | null {
  try {
    const value = window.localStorage.getItem(MODE_STORAGE_KEY);
    return value === "light" || value === "dark" ? value : null;
  } catch {
    return null;
  }
}

function readStoredPreset(): ThemePresetId | null {
  try {
    const value = window.localStorage.getItem(PRESET_STORAGE_KEY);
    return THEME_PRESET_IDS.includes(value as ThemePresetId)
      ? (value as ThemePresetId)
      : null;
  } catch {
    return null;
  }
}

function readInitialMode(): ThemeMode {
  return readStoredMode() ?? "light";
}

function applyTheme(mode: ThemeMode, preset: ThemePresetId) {
  const root = document.documentElement;
  const isDark = mode === "dark";
  root.classList.toggle("dark", isDark);
  root.style.colorScheme = isDark ? "dark" : "light";
  root.dataset.theme = preset;
}

function persistMode(mode: ThemeMode) {
  try {
    window.localStorage.setItem(MODE_STORAGE_KEY, mode);
  } catch {
    // Ignore storage failures; the in-memory theme still updates.
  }
}

function persistPreset(preset: ThemePresetId) {
  try {
    window.localStorage.setItem(PRESET_STORAGE_KEY, preset);
  } catch {
    // Ignore storage failures; the in-memory theme still updates.
  }
}

function persistThemeSettings(mode: ThemeMode, preset: ThemePresetId) {
  void fetch("/api/update_theme_settings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ input: { mode, preset } }),
  }).catch(() => {
    // Keep localStorage as a same-origin fallback if the backend is unavailable.
  });
}

function isThemeMode(value: unknown): value is ThemeMode {
  return value === "light" || value === "dark";
}

function isThemePreset(value: unknown): value is ThemePresetId {
  return (
    typeof value === "string" &&
    THEME_PRESET_IDS.includes(value as ThemePresetId)
  );
}

const initialMode = readInitialMode();
const initialPreset = readStoredPreset() ?? "warm-graphite";

// Apply immediately at module import (before React renders) to avoid a flash.
applyTheme(initialMode, initialPreset);

type ThemeStore = {
  mode: ThemeMode;
  preset: ThemePresetId;
  setMode: (mode: ThemeMode) => void;
  toggleMode: () => void;
  setPreset: (preset: ThemePresetId) => void;
};

export const useThemeStore = create<ThemeStore>((set, get) => ({
  mode: initialMode,
  preset: initialPreset,
  setMode: (mode) => {
    persistMode(mode);
    applyTheme(mode, get().preset);
    persistThemeSettings(mode, get().preset);
    set({ mode });
  },
  toggleMode: () => {
    const mode = get().mode === "dark" ? "light" : "dark";
    persistMode(mode);
    applyTheme(mode, get().preset);
    persistThemeSettings(mode, get().preset);
    set({ mode });
  },
  setPreset: (preset) => {
    persistPreset(preset);
    applyTheme(get().mode, preset);
    persistThemeSettings(get().mode, preset);
    set({ preset });
  },
}));

export async function hydrateThemeSettings() {
  try {
    const response = await fetch("/api/get_theme_settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    if (!response.ok) {
      return;
    }
    const settings = (await response.json()) as PersistedThemeSettings;
    const current = useThemeStore.getState();
    const mode = isThemeMode(settings.mode) ? settings.mode : current.mode;
    const preset = isThemePreset(settings.preset)
      ? settings.preset
      : current.preset;
    persistMode(mode);
    persistPreset(preset);
    applyTheme(mode, preset);
    useThemeStore.setState({ mode, preset });
  } catch {
    // localStorage already supplied the initial theme.
  }
}
