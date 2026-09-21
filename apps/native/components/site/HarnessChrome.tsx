"use client";
import SessionTabs from "./SessionTabs";
import type {SplitTree} from "@/lib/split-tree";
import ActionMenu from "@/components/primitives/ActionMenu";
import AppSettings from "./AppSettings";
import { IconSidebarLeftOpen } from "@/lib/icons";
import type { PointerEvent, MouseEvent, ReactNode } from "react";
import type { Chat } from "./harness-types";
import reviewStyles from "./ChangesPane.module.css";
import { archiveTaskWorkspace, createTaskWorkspace, gcTaskWorkspaces, landTaskWorkspace, runTaskWorkspace, updateTaskWorkspace } from "./harness-task-workspace";
import { useCommandGlyph } from "@/lib/shortcut-glyph";

type Props = {
  navigationToggle?: ReactNode; sidebarVisible?: boolean;
  unreadIds?: ReadonlySet<number>;
  onTabPointerDown?(event: PointerEvent, id: number): void; onTabClickCapture?(event: MouseEvent): void;
  chats: (Pick<Chat, "id" | "title"> & { paneIds?: number[]; direction?: "row" | "column"; tree?: SplitTree })[]; activeId: number; busyIds: ReadonlySet<number>;
  focusChat(id: number): void; closeChat(id: number): void; newChat(): void;
  conversationsOpen: boolean; openConversations(): void; split: boolean; toggleSplit(): void;
  filesOpen: boolean; onFiles(): void; chatCwd?: string; workspaceName: string; onFolder(): void;
  openChanges(): void; changesOpen?: boolean; reviewsOpen?: boolean; onReviews?: () => void; browserOpen: boolean; onBrowser(): void; pinCount: number;
  terminalVisible: boolean; toggleTerminal(): void; agentsOpen: boolean; onAgents(): void; workingAgents?: number;
  tasksOpen?: boolean; taskCount?: number; onTasks?: () => void; splitNotice?: string | null;
};

function paneBtn(pressed: boolean) {
  return `h-7 shrink-0 rounded-[7px] px-2.5 text-[12.5px] font-medium ${pressed ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover"}`;
}

