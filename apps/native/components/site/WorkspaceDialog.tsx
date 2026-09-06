"use client";

import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Switch } from "@/components/atoms/Switch";
import type { PromptModel } from "@/components/primitives/PromptBar";
import { browseFolders, fsReveal, type FolderListing } from "@/lib/fs-client";
import { IconCrossSmall, IconFolder } from "@/lib/icons";
import { basename, type Workspace } from "@/lib/workspaces";

/* ─────────────────────────────────────────────────────────
 * WORKSPACE DIALOG
 * The two faces of the sidebar's workspace menu. "New workspace" walks
 * the machine's folders one level at a time (or takes a typed path) and
 * hands back the folder graff should run in. "Workspace settings" edits
 * how new tabs in a workspace spawn: its name, default model and whether
 * tools are auto-approved.
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
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return createPortal(
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center p-4"
      style={{ background: "color-mix(in oklab, var(--ink) 22%, transparent)", animation: "fade-in 160ms ease both" }}
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className="flex w-full max-w-[560px] flex-col overflow-hidden rounded-[14px] bg-surface shadow-overlay"
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

function Chip({ active, onClick, children }: { active?: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`h-6 shrink-0 rounded-full px-2 text-[11.5px] font-medium transition-colors ${
        active ? "bg-hover-2 text-ink" : "bg-field text-ink-2 shadow-hairline hover:bg-hover hover:text-ink"
      }`}
    >
      {children}
    </button>
  );
}

function GitBadge() {
  return <span className="shrink-0 rounded-full bg-field px-1.5 font-mono text-[10px] text-ink-2 shadow-hairline">git</span>;
}

function FolderPicker({ startPath, onPick, onClose }: { startPath?: string; onPick: (path: string) => void; onClose: () => void }) {
  const [listing, setListing] = useState<FolderListing | null>(null);
  const [typed, setTyped] = useState(startPath ?? "~");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // Only the newest navigation may land: a slow listing of a big folder
  // must not overwrite the one the user has already moved on to.
  const seq = useRef(0);
  const pickRef = useRef(onPick);
  pickRef.current = onPick;
  const go = useCallback(async (target: string, pick = false) => {
    const n = (seq.current += 1);
    setBusy(true);
    setListing(null);
    setError(null);
    try {
      const next = await browseFolders(target);
      if (n !== seq.current) return;
      setListing(next);
      setTyped(next.path);
      setError(null);
      if (pick) pickRef.current(next.path);
    } catch (err) {
      if (n !== seq.current) return;
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      if (n === seq.current) setBusy(false);
    }
  }, []);
  useEffect(() => {
    void go(startPath ?? "~");
    return () => { seq.current++; };
  }, [go, startPath]);

  const crumbs = listing ? listing.path.split("/").filter(Boolean) : [];
  const crumbPath = (i: number) => `/${crumbs.slice(0, i + 1).join("/")}`;
  const home = listing?.home;
  const repo = listing?.default;

  return (
    <>
      <div className="flex shrink-0 flex-col gap-2 border-b border-line px-4 py-3">
        <form
          className="flex items-center gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            void go(typed);
          }}
        >
          <span className="flex size-5 shrink-0 items-center justify-center text-ink-2">
            <IconFolder size={16} />
          </span>
          <input
            value={typed}
            onChange={(event) => { seq.current++; setTyped(event.target.value); setBusy(false); setError(null); setListing(null); }}
            spellCheck={false}
            autoFocus
            aria-label="Folder path"
            placeholder="/path/to/project"
            className={`${FIELD} font-mono text-[12.5px]`}
          />
          <button
            type="submit"
            className="h-8 shrink-0 rounded-[8px] bg-hover-2 px-3 text-[12.5px] font-medium text-ink transition-colors hover:bg-line-strong"
          >
            Go
          </button>
        </form>
        <div className="flex items-center gap-1.5 text-[11.5px] text-ink-3">
          <Chip onClick={() => void go("~")} active={listing?.path === home}>
            Home
          </Chip>
          {repo && (
            <Chip onClick={() => void go(repo)} active={listing?.path === repo}>
              {basename(repo)}
            </Chip>
          )}
          <span className="ml-1 min-w-0 flex-1 truncate">Pick the folder graff should read and edit.</span>
        </div>
      </div>

      <div className="flex h-9 shrink-0 items-center gap-1 overflow-x-auto border-b border-line px-3 text-[12px] whitespace-nowrap text-ink-3 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <button type="button" onClick={() => void go("/")} className="rounded px-1 py-0.5 font-medium transition-colors hover:bg-hover hover:text-ink">
          /
        </button>
        {crumbs.map((seg, i) => (
          <span key={crumbPath(i)} className="flex items-center gap-1">
            {i > 0 && <span className="text-line-strong">/</span>}
            <button
              type="button"
              onClick={() => void go(crumbPath(i))}
              className={`rounded px-1 py-0.5 transition-colors hover:bg-hover hover:text-ink ${i === crumbs.length - 1 ? "font-medium text-ink" : ""}`}
            >
              {seg}
            </button>
          </span>
        ))}
        {listing?.git && (
          <span className="ml-1">
            <GitBadge />
          </span>
        )}
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto" style={{ minHeight: 200 }}>
        {busy && <p role="status" className="px-4 py-3 text-[12.5px] text-ink-3">Reading folder…</p>}
        {error && <p role="alert" className="px-4 py-3 text-[12.5px] text-red">{error}</p>}
        {!listing && !busy && !error && <p className="px-4 py-3 text-[12.5px] text-ink-3">Press Enter to browse, or open this folder directly.</p>}
        {listing && (
          <div className="flex flex-col px-2 py-1.5">
            {listing.parent && (
              <button
                type="button"
                onClick={() => void go(listing.parent as string)}
                className="flex h-8 items-center gap-2 rounded-[7px] px-2 text-left text-[13px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
              >
                <span className="flex size-4 shrink-0 items-center justify-center">…</span>
                <span>Up one level</span>
              </button>
            )}
            {listing.entries.map((entry) => (
              <div
                key={entry.path}
                className="group flex h-8 items-center gap-2 rounded-[7px] px-2 transition-colors duration-100 hover:bg-hover"
              >
                <button
                  type="button"
                  onClick={() => void go(entry.path)}
                  title={entry.path}
                  className="flex min-w-0 flex-1 items-center gap-2 text-left"
                >
                  <span className={`flex size-4 shrink-0 items-center justify-center ${entry.git ? "text-accent-ink" : "text-ink-3"}`}>
                    <IconFolder size={14} />
                  </span>
                  <span className="min-w-0 flex-1 truncate text-[13px] text-ink">{entry.name}</span>
                </button>
                {entry.git && <GitBadge />}
                <button
                  type="button"
                  onClick={() => onPick(entry.path)}
                  className="h-6 shrink-0 rounded-[6px] px-1.5 text-[11.5px] font-medium text-ink-3 opacity-0 transition-[opacity,background-color,color] duration-100 group-hover:opacity-100 hover:bg-hover-2 hover:text-ink focus:opacity-100"
                >
                  Use
                </button>
              </div>
            ))}
            {listing.entries.length === 0 && <p className="px-2 py-2 text-[12.5px] text-ink-3">No folders here</p>}
          </div>
        )}
      </div>

      <div className="flex shrink-0 items-center gap-2 border-t border-line px-4 py-3">
        <span className="min-w-0 flex-1 truncate font-mono text-[11.5px] text-ink-3" title={listing?.path}>
          {listing?.path ?? ""}
        </span>
        <button
          type="button"
          onClick={onClose}
          className="h-8 rounded-full px-3 text-[12.5px] font-medium text-ink-2 transition-colors hover:bg-hover hover:text-ink"
        >
          Cancel
        </button>
        <button
          type="button"
          disabled={!typed.trim() || busy}
          onClick={() => void go(typed, true)}
          className="h-8 rounded-full bg-ink px-3.5 text-[12.5px] font-medium text-canvas transition-opacity hover:opacity-90 disabled:opacity-50"
        >
          Open folder
        </button>
      </div>
    </>
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
              onClick={() => void fsReveal("", workspace.path)}
              className="h-8 shrink-0 rounded-[8px] bg-hover-2 px-2.5 text-[12px] font-medium text-ink transition-colors hover:bg-line-strong"
            >
              Reveal
            </button>
          </div>
        </Field>
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
