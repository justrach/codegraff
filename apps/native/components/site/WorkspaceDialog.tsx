"use client";

import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Switch } from "@/components/atoms/Switch";
import type { PromptModel } from "@/components/primitives/PromptBar";
import { FolderPicker } from "@/components/site/FolderPicker";
import { fsReveal } from "@/lib/fs-client";
import { IconCrossSmall } from "@/lib/icons";
import { basename, type Workspace } from "@/lib/workspaces";

/* ─────────────────────────────────────────────────────────
 * WORKSPACE DIALOG
 * The two faces of the sidebar's workspace menu. "New workspace" walks
 * the machine's folders one level at a time (typed paths stay listed and
 * fuzzy-ranked like /model; Name / Modified / Git chips reorder or hide
 * the list; New folder creates one in place) and hands back the folder
 * graff should run in. "Workspace settings" edits how new tabs in a
 * workspace spawn: its name, default model and whether tools are auto-approved.
 * ───────────────────────────────────────────────────────── */

type Props = {
  mode: "new" | "settings";
  /** The workspace being edited (settings). */
  workspace?: Workspace;
  /** Where the folder picker opens (new). */
  startPath?: string;
  models: PromptModel[];
  onClose: () => void;
  onPick: (path: string) => void;
  onSave: (ws: Workspace) => void;
  onForget: (path: string) => void;
};

const FIELD =
  "h-8 w-full rounded-[8px] bg-field px-2.5 text-[13px] text-ink shadow-hairline outline-none placeholder:text-ink-3 focus:bg-hover";

function Frame({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const panel = useRef<HTMLDivElement>(null);
  // Capture before the child input's autoFocus runs during the commit.
  const previous = useRef(document.activeElement as HTMLElement | null);
  const close = useRef(onClose);
  close.current = onClose;
  useLayoutEffect(() => {
    const dialog = panel.current!;
    // The portal is a direct body child. Inert background roots prevent
    // native or programmatic focus from reaching the chat behind the modal.
    const background = Array.from(document.body.children)
      .filter((element): element is HTMLElement => element instanceof HTMLElement && !element.contains(dialog))
      .map(element => ({ element, inert: element.inert }));
    background.forEach(({ element }) => { element.inert = true; });
    const controls = () => Array.from(dialog.querySelectorAll<HTMLElement>("button, a[href], input, select, textarea, [tabindex]"))
      .filter(element => element.tabIndex >= 0 && !element.matches(":disabled") && !element.closest("[inert], [hidden]") && element.getClientRects().length > 0 && getComputedStyle(element).visibility === "visible");
    const focusInside = (preferred?: HTMLElement) => {
      const items = controls();
      (preferred && items.includes(preferred) ? preferred : items[0] ?? dialog).focus({ preventScroll: true });
      // A control may have become unavailable since it last held focus.
      if (!dialog.contains(document.activeElement)) dialog.focus({ preventScroll: true });
    };
    if (!dialog.contains(document.activeElement)) focusInside();
    let lastFocused = document.activeElement as HTMLElement;
    const keepFocus = (event: FocusEvent) => {
      if (dialog.contains(event.target as Node)) lastFocused = event.target as HTMLElement;
      else { event.stopPropagation(); focusInside(lastFocused); }
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.isComposing) return;
      if (event.key === "Escape") {
        event.preventDefault(); event.stopPropagation(); close.current();
      } else if (event.key === "Tab") {
        const items = controls(), first = items[0], last = items.at(-1);
        if (!first || !items.includes(document.activeElement as HTMLElement) || (event.shiftKey ? document.activeElement === first : document.activeElement === last)) {
          event.preventDefault();
          (event.shiftKey ? last ?? dialog : first ?? dialog).focus({ preventScroll: true });
        }
      }
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("focusin", keepFocus, true);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("focusin", keepFocus, true);
      background.forEach(({ element, inert }) => { element.inert = inert; });
      // The switcher search which opened settings has already unmounted.
      const target = previous.current?.isConnected ? previous.current : document.querySelector<HTMLElement>("[data-workspace-trigger]");
      target?.focus({ preventScroll: true });
    };
  }, []);
  return createPortal(
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center p-4"
      style={{ background: "color-mix(in oklab, var(--ink) 22%, transparent)", animation: "fade-in 160ms ease both" }}
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div
        ref={panel}
        role="dialog"
        tabIndex={-1}
        aria-modal="true"
        aria-label={title}
        className="flex w-full max-w-[560px] flex-col overflow-hidden rounded-window bg-surface shadow-overlay"
        style={{ maxHeight: "min(680px, calc(100dvh - 32px))", animation: "pop-in 180ms cubic-bezier(0.23,1,0.32,1) both" }}
      >
        <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-4">
          <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-ink">{title}</span>
          <button
            type="button"
            aria-label="Close"
            onClick={onClose}
            className="flex size-7 items-center justify-center rounded-[6px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
          >
            <IconCrossSmall size={16} />
          </button>
        </div>
        {children}
      </div>
    </div>,
    document.body,
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-1.5">
      <span className="text-[12.5px] font-medium text-ink">{label}</span>
      {children}
      {hint && <span className="text-[11.5px] text-ink-3">{hint}</span>}
    </label>
  );
}

