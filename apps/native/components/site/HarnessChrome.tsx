import SessionTabs from "./SessionTabs";
import type {SplitTree} from "@/lib/split-tree";
import ActionMenu from "@/components/primitives/ActionMenu";
import AppSettings from "./AppSettings";
import type { PointerEvent, MouseEvent, ReactNode } from "react";
import type { Chat } from "./harness-types";
import reviewStyles from "./ChangesPane.module.css";

type Props = {
  navigationToggle?: ReactNode; sidebarVisible?: boolean;
  unreadIds?: ReadonlySet<number>;
  onTabPointerDown?(event: PointerEvent, id: number): void; onTabClickCapture?(event: MouseEvent): void;
  chats: (Pick<Chat, "id" | "title"> & { paneIds?: number[]; direction?: "row" | "column"; tree?: SplitTree })[]; activeId: number; busyIds: ReadonlySet<number>;
  focusChat(id: number): void; closeChat(id: number): void; newChat(): void;
  conversationsOpen: boolean; openConversations(): void; split: boolean; toggleSplit(): void;
  filesOpen: boolean; onFiles(): void; chatCwd?: string; workspaceName: string; onFolder(): void;
  openChanges(): void; changesOpen?: boolean; browserOpen: boolean; onBrowser(): void; pinCount: number;
  terminalVisible: boolean; toggleTerminal(): void; agentsOpen: boolean; onAgents(): void; workingAgents?: number;
  tasksOpen?: boolean; taskCount?: number; onTasks?: () => void; splitNotice?: string | null;
};

function paneBtn(pressed: boolean) {
  return `h-7 shrink-0 rounded-[7px] px-2.5 text-[12.5px] font-medium ${pressed ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover"}`;
}

export default function HarnessChrome({navigationToggle, sidebarVisible = false, unreadIds, chats, activeId, busyIds, focusChat, closeChat, newChat,
  conversationsOpen, openConversations, split, toggleSplit, filesOpen, onFiles, chatCwd,
  workspaceName, onFolder, openChanges, changesOpen = false, browserOpen, onBrowser, pinCount, terminalVisible,
  toggleTerminal, agentsOpen, onAgents, workingAgents = 0, tasksOpen = false, taskCount = 0, onTasks, splitNotice, onTabPointerDown, onTabClickCapture}: Props) {
  return (
    <div data-workspace-toolbar className={`${reviewStyles.chatbar} flex shrink-0 flex-col ${sidebarVisible ? "overflow-visible bg-transparent" : "overflow-hidden rounded-[14px] border border-line bg-page"}`}>
      <div data-session-tab-strip hidden={sidebarVisible} className={sidebarVisible ? "hidden" : "flex h-10 min-w-0 shrink-0 items-center gap-1 px-2"}>
        <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <button type="button" aria-label="Show agents" aria-pressed={agentsOpen} onClick={onAgents}
          className={paneBtn(agentsOpen)}>Agents{workingAgents > 0 ? ` (${workingAgents})` : ""}</button>
        <span aria-hidden="true" className="mx-1 h-4 w-px shrink-0 bg-line" />
        {!sidebarVisible && <SessionTabs chats={chats} activeId={activeId} busyIds={busyIds} unreadIds={unreadIds}
          agentsOpen={agentsOpen} focusChat={focusChat} closeChat={closeChat}
          onTabPointerDown={onTabPointerDown} onTabClickCapture={onTabClickCapture} />}
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
      </div>
      <div className={`${reviewStyles.actions} flex min-h-10 shrink-0 items-center gap-1 ${sidebarVisible ? "justify-end px-1" : "border-t border-line px-2"} py-1`}>
        {navigationToggle}
        <button type="button" aria-pressed={filesOpen && !changesOpen} onClick={onFiles} title={`${chatCwd ?? "Workspace"}\nShow this chat's files`}
          className={`max-w-48 truncate lg:hidden ${paneBtn(filesOpen && !changesOpen)}`}>{workspaceName}</button>
        <div className={`ml-auto flex items-center gap-1 ${sidebarVisible ? "rounded-[14px] border border-line bg-page px-2 py-0.5" : ""}`}>
        <ActionMenu label="Workspace tools" text="Tools" className="shrink-0">
          <button type="button" aria-label="Review workspace changes" aria-pressed={changesOpen} onClick={openChanges}>Review</button>
          <button type="button" aria-label="Toggle terminal" aria-pressed={terminalVisible} onClick={toggleTerminal}>Terminal <span className="ml-auto text-ink-3">⌘J</span></button>
          <button type="button" aria-label="Browser" aria-pressed={browserOpen} onClick={onBrowser}>Browser{pinCount > 0 ? ` (${pinCount})` : ""}</button>
          <button type="button" aria-label="Files" aria-pressed={filesOpen && !changesOpen} onClick={onFiles}>Files</button>
        </ActionMenu>
        {(taskCount > 0 || tasksOpen) && onTasks && <button type="button" aria-label="Show tasks" aria-pressed={tasksOpen} onClick={onTasks} className={paneBtn(tasksOpen)}>Tasks{taskCount ? ` (${taskCount})` : ""}</button>}
        <ActionMenu label="Chat actions" text="More" className="shrink-0">
          <button type="button" onClick={newChat}>New chat <span className="ml-auto text-ink-3">⌘T</span></button>
          <button type="button" aria-pressed={split} onClick={toggleSplit}>{split ? "Close splits" : "Split view"} <span className="ml-auto text-ink-3">⌘\</span></button>
          <button type="button" aria-pressed={conversationsOpen} onClick={openConversations}>All conversations</button>
          <button type="button" onClick={onFolder}>Open a folder…</button>
        </ActionMenu>
        {!sidebarVisible && <AppSettings />}
        <div data-desktop-update-slot className="shrink-0" />
        </div>
      </div>
      {splitNotice && <p role="status" data-split-limit className="border-t border-line px-3 py-1.5 text-[12px] text-ink-2">{splitNotice}</p>}
    </div>
  );
}
