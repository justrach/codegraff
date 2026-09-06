"use client";
import { useEffect, useRef, useState } from "react";
import type { ReviewState, ReviewScope } from "@/lib/git-review";
function Diff({ text }: { text: string }) {
  let old = 0, next = 0;
  return <div className="min-w-max py-2 font-mono text-[11px] leading-5">{text.split("\n").slice(0, 12000).map((line, index) => {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)/.exec(line);
    if (hunk) { old = Number(hunk[1]); next = Number(hunk[2]); return <div key={index} className="sticky left-0 my-2 bg-hover px-3 text-ink-3">{line}</div>; }
    if (/^(diff --git|index |---|\+\+\+)/.test(line)) return null;
    const added = line.startsWith("+"), removed = line.startsWith("-");
    const left = added ? "" : old++, right = removed ? "" : next++;
    return <div key={index} className={`flex whitespace-pre ${added ? "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400" : removed ? "bg-red-500/10 text-red-600 dark:text-red-400" : "text-ink-2"}`}>
      <span className="w-10 shrink-0 select-none px-1 text-right text-ink-3">{left || ""}</span><span className="mr-2 w-10 shrink-0 select-none px-1 text-right text-ink-3">{right || ""}</span><span className="pr-4">{line || " "}</span>
    </div>;
  })}</div>;
}
export default function ChangesPane({ root, onClose }: { root?: string; onClose(): void }) {
  const [workspace, setWorkspace] = useState(root);
  const [scope, setScope] = useState<ReviewScope>("all");
  const [state, setState] = useState<ReviewState | null>(null);
  const [selected, setSelected] = useState("");
  const selectedRef = useRef(selected); selectedRef.current = selected;
  const [diff, setDiff] = useState("");
  const [error, setError] = useState("");
  const [history, setHistory] = useState(false);
  const [loading, setLoading] = useState(true);
  useEffect(() => { setWorkspace(root); setSelected(""); }, [root]);
  useEffect(() => {
    let stopped = false, timer: ReturnType<typeof setTimeout>;
    const refresh = async () => {
      if (document.visibilityState === "hidden") { timer = setTimeout(refresh, 5000); return; }
      try {
        const query = new URLSearchParams({ scope, ...(workspace ? { root: workspace } : {}) });
        const response = await fetch(`/api/git?${query}`, { cache: "no-store" });
        const data = await response.json(); if (!response.ok) throw Error(data.error);
        if (stopped) return; setState(data); setError("");
        const file = data.files.some((row: { path: string }) => row.path === selectedRef.current) ? selectedRef.current : data.files[0]?.path || "";
        if (file !== selectedRef.current) setSelected(file);
        if (file) {
          const reply = await fetch('/api/git', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ root: workspace, path: file, scope }) });
          const content = await reply.json(); if (!reply.ok) throw Error(content.error);
          if (!stopped && file === selectedRef.current) setDiff(content.diff);
        } else setDiff("");
      } catch (err) { if (!stopped) setError(err instanceof Error ? err.message : String(err)); }
      finally { if (!stopped) { setLoading(false); timer = setTimeout(refresh, 5000); } }
    };
    void refresh(); return () => { stopped = true; clearTimeout(timer); };
  }, [workspace, scope, selected]);
  const index = state?.files.findIndex(file => file.path === selected) ?? -1;
  return <aside aria-label="Workspace changes" className="flex w-[650px] max-w-[60%] shrink-0 flex-col overflow-hidden rounded-xl border border-line bg-page">
    <header className="flex h-11 items-center gap-2 border-b border-line px-3"><strong className="flex-1 text-sm">Changes <span className="font-normal text-ink-3">· {state?.branch ?? "Git"}</span></strong><span className="text-[10px] text-emerald-600">Live · 5s</span><button aria-label="Close changes" onClick={onClose}>×</button></header>
    <div className="flex items-center gap-2 border-b border-line p-2 text-xs">
      <select aria-label="Review worktree" value={workspace ?? state?.root ?? ""} onChange={e => { setWorkspace(e.target.value); setSelected(""); }} className="min-w-0 flex-1 rounded bg-field p-1">
        {(state?.worktrees.length ? state.worktrees : [{ path: workspace ?? "", branch: "Current workspace" }]).map(tree => <option key={tree.path} value={tree.path}>{tree.branch} · {tree.path.split('/').pop()}</option>)}
      </select>
      <select aria-label="Changes scope" value={scope} onChange={e => setScope(e.target.value as ReviewScope)} className="rounded bg-field p-1"><option value="all">All changes</option><option value="staged">Staged</option><option value="unstaged">Unstaged</option></select>
      <button aria-pressed={history} onClick={() => setHistory(!history)} className="rounded px-2 py-1 hover:bg-hover">History</button>
    </div>
    <p className="border-b border-line px-3 py-2 text-[11px] text-ink-3">Shared working tree · edits from you and every agent. <span className="text-emerald-600">+{state?.totalAdd ?? 0}</span> <span className="text-red-500">−{state?.totalDel ?? 0}</span></p>
    {error && <p role="alert" className="p-3 text-xs text-red-500">{error}</p>}
    {history && <div className="max-h-44 overflow-auto border-b border-line p-2">{state?.commits.map(commit => <div key={commit.hash} className="flex gap-2 py-1 text-xs"><code className="text-ink-3">{commit.hash}</code><span className="min-w-0 flex-1 truncate">{commit.subject}</span><span className="text-ink-3">{commit.author}</span></div>)}</div>}
    <div className="flex min-h-0 flex-1">
      <nav aria-label="Changed files" className="w-44 shrink-0 overflow-auto border-r border-line p-1">{state?.files.map(file => <button key={file.path} onClick={() => { setSelected(file.path); setDiff(""); }} title={file.path}
        className={`flex w-full items-center gap-1 rounded px-2 py-2 text-left text-xs ${file.path === selected ? "bg-hover" : "hover:bg-hover"}`}><span className="text-ink-3">{file.untracked ? "+" : file.status.trim()}</span><span className="min-w-0 flex-1 truncate">{file.path}</span></button>)}</nav>
      <section className="flex min-w-0 flex-1 flex-col"><div className="flex h-9 shrink-0 items-center gap-2 border-b border-line px-2 text-xs"><span className="min-w-0 flex-1 truncate" title={selected}>{selected || (loading ? "Loading…" : "Working tree is clean")}</span>
        <button aria-label="Previous changed file" disabled={index <= 0} onClick={() => setSelected(state!.files[index - 1].path)}>↑</button><button aria-label="Next changed file" disabled={!state || index >= state.files.length - 1} onClick={() => setSelected(state!.files[index + 1].path)}>↓</button></div>
        <div className="min-h-0 flex-1 overflow-auto">{diff ? <Diff text={diff} /> : <p className="p-4 text-xs text-ink-3">{selected ? "Loading diff, or no text diff available." : "Changes appear here as files are edited."}</p>}</div>
      </section>
    </div>
  </aside>;
}
