import { IconChat, IconFolder, IconGlobe } from "@/lib/icons";
import { useEffect, useRef } from "react";
import { ThemeToggle } from "./ThemeToggle";
import type { Chat } from "./harness-types";
import reviewStyles from "./ChangesPane.module.css";
type Props = {
  chats: Chat[]; activeId: number; busyIds: ReadonlySet<number>;
  focusChat(id: number): void; closeChat(id: number): void; newChat(): void;
  conversationsOpen: boolean; openConversations(): void; split: boolean; toggleSplit(): void;
  filesOpen: boolean; onFiles(): void; chatCwd?: string; workspaceName: string; onFolder(): void;
  openChanges(): void; browserOpen: boolean; onBrowser(): void; pinCount: number;
  terminalVisible: boolean; toggleTerminal(): void; agentsOpen: boolean; onAgents(): void;
};
export default function HarnessChrome({chats, activeId, busyIds, focusChat, closeChat, newChat,
  conversationsOpen, openConversations, split, toggleSplit, filesOpen, onFiles, chatCwd,
  workspaceName, onFolder, openChanges, browserOpen, onBrowser, pinCount, terminalVisible,
  toggleTerminal, agentsOpen, onAgents}: Props) {
  const frame = useRef<HTMLDivElement>(null);
  useEffect(() => { frame.current?.querySelector(`[data-tab-id="${activeId}"]`)?.scrollIntoView({block: "nearest", inline: "nearest"}); }, [activeId]);
  return (
    <div ref={frame} data-workspace-toolbar className={`${reviewStyles.chatbar} flex shrink-0 flex-col overflow-hidden rounded-[14px] border border-line bg-page`}>
      {/* Tabs scroll independently; toolbar labels collapse in narrow panes. */}
      <div className="flex h-10 min-w-0 shrink-0 items-center gap-1 overflow-x-auto px-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        {chats.map((c) => (
          <div
            data-tab-id={c.id}
            key={c.id}
            className={`group/tab flex h-7 w-36 shrink-0 items-center gap-0.5 rounded-[7px] pl-2.5 pr-1 text-[12.5px] font-medium transition-colors duration-100 ${
              c.id === activeId ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
            }`}
          >
            {busyIds.has(c.id) && (
              <span
                className="mr-1 size-1.5 shrink-0 animate-pulse rounded-full"
                style={{ background: "var(--accent)" }}
                aria-label="Working"
              />
            )}
            <button
              type="button"
              aria-pressed={c.id === activeId}
              onClick={() => {
                focusChat(c.id);
              }}
              title={c.title ?? (chats.length > 1 ? `Chat ${c.id}` : "New chat")}
              className="min-w-0 flex-1 text-left"
            >
              <span className="block truncate">{c.title ?? (chats.length > 1 ? `Chat ${c.id}` : "New chat")}</span>
            </button>
            <button
              type="button"
              aria-label="Close tab"
              title={c.id === activeId ? "Close tab (⌘W) — ⇧⌘T brings it back" : "Close tab"}
              onClick={() => closeChat(c.id)}
              className="-my-1 flex size-6 shrink-0 items-center justify-center rounded-[5px] text-ink-3 transition-[background-color,color] duration-100 hover:bg-hover-2 hover:text-ink"
            >
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden>
                <path d="M18 6L6 18M6 6l12 12" />
              </svg>
            </button>
          </div>
        ))}
        <button
          type="button"
          aria-label="New chat"
          title="New chat (⌘T)"
          onClick={newChat}
          className="ml-0.5 flex size-7 shrink-0 items-center justify-center rounded-[7px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
        >
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden>
            <path d="M12 5v14M5 12h14" />
          </svg>
        </button>
      </div>
      <div className={`${reviewStyles.actions} flex min-h-10 shrink-0 items-center gap-2 overflow-x-auto border-t border-line px-2 py-1`}>
        <button
          type="button"
          aria-pressed={conversationsOpen}
          onClick={openConversations}
          title="All conversations"
          className={`flex h-7 items-center gap-1.5 rounded-[7px] px-2 text-[12px] font-medium transition-colors duration-100 ${
            conversationsOpen ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
          <IconChat size={14} />
          <span data-toolbar-label className="hidden sm:inline">Chats</span>
        </button>
        <button
          type="button"
          aria-pressed={split}
          onClick={toggleSplit}
          title={split ? "Close the splits (⌘\\)" : "Split the view: another chat beside this one (⌘D adds one)"}
          className={`flex size-7 items-center justify-center rounded-[7px] transition-colors duration-100 ${
            split ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <rect x="3" y="4" width="18" height="16" rx="2" />
            <path d="M12 4v16" />
          </svg>
        </button>
        <button
          type="button"
          aria-pressed={filesOpen}
          onClick={onFiles}
          title={`${chatCwd ?? "Workspace"}\nShow this chat's files`}
          className={`flex h-7 items-center gap-1.5 rounded-l-[7px] pl-2 pr-1.5 text-[12px] font-medium transition-colors duration-100 ${
            filesOpen ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
          <IconFolder size={14} />
          <span data-toolbar-label className="max-w-40 truncate font-mono text-[11.5px]">{workspaceName}</span>
        </button>
        <button
          type="button"
          aria-label="Open a folder"
          onClick={onFolder}
          title="Open another folder to work in"
          className="-ml-2 flex h-7 items-center rounded-r-[7px] pl-0.5 pr-1.5 text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
        >
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <path d="M6 9l6 6 6-6" />
          </svg>
        </button>
        <button type="button" onClick={openChanges} className="flex items-center gap-1.5 rounded-lg px-2 py-1 text-xs text-ink-2 hover:bg-hover" aria-label="Review workspace changes" title="Review workspace changes"><svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><path d="M5 5h14v14H5zM8 9h8M8 12h8M8 15h4" /></svg><span data-toolbar-label>Changes</span></button>
        <button
          type="button"
          aria-pressed={browserOpen}
          onClick={onBrowser}
          title="Sidecar browser — a Chrome tab this chat and its agent share"
          className={`flex h-7 items-center gap-1.5 rounded-[7px] px-2 text-[12px] font-medium transition-colors duration-100 ${
            browserOpen ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
          <IconGlobe size={14} />
          <span data-toolbar-label className="text-[11.5px]">Browser</span>
          {pinCount > 0 && (
            <span className="rounded-full bg-accent px-1.5 text-[10px] font-semibold text-white tabular-nums">{pinCount}</span>
          )}
        </button>
        <button aria-label="Toggle terminal" aria-pressed={terminalVisible} title="Terminal (⌘J)" onClick={toggleTerminal} className="rounded-lg px-2 py-1 text-xs text-ink-2 hover:bg-hover"><svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9 3 3-3 3m6 0h4"/></svg></button>
        <button aria-label="Show agents" aria-pressed={agentsOpen} onClick={onAgents} className="flex items-center gap-1.5 rounded-lg px-2 py-1 text-xs text-ink-2 hover:bg-hover"><svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><circle cx="9" cy="7" r="3"/><path d="M3 20v-3a6 6 0 0 1 12 0v3M16 4a3 3 0 0 1 0 6M18 14a5 5 0 0 1 3 4v2"/></svg><span data-toolbar-label>Agents</span></button>
        <ThemeToggle />
      </div>
    </div>
  );

}