export default function HarnessChrome({navigationToggle, sidebarVisible = false, unreadIds, chats, activeId, busyIds, focusChat, closeChat, newChat,
  conversationsOpen, openConversations, split, toggleSplit, filesOpen, onFiles, chatCwd,
  workspaceName, onFolder, openChanges, changesOpen = false, reviewsOpen = false, onReviews, browserOpen, onBrowser, pinCount, terminalVisible,
  toggleTerminal, agentsOpen, onAgents, workingAgents = 0, tasksOpen = false, taskCount = 0, onTasks, splitNotice, onTabPointerDown, onTabClickCapture}: Props) {
  const mod = useCommandGlyph();
  return (
    <div data-workspace-toolbar data-workspace-root={chatCwd} className={`${reviewStyles.chatbar} flex shrink-0 flex-col ${sidebarVisible ? "overflow-visible bg-transparent" : "overflow-hidden rounded-[14px] border border-line bg-page"}`}>
      {!sidebarVisible && <div data-session-tab-strip className="flex h-10 min-w-0 shrink-0 items-center gap-1 px-2">
        <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <button type="button" aria-label="Show agents" aria-pressed={agentsOpen} onClick={onAgents}
          className={paneBtn(agentsOpen)}>Agents{workingAgents > 0 ? ` (${workingAgents})` : ""}</button>
        <span aria-hidden="true" className="mx-1 h-4 w-px shrink-0 bg-line" />
        <SessionTabs chats={chats} activeId={activeId} busyIds={busyIds} unreadIds={unreadIds}
          agentsOpen={agentsOpen} focusChat={focusChat} closeChat={closeChat}
          onTabPointerDown={onTabPointerDown} onTabClickCapture={onTabClickCapture} />
        <button type="button" aria-label="New chat" title={`New chat (${mod}T)`} onClick={newChat}
          className="ml-0.5 flex size-7 shrink-0 items-center justify-center rounded-full text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden>
            <path d="M12 5v14M5 12h14" />
          </svg>
        </button>
        </div>
      </div>}
      <div className={`${reviewStyles.actions} flex shrink-0 items-center gap-1 ${sidebarVisible ? "justify-end" : "min-h-10 border-t border-line px-2 py-1"}`}>
        {navigationToggle}
        <button type="button" aria-pressed={filesOpen && !changesOpen} onClick={onFiles} title={`${chatCwd ?? "Workspace"}\nShow this chat's files`}
          className={`max-w-48 truncate lg:hidden ${paneBtn(filesOpen && !changesOpen)}`}>{workspaceName}</button>
        <div className={`ml-auto flex items-center gap-1 ${sidebarVisible ? "rounded-[14px] border border-line bg-page px-2 py-0.5" : ""}`}>
        <ActionMenu label="Workspace tools" text="Tools" className="shrink-0">
          <button type="button" aria-label="Review workspace changes" aria-pressed={changesOpen} onClick={openChanges}>Review</button>
          {onReviews && <button type="button" aria-label="GitHub reviews" aria-pressed={reviewsOpen} onClick={onReviews}>Reviews</button>}
          <button type="button" aria-label="New task workspace" onClick={() => void createTaskWorkspace(chatCwd).catch(err => window.alert(String(err.message || err)))}>New task workspace</button>
          <button type="button" aria-label="Run workspace script" onClick={() => void runTaskWorkspace(chatCwd, () => { if (!terminalVisible) toggleTerminal(); }).catch(err => window.alert(String(err.message || err)))}>Run</button>
          <button type="button" aria-label="Update task workspace from main" onClick={() => void updateTaskWorkspace(chatCwd).catch(err => window.alert(String(err.message || err)))}>Update from main</button>
          <button type="button" aria-label="Land task workspace" onClick={() => void landTaskWorkspace(chatCwd).catch(err => window.alert(String(err.message || err)))}>Land</button>
          <button type="button" aria-label="Archive task workspace" onClick={() => void archiveTaskWorkspace(chatCwd).catch(err => window.alert(String(err.message || err)))}>Archive</button>
          <button type="button" aria-label="Clear unused task trees" onClick={() => void gcTaskWorkspaces(chatCwd).catch(err => window.alert(String(err.message || err)))}>Clear unused trees</button>
          <button type="button" aria-label="Toggle terminal" aria-pressed={terminalVisible} onClick={toggleTerminal}>Terminal <span className="ml-auto text-ink-3">{mod}J</span></button>
          <button type="button" aria-label="Browser" aria-pressed={browserOpen} onClick={onBrowser}>Browser{pinCount > 0 ? ` (${pinCount})` : ""}</button>
          <button type="button" aria-label="Files" aria-pressed={filesOpen && !changesOpen} onClick={onFiles}>Files</button>
        </ActionMenu>
        {(taskCount > 0 || tasksOpen) && onTasks && <button type="button" aria-label="Show tasks" aria-pressed={tasksOpen} onClick={onTasks} className={paneBtn(tasksOpen)}>Tasks{taskCount ? ` (${taskCount})` : ""}</button>}
        <ActionMenu label="Chat actions" text="More" className="shrink-0">
          {!sidebarVisible && <button type="button" onClick={newChat}>New chat <span className="ml-auto text-ink-3">{mod}T</span></button>}
          <button type="button" aria-pressed={split} onClick={toggleSplit}>{split ? "Close splits" : "Split view"} <span className="ml-auto text-ink-3">{mod}\</span></button>
          <button type="button" aria-label="Conversations" aria-pressed={conversationsOpen} onClick={openConversations}>All conversations</button>
          <button type="button" onClick={onFolder}>Open a folder…</button>
        </ActionMenu>
        {!sidebarVisible && <button type="button" aria-label="Expand sidebar" title={`Expand sidebar (${mod}B)`}
          onClick={() => window.dispatchEvent(new CustomEvent("graff-toggle-sidebar"))}
          className="hidden size-7 shrink-0 items-center justify-center rounded-full text-ink-3 hover:bg-hover hover:text-ink lg:flex">
          <IconSidebarLeftOpen size={16} />
        </button>}
        {!sidebarVisible && <AppSettings />}
        <div data-desktop-update-slot className="shrink-0" />
        </div>
      </div>
      {splitNotice && <p role="status" data-split-limit className="border-t border-line px-3 py-1.5 text-[12px] text-ink-2">{splitNotice}</p>}
    </div>
  );
}
