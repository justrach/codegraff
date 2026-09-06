"use client";
import { useEffect, useRef, useState } from "react";
import type { ReviewState, ReviewScope } from "@/lib/git-review";
import ReviewActions from "./ReviewActions";
import ReviewDiff from "./ReviewDiff";
import { reviewLines } from "@/lib/review-lines";
import styles from "./ChangesPane.module.css";
import ResizableReviewPane from "./ResizableReviewPane";
function Icon({ kind }: { kind: "close" | "files" | "up" | "down" | "history" | "refresh" }) {
  const paths = { close: "M6 6l12 12M6 18 18 6", files: "M8 6h12M8 12h12M8 18h12M3 6h.01M3 12h.01M3 18h.01", up: "m6 14 6-6 6 6", down: "m6 10 6 6 6-6", history: "M3 10a9 9 0 1 1 1 7M3 4v6h6M12 7v5l3 2", refresh: "M4 10a8 8 0 1 1 0 5M4 4v6h6" };
  return <svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d={paths[kind]} /></svg>;
}
const button = "flex size-7 shrink-0 items-center justify-center rounded-md text-ink-3 hover:bg-hover hover:text-ink disabled:opacity-30";
export default function ChangesPane({ root, onClose }: { root?: string; onClose(): void }) {
  const [workspace, setWorkspace] = useState(root);
  const [scope, setScope] = useState<ReviewScope>("all");
  const [state, setState] = useState<ReviewState | null>(null);
  const [selected, setSelected] = useState("");
  const selectedRef = useRef(selected); selectedRef.current = selected;
  const [diff, setDiff] = useState("");
  const [error, setError] = useState("");
  const [history, setHistory] = useState(false);
  const [showFiles, setShowFiles] = useState(false);
  const viewport = useRef<HTMLElement>(null);
  const [filter, setFilter] = useState("");
  const [wrap, setWrap] = useState(true);
  const [revision, setRevision] = useState(0);
  const [loading, setLoading] = useState(true);
  const identity = useRef("");
  useEffect(() => { setWorkspace(root); setSelected(""); }, [root]);
  useEffect(() => {
    setLoading(true);
    setDiff(""); setError("");
    const nextIdentity = JSON.stringify([workspace, scope]);
    if (identity.current !== nextIdentity) { identity.current = nextIdentity; setState(null); }
    let stopped = false, timer: ReturnType<typeof setTimeout>;
    const refresh = async () => {
      if (document.visibilityState === "hidden") { timer = setTimeout(refresh, 5000); return; }
      let listed = false;
      try {
        const query = new URLSearchParams({ scope, ...(workspace ? { root: workspace } : {}) });
        const response = await fetch(`/api/git?${query}`, { cache: "no-store" });
        const data = await response.json(); if (!response.ok) throw Error(data.error || `Could not load changes (${response.status}).`);
        if (stopped) return; setState(data); setError(""); listed = true;
        const file = data.files.some((row: { path: string }) => row.path === selectedRef.current) ? selectedRef.current : data.files[0]?.path || "";
        if (file !== selectedRef.current) setSelected(file);
        if (file) {
          const reply = await fetch('/api/git', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ root: workspace, path: file, scope }) });
          const content = await reply.json(); if (!reply.ok) throw Error(content.error || `Could not load the diff (${reply.status}).`);
          if (!stopped && file === selectedRef.current) setDiff(content.diff);
        } else setDiff("");
      } catch (err) { if (!stopped) { setError(err instanceof Error ? err.message : String(err)); setDiff(""); if (!listed) setState(null); } }
      finally { if (!stopped) { setLoading(false); timer = setTimeout(refresh, 5000); } }
    };
    void refresh(); return () => { stopped = true; clearTimeout(timer); };
  }, [workspace, scope, selected, revision]);
  const files = state?.files ?? [];
  const filteredFiles = files.filter(file => file.path.toLowerCase().includes(filter.toLowerCase()));
  const index = files.findIndex(file => file.path === selected);
  const file = files[index];
  const rows = reviewLines(diff);
  const added = rows.filter(row => row.kind === "add").length;
  const removed = rows.filter(row => row.kind === "remove").length;
  const newFiles = files.filter(file => file.untracked).length;
  const choose = (path: string) => { setSelected(path); setDiff(""); };
  return <ResizableReviewPane><aside aria-label="Workspace changes" className={`${styles.panel} flex min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page`}>
    <header className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-3">
      <strong className="text-[13px] font-medium">Changes</strong>
      <span className="rounded-md bg-hover px-1.5 py-0.5 text-[10px] tabular-nums text-ink-3">{files.length}</span>
      <div className="min-w-0 flex-1 truncate pl-1 text-[11px] text-ink-3" title={state?.branch}>{state?.branch}</div>
      <span className={`size-1.5 shrink-0 rounded-full ${error ? "bg-orange" : "bg-green/70"}`} title={error ? "Updates unavailable; retrying every five seconds" : "Refreshes every five seconds while visible"} aria-label={error ? "Updates unavailable" : "Live updates"} />
      <button className={button} title="Refresh changes" aria-label="Refresh changes" onClick={() => setRevision(value => value + 1)}><Icon kind="refresh" /></button>
      <button className={button} title="Close changes" aria-label="Close changes" onClick={onClose}><Icon kind="close" /></button>
    </header>
    {state && state.worktrees.length > 1 && <div className="border-b border-line px-3 py-2"><select aria-label="Review worktree" value={workspace ?? state.root} onChange={e => { setWorkspace(e.target.value); choose(""); }} className="w-full rounded-md bg-field px-2 py-1 text-xs">{state.worktrees.map(tree => <option key={tree.path} value={tree.path}>{tree.branch} · {tree.path.split('/').pop()}</option>)}</select></div>}
    <div className="flex shrink-0 items-center gap-2 border-b border-line px-3 py-2">
      <div role="group" aria-label="Changes scope" className="flex rounded-lg bg-hover/60 p-0.5">{(["all", "staged", "unstaged"] as const).map(value => <button key={value} aria-pressed={scope === value} onClick={() => { setScope(value); choose(""); }} className={`rounded-md px-2.5 py-1 text-[11px] transition-colors ${scope === value ? "bg-page text-ink shadow-sm" : "text-ink-3 hover:text-ink"}`}>{value === "all" ? "All" : value === "staged" ? "Staged" : "Unstaged"}</button>)}</div>
      <div className="flex min-w-0 flex-1 items-center justify-end gap-1.5 text-[10px] tabular-nums">
        {!!state?.totalAdd && <span title="Added lines in tracked files" className="text-green">+{state.totalAdd}</span>}
        {!!state?.totalDel && <span title="Removed lines in tracked files" className="text-red">−{state.totalDel}</span>}
        {!!newFiles && <span className="whitespace-nowrap text-ink-3">{newFiles} new</span>}
      </div>
      <button aria-label="Show recent commits" title="Recent commits" aria-pressed={history} onClick={() => setHistory(!history)} className={`${button} ${history ? "bg-hover text-ink" : ""}`}><Icon kind="history" /></button>
    </div>
    {error && <p role="alert" className="border-b border-line px-3 py-2 text-xs text-red">{error}<button type="button" onClick={() => setRevision(value => value + 1)} className="ml-2 rounded px-2 py-1 underline">Retry</button></p>}
    {history && <div className="max-h-44 shrink-0 overflow-auto border-b border-line px-3 py-2">{state?.commits.length ? state.commits.map(commit => <div key={commit.hash} className="py-1.5 text-xs"><div className="truncate text-ink-2" title={commit.subject}>{commit.subject}</div><div className="mt-0.5 text-[10px] text-ink-3"><code>{commit.hash}</code> · {commit.author}</div></div>) : <p className="py-2 text-xs text-ink-3">No commits yet.</p>}</div>}
    {files.length > 0 && <div className="flex h-11 shrink-0 items-center gap-1.5 border-b border-line px-2">
      <button className={`${button} ${showFiles ? "bg-hover" : ""}`} title="Toggle file list" aria-label="Toggle changed file list" aria-pressed={showFiles} onClick={() => setShowFiles(!showFiles)}><Icon kind="files" /></button>
      <select aria-label="Changed file" title={selected} value={selected} onChange={e => choose(e.target.value)} className="min-w-0 flex-1 truncate rounded-md bg-transparent py-1 text-xs text-ink-2">{files.map(file => <option key={file.path} value={file.path}>{file.path}</option>)}</select>
      {file?.untracked && <span className="rounded bg-hover px-1.5 py-0.5 text-[9px] text-ink-3">NEW</span>}
      {!!added && <span className="text-[10px] tabular-nums text-green">+{added}</span>}{!!removed && <span className="text-[10px] tabular-nums text-red">−{removed}</span>}
      <button aria-label="Wrap long lines" aria-pressed={wrap} title="Wrap long lines" onClick={() => setWrap(!wrap)} className={`rounded px-1.5 py-1 text-[10px] ${wrap ? "bg-hover text-ink-2" : "text-ink-3"}`}>Wrap</button>
      <button className={button} aria-label="Previous changed file" disabled={index <= 0} onClick={() => choose(files[index - 1].path)}><Icon kind="up" /></button>
      <button className={button} aria-label="Next changed file" disabled={index >= files.length - 1} onClick={() => choose(files[index + 1].path)}><Icon kind="down" /></button>
    </div>}
    <div className={styles.body}>
      {showFiles && files.length > 0 && <nav aria-label="Changed files" className={styles.files}><input aria-label="Filter changed files" placeholder="Find a file…" value={filter} onChange={event => setFilter(event.target.value)} className="mb-2 w-full rounded-md border border-line bg-field px-2 py-1.5 text-xs outline-accent" />{!filteredFiles.length && <p className="px-2 py-3 text-xs text-ink-3">No matching files.</p>}{filteredFiles.map(file => <button key={file.path} onClick={() => choose(file.path)} title={file.path} className={`mb-0.5 flex w-full items-center gap-2 rounded-md px-2 py-2 text-left text-xs ${file.path === selected ? "bg-hover text-ink" : "text-ink-3 hover:bg-hover"}`}><span className="min-w-0 flex-1"><span className="block truncate">{file.path.split('/').pop()}</span>{file.path.includes("/") && <span className="mt-0.5 block truncate font-mono text-[9px] text-ink-3">{file.path.slice(0, file.path.lastIndexOf("/"))}</span>}</span><span className="text-[9px]">{file.untracked ? "NEW" : file.status.trim()}</span></button>)}</nav>}
      <section ref={viewport} aria-label="File diff" aria-busy={loading} className="min-h-0 min-w-0 flex-1 overflow-auto">
        {rows.length ? <ReviewDiff rows={rows} wrap={wrap} /> : <div className="flex min-h-40 h-full flex-col items-center justify-center gap-2 px-8 text-center"><span className="text-sm text-ink-2">{loading ? "Loading changes…" : error ? "Changes unavailable" : selected ? "No text changes to display" : "Working tree is clean"}</span><p className="max-w-60 text-xs leading-relaxed text-ink-3">{loading ? "" : error ? "Retry to read this folder’s current changes." : selected ? "Binary files and metadata-only changes have no line diff." : "Edits in this workspace will appear here automatically."}</p></div>}
      </section>
    </div>
    {file && !error && !loading && <ReviewActions diff={diff} path={selected} root={workspace} viewport={viewport} count={rows.slice(0, 12000).filter(row => row.kind === "hunk").length} />}
  </aside></ResizableReviewPane>;
}
