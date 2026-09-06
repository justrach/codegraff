"use client";
import { useEffect, useRef, useState } from "react";
import { parseTheme, themeWarnings, themeLimit, type CustomTheme } from "@/lib/custom-themes";
import { selectCustomTheme, type Appearance } from "@/lib/appearance";

export default function CustomThemes({ selected }: { selected: Appearance }) {
  const [themes, setThemes] = useState<CustomTheme[]>([]), [issues, setIssues] = useState<string[]>([]), [error, setError] = useState("");
  const upload = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const controller = new AbortController(); let timer: ReturnType<typeof setTimeout>;
    const refresh = async () => {
      try {
        if (document.visibilityState === "hidden") return;
        const response = await fetch("/api/themes", { signal: controller.signal, cache: "no-store" });
        const data = await response.json(); if (!response.ok) throw Error(data.error);
        setThemes(data.themes.map(parseTheme)); setIssues(data.issues); setError("");
      } catch (error) { if (!controller.signal.aborted) setError(error instanceof Error ? error.message : "Could not load themes."); }
      finally { if (!controller.signal.aborted) timer = setTimeout(refresh, 2000); }
    };
    void refresh(); return () => { controller.abort(); clearTimeout(timer); };
  }, []);
  return <section className="mt-3 border-t border-line pt-3" aria-label="Custom themes">
    <div className="flex items-center justify-between"><strong className="text-xs font-medium">My themes</strong><button className="rounded px-2 py-1 text-[11px] text-accent-ink hover:bg-hover" onClick={() => upload.current?.click()}>Import theme</button></div>
    <p className="mt-1 text-[11px] leading-4 text-ink-3">Type <code>$gui-theme</code> or <code>@gui-theme</code> in chat to create your own with Graff.</p>
    <input ref={upload} type="file" accept="application/json,.json" className="hidden" aria-label="Import theme file" onChange={async event => {
      const file = event.target.files?.[0]; event.target.value = ""; if (!file) return;
      try {
        if (file.size > themeLimit) throw Error("Theme exceeds 16 KiB.");
        const theme = parseTheme(JSON.parse(await file.text()));
        if (themes.some(current => current.id === theme.id)) throw Error("That theme id already exists. Give the imported theme a new id first.");
        const response = await fetch("/api/themes", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(theme) });
        const data = await response.json(); if (!response.ok) throw Error(data.error);
        setThemes(current => [...current.filter(item => item.id !== theme.id), theme]); setError("");
      } catch (error) { setError(error instanceof Error ? error.message : "Could not import theme."); }
    }} />
    <div className="mt-2 grid grid-cols-2 gap-2">{themes.map(theme => {
      const warnings = themeWarnings(theme);
      return <button key={theme.id} aria-label={`Use theme ${theme.name}`} aria-pressed={selected === `custom:${theme.id}`} title={warnings.join("\n") || theme.name}
        onClick={() => { try { selectCustomTheme(theme); } catch { setError("Could not save the theme preference."); } }}
        className={`rounded-lg border p-2 text-left hover:bg-hover ${selected === `custom:${theme.id}` ? "border-accent" : "border-line"}`}>
        <span className="mb-1 flex h-10 items-center gap-1 rounded p-2" style={{ background: theme.colors.page, color: theme.colors.ink }}><span className="size-4 rounded-full" style={{ background: theme.colors.accent }} /><span className="rounded px-1 text-[10px]" style={{ background: theme.colors.surface }}>Aa</span></span>
        <span className="block truncate text-[11px] font-medium">{theme.name}</span>{warnings.length > 0 && <span className="text-[10px] text-orange">Check text contrast</span>}
      </button>;
    })}</div>
    {(error || issues.length > 0) && <p role="alert" className="mt-2 text-[11px] text-red">{error || issues.join(" ")}</p>}
  </section>;
}
