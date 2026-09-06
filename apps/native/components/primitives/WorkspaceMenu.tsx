'use client';
import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { monogram } from '@/lib/workspaces';
type Row={path:string;name:string};
export default function WorkspaceMenu({position,current,rows,onSwitch,onNew,onSettings,onClose}:{
  position:{top:number;left:number};current?:string;rows:Row[];onSwitch?:(path:string)=>void;onNew?:()=>void;onSettings?:()=>void;onClose:()=>void;
}) {
  const [query,setQuery]=useState('');const input=useRef<HTMLInputElement>(null);const menu=useRef<HTMLDivElement>(null);
  const close=useRef(onClose);close.current=onClose;
  useEffect(()=>{const previous=document.activeElement as HTMLElement|null;input.current?.focus();const escape=(e:KeyboardEvent)=>{if(e.key==='Escape'){e.preventDefault();close.current();}};window.addEventListener('keydown',escape);return()=>{window.removeEventListener('keydown',escape);previous?.focus();};},[]);
  const list=rows.filter(row=>`${row.name} ${row.path}`.toLowerCase().includes(query.toLowerCase())).sort((a,b)=>Number(b.path===current)-Number(a.path===current)||a.name.localeCompare(b.name));
  const pick=(action?:()=>void)=>()=>{onClose();action?.();};
  const top=Math.min(position.top,Math.max(12,window.innerHeight-180));
  return createPortal(<div ref={menu} data-workspace-menu role="dialog" aria-label="Switch workspace"
    className="fixed z-50 flex flex-col overflow-hidden rounded-[14px] border border-line bg-surface shadow-overlay"
    style={{top,left:Math.max(12,Math.min(position.left,window.innerWidth-372)),width:'min(360px, calc(100vw - 24px))',maxHeight:`calc(100dvh - ${top+12}px)`}}
    onKeyDown={e=>{
      if(e.key==='ArrowDown'||e.key==='ArrowUp'){
        e.preventDefault();const buttons=[...menu.current!.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')];const index=buttons.indexOf(document.activeElement as HTMLButtonElement);buttons[(index+(e.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length]?.focus();
      } else if(e.key==='Enter'&&e.target===input.current){e.preventDefault();if(list[0])pick(()=>onSwitch?.(list[0].path))();}
    }}>
    <div className="shrink-0 border-b border-line p-2"><input ref={input} aria-label="Search workspaces" placeholder="Search by name or folder…" value={query} onChange={e=>setQuery(e.target.value)} className="h-9 w-full rounded-lg bg-field px-3 text-sm text-ink outline-none focus:ring-1 focus:ring-accent"/></div>
    <div className="min-h-0 max-h-80 overflow-y-auto overscroll-contain p-1.5" aria-label="Workspaces">
      {list.map(row=><button type="button" key={row.path} aria-current={row.path===current?'true':undefined} title={row.path} onClick={pick(()=>onSwitch?.(row.path))}
        className="flex w-full items-center gap-2 rounded-lg px-2 py-2 text-left hover:bg-hover focus-visible:bg-hover focus-visible:outline-none">
        <span aria-hidden className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-field text-xs text-ink-2">{monogram(row.name)}</span>
        <span className="min-w-0 flex-1"><span className="block truncate text-sm font-medium text-ink">{row.name}</span><span className="block truncate font-mono text-[10px] text-ink-3">{row.path}</span></span>
        {row.path===current&&<span className="text-xs text-accent">Current</span>}
      </button>)}
      {!list.length&&<p className="p-3 text-sm text-ink-3">{query?'No matching workspaces.':'Open a folder to start a workspace.'}</p>}
    </div>
    <div className="shrink-0 border-t border-line p-1.5">
      <button type="button" onClick={pick(onNew)} className="flex w-full justify-between rounded-lg px-3 py-2 text-sm text-ink hover:bg-hover">Open a folder…<kbd className="text-xs text-ink-3">⌘O</kbd></button>
      <button type="button" onClick={pick(onSettings)} className="w-full rounded-lg px-3 py-2 text-left text-sm text-ink hover:bg-hover">Workspace settings…</button>
    </div>
  </div>,document.body);
}
