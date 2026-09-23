/** Desktop interface sounds. The app owns the preference; Cuelume does not.
 *  Off is the default, and off never loads the sound library. */

export const uiSoundsKey = "graff-ui-sounds";
export const uiSoundsEvent = "graff-ui-sounds";
export const uiSoundVolume = 0.4;

export type UiSoundPrefs = { interface: boolean; ready: boolean };
export type UiCue = "toggle" | "press" | "success" | "error" | "ready";

const off: UiSoundPrefs = { interface: false, ready: false };

export function parseUiSoundPrefs(raw: string | null): UiSoundPrefs {
  if (!raw) return off;
  try {
    const value = JSON.parse(raw) as unknown;
    if (!value || typeof value !== "object" || Array.isArray(value)) return off;
    const record = value as Record<string, unknown>;
    return { interface: record.interface === true, ready: record.ready === true };
  } catch {
    return off;
  }
}

export function cueAllowed(prefs: UiSoundPrefs, reduced: boolean, name: UiCue): boolean {
  if (reduced || prefs.interface !== true) return false;
  return name === "ready" ? prefs.ready === true : true;
}

export function readUiSoundPrefs(): UiSoundPrefs {
  try { return parseUiSoundPrefs(localStorage.getItem(uiSoundsKey)); }
  catch { return off; }
}

export function writeUiSoundPrefs(next: UiSoundPrefs): void {
  const stored = { interface: next.interface === true, ready: next.ready === true };
  localStorage.setItem(uiSoundsKey, JSON.stringify(stored));
  window.dispatchEvent(new Event(uiSoundsEvent));
}

export function reducedMotion(): boolean {
  try { return window.matchMedia("(prefers-reduced-motion: reduce)").matches; }
  catch { return false; }
}

let loading: Promise<typeof import("cuelume")> | null = null;

function library() {
  loading ??= import("cuelume").then(mod => {
    mod.setVolume(uiSoundVolume);
    return mod;
  });
  return loading;
}

/** No-op unless interface sounds are on and the OS is not asking for less motion. */
export function playUiSound(name: UiCue): void {
  if (typeof window === "undefined") return;
  if (!cueAllowed(readUiSoundPrefs(), reducedMotion(), name)) return;
  void library().then(mod => {
    if (!cueAllowed(readUiSoundPrefs(), reducedMotion(), name)) return;
    mod.play(name, { volume: uiSoundVolume });
  }).catch(() => {});
}

/** Copy, then cue success or a recoverable failure. The rejection still propagates. */
export function copyText(text: string): Promise<void> {
  return navigator.clipboard.writeText(text).then(() => {
    playUiSound("success");
  }, (err: unknown) => {
    playUiSound("error");
    throw err;
  });
}
