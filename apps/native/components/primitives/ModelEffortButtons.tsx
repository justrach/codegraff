"use client";
import { useEffect, useRef, useState, type RefObject } from "react";
import { createPortal } from "react-dom";
import type { ModelChoice } from "@/lib/acp-client";
import styles from "./EffortPicker.module.css";
const labels: Record<string, string> = { low: "Light", medium: "Medium", high: "High", xhigh: "Extra high", max: "Max", ultra: "Ultra" };
function Bolt({ filled = false }: { filled?: boolean }) {
  return <svg aria-hidden="true" width="20" height="20" viewBox="0 0 24 24" fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="m13.3 2-9 12h7L10.7 22l9-12h-7L13.3 2Z" /></svg>;
}
function Chevron() {
  return <svg aria-hidden="true" width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="m4 6 4 4 4-4" /></svg>;
}
export default function ModelEffortButtons({ model, buttonRef, modelOpen, openModel, wide, pill, onCommand, busy }: {
  model: ModelChoice; buttonRef: RefObject<HTMLButtonElement | null>; modelOpen: boolean; openModel(): void;
  wide: boolean; pill: boolean; onCommand?: (text: string) => Promise<void>; busy?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const savingRef = useRef(false);
  const blocked = busy || saving || !onCommand;
  const [position, setPosition] = useState({ left: 0, bottom: 0 });
  const [draft, setDraft] = useState(0);
  const panel = useRef<HTMLDivElement>(null);
  const effortButton = useRef<HTMLButtonElement>(null);
  const levels = model.effortLevels ?? [];
  const index = Math.max(0, levels.indexOf(model.effort ?? "medium"));
  const show = () => {
    const rect = effortButton.current?.getBoundingClientRect();
    if (rect) setPosition({ left: Math.max(12, Math.min(window.innerWidth - 332, rect.right - 320)), bottom: window.innerHeight - rect.top + 10 });
    if (modelOpen) openModel();
    setDraft(index); setOpen(true);
  };
  useEffect(() => { setDraft(index); }, [index]);
  useEffect(() => {
    const button = buttonRef.current;
    const listener = () => show(); button?.addEventListener("graff-effort-open", listener);
    return () => button?.removeEventListener("graff-effort-open", listener);
  });
  useEffect(() => {
    if (!open) return;
    const dismiss = (event: PointerEvent) => { if (!panel.current?.contains(event.target as Node)) setOpen(false); };
    const escape = (event: KeyboardEvent) => { if (event.key === "Escape") { setOpen(false); buttonRef.current?.focus(); } };
    document.addEventListener("pointerdown", dismiss); document.addEventListener("keydown", escape);
    return () => { document.removeEventListener("pointerdown", dismiss); document.removeEventListener("keydown", escape); };
  }, [open, buttonRef]);
  const change = async (command: string) => {
    if (blocked || savingRef.current || !onCommand) return;
    savingRef.current = true; setSaving(true); setError("");
    try { await onCommand(command); }
    catch (err) { setDraft(index); setError(err instanceof Error ? err.message : "Could not save. Try again."); }
    finally { savingRef.current = false; setSaving(false); }
  };
  const apply = () => { if (levels[draft] && levels[draft] !== model.effort) void change(`/effort ${levels[draft]}`); };
  const progress = levels.length > 1 ? draft / (levels.length - 1) : 0;
  const displayName = model.name.replace(/^gpt-/i, "GPT-").replace(/-(astra|sol|terra|luna)$/i, (_, name: string) => ` ${name[0].toUpperCase()}${name.slice(1)}`);
  return <div data-model-controls className={`flex w-full min-w-0 items-center gap-0.5 ${wide ? "col-start-2 row-start-2 justify-self-start" : "col-start-3 row-start-1"}`}>
    <button ref={buttonRef} type="button" aria-expanded={modelOpen} aria-label="Choose model" disabled={saving || busy} onClick={openModel}
      className={`flex h-7 min-w-0 items-center gap-1 px-1.5 text-[12px] font-medium text-ink-2 hover:bg-hover hover:text-ink ${pill ? "rounded-full" : "rounded-lg"}`}>
      {model.fast && model.fastSupported && <span className="text-accent [&_svg]:size-3.5" aria-label="Fast mode enabled"><Bolt filled /></span>}
      <span className="truncate" title={displayName}>{displayName}</span><span className="shrink-0"><Chevron /></span>
    </button>
    {levels.length > 0 && <button ref={effortButton} type="button" aria-label="Select effort" aria-expanded={open} onClick={show}
      className="flex h-7 shrink-0 items-center gap-1.5 rounded-full px-2 text-xs text-ink-3 hover:bg-hover">{labels[model.effort ?? ""] ?? "Effort"}<Chevron /></button>}
    {open && createPortal(<div ref={panel} role="dialog" aria-label="Reasoning effort" style={position}
      className="fixed z-[100] w-80 max-w-[calc(100vw-24px)] rounded-[22px] border border-line bg-page px-4 pb-4 pt-3 text-ink shadow-[0_8px_24px_-8px_rgb(0_0_0/18%)]">
      <div className="flex items-center justify-between gap-3">
        <button type="button" aria-label="Fast mode" aria-pressed={!!model.fast} disabled={blocked || !model.fastSupported}
          title={model.fastSupported ? "Priority service for lower latency; may use more of your allowance" : "Fast mode is available for Codex models"}
          onClick={() => void change(`/fast ${model.fast ? "off" : "on"}`)}
          className={`flex size-8 shrink-0 items-center justify-center rounded-[10px] transition-colors disabled:opacity-30 ${model.fast ? "bg-accent-tint text-accent" : "text-ink-3 hover:bg-hover"}`}><Bolt filled={!!model.fast} /></button>
        <div className="min-w-0 text-center"><div className="text-[17px] font-medium leading-6 text-accent">{labels[levels[draft]] ?? levels[draft]}</div><div className="mt-0.5 truncate text-[13px] leading-5 text-ink-3">{saving ? <span role="status">Saving…</span> : displayName}</div></div>
        <button type="button" aria-label="Reset effort to medium" title="Reset effort to medium" disabled={blocked || !levels.includes("medium")} onClick={() => { setDraft(levels.indexOf("medium")); void change("/effort medium"); }} className="flex size-8 shrink-0 items-center justify-center rounded-lg text-ink-3 hover:bg-hover disabled:opacity-30"><svg aria-hidden="true" width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M4 10a8 8 0 1 1 0 5M4 4v6h6" /></svg></button>
      </div>
      <div className={styles.slider}>
        <div aria-hidden="true" className={styles.track}><div className={styles.fill} style={{ width: draft === 0 ? 0 : `calc(20px + (100% - 40px) * ${progress})` }} /></div>
        <div aria-hidden="true" className={styles.stops}>{levels.map((level, i) => <span key={level} className={`${styles.stop} ${i < draft ? styles.passed : ""}`} style={{ left: `${i / Math.max(1, levels.length - 1) * 100}%` }} />)}</div>
        <input type="range" aria-label="Reasoning effort level" aria-valuetext={labels[levels[draft]] ?? levels[draft]} min={0} max={Math.max(0, levels.length - 1)} step={1} value={draft} disabled={blocked}
        onChange={event => setDraft(Number(event.target.value))} onPointerUp={apply} onKeyUp={apply}
        className={styles.range} />
      </div>
      {error && <p role="alert" className="mt-2 text-xs text-red">{error}</p>}
    </div>, document.body)}
  </div>;
}