function SettingsForm({
  workspace,
  models,
  onSave,
  onForget,
  onClose,
}: {
  workspace: Workspace;
  models: PromptModel[];
  onSave: (ws: Workspace) => void;
  onForget: (path: string) => void;
  onClose: () => void;
}) {
  const [name, setName] = useState(workspace.name);
  const [model, setModel] = useState(workspace.model ?? "");
  const [yolo, setYolo] = useState(workspace.yolo ?? true);
  const [mcp, setMcp] = useState(workspace.mcp ?? true);
  const [confirmForget, setConfirmForget] = useState(false);
  const [revealError, setRevealError] = useState<string | null>(null);
  const save = () => onSave({ ...workspace, name: name.trim() || basename(workspace.path), model: model || undefined, yolo, mcp });

  return (
    <>
      <form
        className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4 py-4"
        onSubmit={(event) => {
          event.preventDefault();
          save();
        }}
      >
        <Field label="Name" hint="How the switcher and the tab bar label this folder.">
          <input value={name} onChange={(event) => setName(event.target.value)} autoFocus className={FIELD} />
        </Field>
        <Field label="Folder" hint="graff's working directory. Sessions save to .graff/sessions inside it.">
          <div className="flex items-center gap-2">
            <span className="min-w-0 flex-1 truncate rounded-[8px] bg-inset px-2.5 py-1.5 font-mono text-[12px] text-ink-2 shadow-hairline" title={workspace.path}>
              {workspace.path}
            </span>
            <button
              type="button"
              onClick={() => {
                setRevealError(null);
                void fsReveal("", workspace.path).catch(error => setRevealError(error instanceof Error ? error.message : "Could not reveal this folder."));
              }}
              className="h-8 shrink-0 rounded-[8px] bg-hover-2 px-2.5 text-[12px] font-medium text-ink transition-colors hover:bg-line-strong"
            >
              Reveal
            </button>
          </div>
        </Field>
        {revealError && <p role="alert" className="text-[12px] text-red">{revealError}</p>}
        <Field label="Default model" hint="What a new tab here spawns with. The composer's picker still changes it per tab.">
          <select value={model} onChange={(event) => setModel(event.target.value)} className={FIELD}>
            <option value="">Harness default</option>
            {models.map((m) => (
              <option key={m.key} value={m.key}>
                {m.name}
                {m.tag ? ` · ${m.tag}` : ""}
              </option>
            ))}
          </select>
        </Field>
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <div className="text-[12.5px] font-medium text-ink">Auto-approve tools</div>
            <div className="mt-1 text-[11.5px] text-ink-3">
              Runs <span className="font-mono text-ink-2">graff acp --yolo</span>: tools execute without asking. Off, tools are denied — the
              native app has no approval prompt yet.
            </div>
          </div>
          <Switch checked={yolo} onChange={setYolo} label="Auto-approve tools" />
        </div>
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <div className="text-[12.5px] font-medium text-ink">Start MCP servers</div>
            <div className="mt-1 text-[11.5px] text-ink-3">
              Each chat's agent starts every MCP server in <span className="font-mono text-ink-2">~/.codegraff/mcp.json</span>, which can
              cost a gigabyte or more per tab. Off, the agent has its built-in tools only.
            </div>
          </div>
          <Switch checked={mcp} onChange={setMcp} label="Start MCP servers" />
        </div>
        <p className="text-[11.5px] text-ink-3">Changes apply to new tabs. A running tab keeps the agent it spawned with.</p>
      </form>

      <div className="flex shrink-0 items-center gap-2 border-t border-line px-4 py-3">
        {confirmForget ? (
          <>
            <span className="min-w-0 truncate text-[12px] text-ink-2">Remove it from the switcher? Nothing on disk changes.</span>
            <button
              type="button"
              onClick={() => onForget(workspace.path)}
              className="h-8 shrink-0 rounded-full px-3 text-[12.5px] font-medium text-red transition-colors hover:bg-hover"
            >
              Forget
            </button>
            <button
              type="button"
              onClick={() => setConfirmForget(false)}
              className="h-8 shrink-0 rounded-full px-3 text-[12.5px] font-medium text-ink-2 transition-colors hover:bg-hover hover:text-ink"
            >
              Keep
            </button>
          </>
        ) : (
          <button
            type="button"
            onClick={() => setConfirmForget(true)}
            className="h-8 rounded-full px-3 text-[12.5px] font-medium text-red transition-colors hover:bg-hover"
          >
            Forget workspace
          </button>
        )}
        <span className="flex-1" />
        <button
          type="button"
          onClick={onClose}
          className="h-8 rounded-full px-3 text-[12.5px] font-medium text-ink-2 transition-colors hover:bg-hover hover:text-ink"
        >
          Cancel
        </button>
        <button
          type="button"
          onClick={save}
          className="h-8 rounded-full bg-ink px-3.5 text-[12.5px] font-medium text-canvas transition-opacity hover:opacity-90"
        >
          Save
        </button>
      </div>
    </>
  );
}

export default function WorkspaceDialog({ mode, workspace, startPath, models, onClose, onPick, onSave, onForget }: Props) {
  if (mode === "settings" && workspace) {
    return (
      <Frame title={`Workspace settings · ${workspace.name}`} onClose={onClose}>
        <SettingsForm workspace={workspace} models={models} onSave={onSave} onForget={onForget} onClose={onClose} />
      </Frame>
    );
  }
  return (
    <Frame title="Open a folder" onClose={onClose}>
      <FolderPicker startPath={startPath} onPick={onPick} onClose={onClose} />
    </Frame>
  );
}
