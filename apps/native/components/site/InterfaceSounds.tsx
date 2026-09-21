"use client";
import { useEffect, useState } from "react";
import { Switch } from "../atoms/Switch";
import { readUiSoundPrefs, reducedMotion, uiSoundsEvent, writeUiSoundPrefs, type UiSoundPrefs } from "@/lib/ui-sounds";

const off: UiSoundPrefs = { interface: false, ready: false };

/** Appearance-panel controls. Playback lives in lib/ui-sounds; this only stores the choice. */
export default function InterfaceSounds() {
  const [prefs, setPrefs] = useState<UiSoundPrefs>(off);
  const [muted, setMuted] = useState(false);
  useEffect(() => {
    const sync = () => { setPrefs(readUiSoundPrefs()); setMuted(reducedMotion()); };
    sync();
    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    query.addEventListener("change", sync);
    window.addEventListener(uiSoundsEvent, sync);
    window.addEventListener("storage", sync);
    return () => {
      query.removeEventListener("change", sync);
      window.removeEventListener(uiSoundsEvent, sync);
      window.removeEventListener("storage", sync);
    };
  }, []);
  const update = (next: UiSoundPrefs) => { writeUiSoundPrefs(next); setPrefs(next); };
  return <fieldset className="mt-4 border-t border-line pt-3">
    <legend className="mb-1 text-xs font-medium">Interface sounds</legend>
    <p className="mb-3 text-xs text-ink-3">Off until you turn them on. Quiet clicks on switches, Send, and copy. Nothing on hover.</p>
    <div className="flex items-center justify-between gap-3 py-1">
      <span className="text-xs">Sounds</span>
      <Switch checked={prefs.interface} label="Interface sounds" onChange={on => update({ ...prefs, interface: on })} />
    </div>
    <div className="flex items-center justify-between gap-3 py-1">
      <span id="ui-sounds-ready" className="text-xs text-ink-2">Ding when a reply finishes</span>
      <Switch checked={prefs.interface && prefs.ready} disabled={!prefs.interface} label="Ding when a reply finishes" onChange={on => update({ ...prefs, ready: on })} />
    </div>
    {!prefs.interface && <p className="mt-2 text-xs text-ink-3">Turn sounds on to use the reply ding. Turning sounds off keeps that choice for later.</p>}
    {muted && <p className="mt-2 text-xs text-ink-3">Muted while Reduce motion is on. Your choice is saved.</p>}
  </fieldset>;
}
