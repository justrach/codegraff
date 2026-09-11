import { useEffect, useMemo, useRef, type ReactNode } from "react";
import { IconFolder } from "@/lib/icons";
import type { Chat } from "./harness-types";
import { ComposerDraftContext } from "@/components/primitives/useComposerDraft";
import { createComposerDraft, type ComposerDraftStore } from "@/lib/composer-draft";
import SplitDivider from "./SplitDivider";
import {flatSplit,pruneSplit,splitGeometry,paneStyle,type SplitTree} from "@/lib/split-tree";
export default function ChatSplitLayout({ threads, liveChatIds, activeId, direction, layout, onLayoutChange, onFocus, onClose, folder, body, split }: {
  threads: Chat[]; activeId: number; direction: "row" | "column"; layout?: SplitTree;
  liveChatIds?: number[];
  onLayoutChange(tree:SplitTree):void; onFocus(id: number): void; onClose(id: number): void;
  folder(thread: Chat): { name: string; path?: string }; body(thread: Chat): ReactNode; split: boolean;
}) {
  const drafts = useRef(new Map<number, ComposerDraftStore>());
  const liveKey = liveChatIds?.join(",");
  useEffect(() => {
    if (liveKey === undefined) return;
    const live = new Set(liveKey.split(",").filter(Boolean).map(Number));
    for (const [id, store] of drafts.current) if (!live.has(id)) { store.dispose(); drafts.current.delete(id); }
  }, [liveKey]);
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    const stores = drafts.current;
    return () => {
      mounted.current = false;
      queueMicrotask(() => { if (!mounted.current) { stores.forEach(store => store.dispose()); stores.clear(); } });
    };
  }, []);
  const draftFor = (id: number) => {
    let store = drafts.current.get(id);
    if (!store) { store = createComposerDraft(); drafts.current.set(id, store); }
    return store;
  };
  const shownKey=threads.map(thread=>thread.id).join(',');
  const tree=useMemo(()=>layout?pruneSplit(layout,new Set(threads.map(thread=>thread.id)))!:flatSplit(threads.map(thread=>thread.id),direction),[layout,shownKey,direction]);
  const geometry=useMemo(()=>splitGeometry(tree),[tree]);
  return <div data-chat-layout className="relative flex min-h-0 min-w-0 flex-1" style={{flexDirection:direction}}>
    {threads.map((thread,index)=>
      <section key={thread.id} data-chat={thread.id} data-focused={thread.id===activeId} aria-label={`Chat pane ${index+1}`}
        onPointerDownCapture={()=>{if(thread.id!==activeId)onFocus(thread.id);}}
        onFocusCapture={()=>{if(thread.id!==activeId)onFocus(thread.id);}}
        style={{...paneStyle(geometry.panes.find(p=>p.id===thread.id)!.box),minHeight:0,borderColor:split&&thread.id===activeId?'var(--accent)':undefined}}
        className="absolute flex min-w-0 flex-col overflow-hidden rounded-[14px] border border-line bg-page">
        {split&&<header className="flex h-9 shrink-0 items-center gap-2 border-b border-line px-3">
          <button type="button" aria-pressed={thread.id===activeId} onClick={()=>onFocus(thread.id)} title="Focus this chat" className="min-w-0 flex-1 truncate text-left text-xs font-medium">{thread.title??`Chat ${thread.id}`}</button>
          <span title={folder(thread).path} className="flex min-w-0 max-w-[40%] items-center gap-1 text-[11px] text-ink-3"><IconFolder size={13}/><span className="truncate">{folder(thread).name}</span></span>
          <button type="button" aria-label="Close this split" title="Close this chat (⌘W)" onClick={()=>onClose(thread.id)} className="flex size-6 shrink-0 items-center justify-center rounded text-ink-3 hover:bg-hover hover:text-ink">×</button>
        </header>}
        <ComposerDraftContext.Provider value={draftFor(thread.id)}>{body(thread)}</ComposerDraftContext.Provider>
      </section>
    )}
    {geometry.dividers.map(({node,box},index)=><SplitDivider key={node.key} node={node} box={box} tree={tree} onChange={onLayoutChange} index={index}/>)}
  </div>;
}
