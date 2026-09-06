"use client";
import { useState } from "react";
import { IconFolder, IconPlusMedium } from "@/lib/icons";
import type { Workspace } from "@/lib/workspaces";

export default function ProjectsPane({ workspaces, current, onOpen, onContinue, onNewChat, onClose }: {
  workspaces: Workspace[]; current: string | null; onOpen: () => void;
  onContinue: (path: string) => void; onNewChat: (path: string) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const shown = workspaces.filter(w => `${w.name} ${w.path}`.toLowerCase().includes(query.toLowerCase()));
  return <section aria-label="Projects" className="flex min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page">
    <header className="flex flex-wrap items-center justify-between gap-3 border-b border-line px-6 py-5">
      <div><h1 className="text-xl font-semibold text-ink">Projects</h1><p className="mt-1 text-sm text-ink-3">A project is a folder on your Mac. Your files stay there.</p></div>
      <div className="flex flex-wrap items-center gap-3"><button type="button" onClick={onClose} className="rounded-control px-2 py-2 text-sm text-ink-2 hover:bg-hover">Back to chat</button><button type="button" onClick={onOpen} className="flex items-center gap-2 rounded-control bg-ink px-4 py-2 text-sm text-page"><IconPlusMedium size={16} />Open folder…</button></div>
    </header>
    <div className="min-h-0 overflow-y-auto p-6">
      <input aria-label="Search projects" placeholder="Find a project by name or folder…" value={query} onChange={e => setQuery(e.target.value)} className="mb-5 h-10 w-full rounded-control border border-line bg-field px-3 text-sm text-ink" />
      <div className="grid gap-3 xl:grid-cols-2">
        {shown.map(w => <article key={w.path} data-project-path={w.path} className="min-w-0 rounded-[14px] border border-line bg-surface p-4">
          <div className="flex items-center gap-2 text-ink"><IconFolder size={19} /><h2 className="min-w-0 flex-1 truncate font-medium">{w.name}</h2>{w.path === current && <span className="text-xs text-accent">Current</span>}</div>
          <p className="my-3 break-all font-mono text-xs text-ink-3">{w.path}</p>
          <div className="flex flex-wrap gap-2">
            <button type="button" onClick={() => onContinue(w.path)} className="rounded-control bg-hover-2 px-3 py-2 text-sm text-ink">Continue conversation</button>
            <button type="button" onClick={() => onNewChat(w.path)} className="rounded-control px-3 py-2 text-sm text-ink-2 hover:bg-hover">New chat</button>
          </div>
        </article>)}
      </div>
      {!shown.length && <p className="py-8 text-center text-sm text-ink-3">{query ? "No projects match this search." : "Open a folder to start your first project."}</p>}
    </div>
  </section>;
}
