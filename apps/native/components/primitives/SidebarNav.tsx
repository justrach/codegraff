"use client";

import { Fragment, useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";
import {
  IconCheckmark1Small,
  IconChevronDownSmall,
  IconCrossSmall,
  IconEditBig,
  IconFolder,
  IconGlobe,
  IconHome,
  IconMagnifyingGlass,
  IconChat,
  IconPlusMedium,
  IconSettingsGear1,
  IconSidebarLeftArrow,
  IconSidebarLeftOpen,
} from "@/lib/icons";
import CodeGraffMark from "./CodeGraffMark";
import GlideMenu from "@/components/primitives/GlideMenu";
import WorkspaceMenu from "./WorkspaceMenu";

/* ─────────────────────────────────────────────────────────
 * SIDEBAR NAV
 * Shared by the design-system preview and the harness shell:
 * compact workspace switcher, primary navigation, searchable
 * chat history, and a collapse that preserves icon alignment.
 * ───────────────────────────────────────────────────────── */

const WORKSPACE = { key: "graff", name: "Codegraff", monogram: "G" };

const NAV_ITEMS: { key: string; label: string; icon: ReactNode; count?: string }[] = [
  { key: "home", label: "Home", icon: <IconHome size={18} /> },
  { key: "projects", label: "Projects", icon: <IconFolder size={18} /> },
  { key: "conversations", label: "Conversations", icon: <IconChat size={18} /> },
  { key: "workspace", label: "Files", icon: <IconFolder size={18} /> },
  { key: "changes", label: "Changes", icon: <IconEditBig size={18} /> },
  { key: "browser", label: "Browser", icon: <IconGlobe size={18} /> },
];

export type SidebarRecent = {
  id: string;
  label: string;
  prompt?: string;
  /** Section header shown above the first row of each run of equal groups. */
  group?: string;
  /** Tooltip detail (model, age) — the row itself stays a single line. */
  hint?: string;
};

const DEFAULT_RECENTS: SidebarRecent[] = [
  { id: "files", label: "What files are here?" },
  { id: "readme", label: "Summarize README.md" },
  { id: "review", label: "Review the last commit" },
  { id: "todos", label: "What's on the checklist?" },
];

type SidebarNavProps = {
  activeTitle?: string | null;
  /** When set, rows highlight by id instead of by label (titles can repeat). */
  activeId?: string | null;
  className?: string;
  fill?: boolean;
  onNewChat?: () => void;
  onPick?: (id: string, label: string, prompt?: string) => void;
  /** controlled primary-nav selection (e.g. "home" | "invite") */
  activeNav?: string;
  onNavigate?: (key: string) => void;
  /** footer call-to-action — defaults to the demo "Upgrade" button */
  footerLabel?: string;
  footerIcon?: ReactNode;
  onFooterClick?: () => void;
  /** Tooltip on the footer control. */
  footerTitle?: string;
  recents?: SidebarRecent[];
  /** How many saved sessions exist (sidebar only shows a preview). */
  recentsTotal?: number;
  onSeeAll?: () => void;
  variant?: string;
  /** The active workspace (the folder graff runs in); the demo shows a placeholder. */
  workspace?: SidebarWorkspace;
  /** Every workspace the switcher offers, the active one included. */
  workspaces?: SidebarWorkspace[];
  onSwitchWorkspace?: (path: string) => void;
  onNewWorkspace?: () => void;
  /** Put a saved chat away, or (deleting) remove it for good. */
  onArchiveRecent?: (id: string) => void;
  onDeleteRecent?: (id: string) => void;
  onWorkspaceSettings?: () => void;
};

export type SidebarWorkspace = { path: string; name: string };

const SIDEBAR_MOTION = {
  expandedWidth: 248,
  collapsedWidth: 52,
  duration: 280,
  copyDuration: 180,
  copyOffset: 8,
  easing: "cubic-bezier(0.16, 1, 0.3, 1)",
};

/* ─────────────────────────────────────────────────────────
 * CHAT SEARCH STORYBOARD
 *
 *   0ms   search is triggered; Chats label begins fading
 *   0ms   field grows right → left from the search control
 * 180ms   field fills the row; cursor is focused and ready
 * ───────────────────────────────────────────────────────── */
const CHAT_SEARCH_MOTION = {
  duration: 180,
  closedWidth: 28,
  easing: "cubic-bezier(0.16, 1, 0.3, 1)",
};

function GlideGroup({ children }: { children: ReactNode }) {
  return (
    <GlideMenu
      rowSelector="[data-row]"
      highlightClassName="sidebar-glide-highlight rounded-[7px] bg-hover-2"
      className="group/glide flex flex-col gap-px"
    >
      {children}
    </GlideMenu>
  );
}

function RailButton({
  icon,
  label,
  active = false,
  count,
  onClick,
}: {
  icon: ReactNode;
  label: string;
  active?: boolean;
  count?: string;
  onClick?: () => void;
}) {
  return (
    <button
      data-row
      type="button"
      aria-label={label}
      aria-current={active ? "page" : undefined}
      title={label}
      onClick={onClick}
      className={`sidebar-row relative z-10 mx-2 flex h-8 items-center rounded-[8px] px-2 text-left
        transition-[width,background-color,color,transform] duration-150 active:scale-[0.98]
        ${active ? "bg-hover-2 group-hover/glide:bg-transparent" : ""}`}
    >
      <span className={`flex size-5 shrink-0 items-center justify-center ${active ? "text-ink" : "text-ink-2"}`}>
        {icon}
      </span>
      <span className={`sidebar-copy ml-1.5 min-w-0 flex-1 truncate text-[14px] font-medium ${active ? "text-ink" : "text-ink-2"}`}>
        {label}
      </span>
      {count && (
        <span className="sidebar-copy mr-2 shrink-0 text-[12px] font-medium tabular-nums text-ink-3">
          {count}
        </span>
      )}
    </button>
  );
}

export default function SidebarNav({
  activeTitle,
  activeId,
  className = "",
  fill = false,
  onNewChat,
  onPick,
  activeNav,
  onNavigate,
  footerLabel = "Upgrade",
  footerIcon,
  onFooterClick,
  footerTitle,
  recents = DEFAULT_RECENTS,
  workspace,
  workspaces = [],
  onSwitchWorkspace,
  onNewWorkspace,
  onWorkspaceSettings,
  onArchiveRecent,
  onDeleteRecent,
  recentsTotal,
  onSeeAll,
}: SidebarNavProps) {
  const [collapsed, setCollapsed] = useState(false);
  const [internalNav, setInternalNav] = useState("chats");
  const currentNav = activeNav ?? internalNav;
  const selectNav = (key: string) => {
    setInternalNav(key);
    onNavigate?.(key);
  };
  const [demoActiveTitle, setDemoActiveTitle] = useState<string | null>(null);
  const [workspaceOpen, setWorkspaceOpen] = useState(false);
  const [workspacePosition, setWorkspacePosition] = useState({ top: 0, left: 0 });
  const [searchOpen, setSearchOpen] = useState(false);
  /** The Chats header collapses its list; searching always opens it again. */
  const [chatsOpen, setChatsOpen] = useState(true);
  const [query, setQuery] = useState("");
  const workspaceButtonRef = useRef<HTMLButtonElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  const selectedTitle = activeTitle === undefined ? demoActiveTitle : activeTitle;
  const visibleRecents = recents.filter((item) => item.label.toLowerCase().includes(query.trim().toLowerCase()));

  useEffect(() => {
    if (!workspaceOpen) return;
    const close = (event: PointerEvent) => {
      const target = event.target as Element;
      if (!target.closest("[data-workspace-trigger]") && !target.closest("[data-workspace-menu]")) {
        setWorkspaceOpen(false);
      }
    };
    document.addEventListener("pointerdown", close);
    return () => document.removeEventListener("pointerdown", close);
  }, [workspaceOpen]);

  useEffect(() => {
    if (searchOpen) searchRef.current?.focus();
  }, [searchOpen]);

  const collapse = () => {
    setCollapsed(true);
    setWorkspaceOpen(false);
    setSearchOpen(false);
    setQuery("");
  };

  return (
    <aside
      data-sidebar-collapsed={collapsed}
      aria-label="Workspace navigation"
      className={`relative flex shrink-0 overflow-hidden transition-[width] ${fill ? "h-full" : "h-[600px]"} ${className}`}
      style={{
        width: collapsed ? SIDEBAR_MOTION.collapsedWidth : SIDEBAR_MOTION.expandedWidth,
        transitionDuration: `${SIDEBAR_MOTION.duration}ms`,
        transitionTimingFunction: SIDEBAR_MOTION.easing,
        "--sidebar-copy-duration": `${SIDEBAR_MOTION.copyDuration}ms`,
        "--sidebar-copy-offset": `${SIDEBAR_MOTION.copyOffset}px`,
        "--sidebar-easing": SIDEBAR_MOTION.easing,
      } as CSSProperties}
    >
      <div className="flex min-h-0 w-[248px] shrink-0 flex-col">
        <div className="relative mb-2.5 h-10 shrink-0">
          <button
            ref={workspaceButtonRef}
            data-workspace-trigger
            type="button"
            aria-expanded={workspaceOpen}
            aria-hidden={collapsed}
            tabIndex={collapsed ? -1 : 0}
            onClick={() => {
              if (!workspaceOpen && workspaceButtonRef.current) {
                const rect = workspaceButtonRef.current.getBoundingClientRect();
                setWorkspacePosition({ top: rect.bottom + 6, left: rect.left });
              }
              setWorkspaceOpen((open) => !open);
            }}
            className="sidebar-workspace-control absolute left-2 top-1 flex h-8 w-[188px] items-center rounded-[8px] px-2 text-left transition-[background-color,transform] duration-100 hover:bg-hover-2 active:scale-[0.99]"
          >
            <span className="sidebar-logo flex size-5 shrink-0 items-center justify-center text-ink">
              <CodeGraffMark size={20} />
            </span>
            <span className="sidebar-copy ml-1.5 min-w-0 flex-1 truncate text-[14px] font-medium text-ink-2" title={workspace?.path}>
              {workspace?.name ?? WORKSPACE.name}
            </span>
            <span className="sidebar-copy ml-1 flex shrink-0 text-ink-3">
              <IconChevronDownSmall size={16} />
            </span>
          </button>

          {workspaceOpen && (
            <WorkspaceMenu
              position={workspacePosition}
              current={workspace?.path}
              rows={workspaces}
              onSwitch={onSwitchWorkspace}
              onNew={onNewWorkspace}
              onSettings={onWorkspaceSettings}
              onClose={() => setWorkspaceOpen(false)}
            />
          )}

          <button
            type="button"
            aria-label="Collapse sidebar"
            aria-hidden={collapsed}
            tabIndex={collapsed ? -1 : 0}
            onClick={collapse}
            className="sidebar-collapse-control absolute right-2 top-1 flex size-8 items-center justify-center rounded-[8px] text-ink-3 transition-[opacity,background-color,color] duration-150 hover:bg-hover-2 hover:text-ink"
          >
            <IconSidebarLeftArrow size={18} />
          </button>
          <button
            type="button"
            aria-label="Expand sidebar"
            aria-hidden={!collapsed}
            tabIndex={collapsed ? 0 : -1}
            onClick={() => setCollapsed(false)}
            className="sidebar-expand-control absolute left-2 top-0.5 flex size-9 items-center justify-center rounded-[8px] text-ink-3 transition-[opacity,background-color,color] duration-150 hover:bg-hover-2 hover:text-ink"
          >
            <IconSidebarLeftOpen size={18} />
          </button>
        </div>

        <GlideGroup>
          {onNewWorkspace && <RailButton icon={<IconPlusMedium size={18} />} label="Open folder…" onClick={onNewWorkspace} />}
          <RailButton
            icon={<IconEditBig size={18} />}
            label="New chat"
            onClick={() => {
              if (activeTitle === undefined) setDemoActiveTitle(null);
              selectNav("chats");
              onNewChat?.();
            }}
          />
          {NAV_ITEMS.map((item) => (
            <RailButton
              key={item.key}
              icon={item.icon}
              label={item.label}
              count={item.key === "conversations" && recentsTotal != null ? String(recentsTotal) : item.count}
              active={currentNav === item.key}
              onClick={() => selectNav(item.key)}
            />
          ))}
        </GlideGroup>

        <div className="mt-3 min-h-0 flex-1 overflow-y-auto">
          <div className="sidebar-copy relative mx-2 mb-1 h-8">
            <button
              type="button"
              aria-hidden={searchOpen}
              aria-expanded={chatsOpen}
              aria-controls="sidebar-chat-list"
              title={chatsOpen ? "Hide the chat list" : "Show the chat list"}
              onClick={() => setChatsOpen((open) => !open)}
              className={`absolute inset-y-0 left-0 flex items-center gap-1.5 rounded-[8px] px-2 text-[12.5px] font-medium text-ink-3 transition-[opacity,transform,background-color,color] hover:bg-hover-2 hover:text-ink ${searchOpen ? "pointer-events-none -translate-x-1 opacity-0" : "translate-x-0 opacity-100"}`}
              style={{ transitionDuration: `${CHAT_SEARCH_MOTION.duration}ms`, transitionTimingFunction: CHAT_SEARCH_MOTION.easing }}
            >
              <span className={`flex transition-transform duration-150 ${chatsOpen ? "" : "-rotate-90"}`}>
                <IconChevronDownSmall size={16} />
              </span>
              <span>Chats</span>
              {visibleRecents.length > 0 && <span className="tabular-nums text-ink-3">{visibleRecents.length}</span>}
            </button>

            <button
              type="button"
              aria-label="Search chats"
              aria-expanded={searchOpen}
              onClick={() => {
                setSearchOpen(true);
                setChatsOpen(true);
              }}
              className={`absolute right-0 top-0 z-10 flex size-8 items-center justify-center rounded-[8px] text-ink-3 transition-[opacity,background-color,color,transform] hover:bg-hover-2 hover:text-ink active:scale-[0.96] ${searchOpen ? "pointer-events-none opacity-0" : "opacity-100"}`}
              style={{ transitionDuration: `${CHAT_SEARCH_MOTION.duration}ms` }}
            >
              <IconMagnifyingGlass size={16} />
            </button>

            <div
              className={`absolute right-0 top-0 z-20 flex h-8 items-center overflow-hidden rounded-[8px] bg-field text-ink-3 shadow-hairline transition-[width,opacity] focus-within:text-ink-2 ${searchOpen ? "pointer-events-auto opacity-100" : "pointer-events-none opacity-0"}`}
              style={{
                width: searchOpen ? "100%" : CHAT_SEARCH_MOTION.closedWidth,
                transitionDuration: `${CHAT_SEARCH_MOTION.duration}ms`,
                transitionTimingFunction: CHAT_SEARCH_MOTION.easing,
              }}
            >
              <span className="ml-2 flex shrink-0 items-center justify-center">
                <IconMagnifyingGlass size={15} />
              </span>
              <input
                ref={searchRef}
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Escape") {
                    setSearchOpen(false);
                    setQuery("");
                  }
                }}
                placeholder="Search chats"
                aria-label="Search chat history"
                className="ml-1.5 min-w-0 flex-1 bg-transparent text-[13px] font-medium text-ink outline-none placeholder:text-ink-3"
              />
              <button
                type="button"
                aria-label="Close chat search"
                onClick={() => {
                  setSearchOpen(false);
                  setQuery("");
                }}
                className="flex size-8 shrink-0 items-center justify-center rounded-[8px] text-ink-3 transition-[background-color,color,transform] duration-150 hover:bg-hover-2 hover:text-ink active:scale-[0.96]"
              >
                <IconCrossSmall size={16} />
              </button>
            </div>
          </div>

          <div id="sidebar-chat-list" hidden={!chatsOpen}>
          <GlideGroup>
            {visibleRecents.map((item, index) => {
              const active = activeId !== undefined ? item.id === activeId : item.label === selectedTitle;
              const header = item.group && item.group !== visibleRecents[index - 1]?.group ? item.group : null;
              return (
                <Fragment key={item.id}>
                {header && (
                  <div className={`sidebar-copy mx-2 px-2 pb-1 text-[11px] font-medium tracking-wide text-ink-3 ${index === 0 ? "" : "mt-3"}`}>
                    {header}
                  </div>
                )}
                <div className="group/row relative">
                <button
                  data-row
                  type="button"
                  title={item.hint ? `${item.label} — ${item.hint}` : item.label}
                  onClick={() => {
                    selectNav("home");
                    if (activeTitle === undefined) setDemoActiveTitle(item.label);
                    onPick?.(item.id, item.label, item.prompt);
                  }}
                  className={`sidebar-row relative z-10 mx-2 flex min-h-10 items-center rounded-[8px] px-2 py-1.5 text-left transition-[width,background-color,color,transform] duration-150 active:scale-[0.98] ${
                    active ? "bg-hover-2 group-hover/glide:bg-transparent" : ""
                  }`}
                >
                  <span className={`sidebar-copy flex min-w-0 flex-1 flex-col ${onArchiveRecent || onDeleteRecent ? "pr-14" : ""}`}>
                    <span className={`truncate text-[13.5px] font-medium ${active ? "text-ink" : "text-ink-2"}`}>
                      {item.label}
                    </span>
                    {item.hint && (
                      <span className="truncate text-[11px] text-ink-3">{item.hint}</span>
                    )}
                  </span>
                </button>
                {(onArchiveRecent || onDeleteRecent) && (
                  <span className="sidebar-copy absolute inset-y-0 right-3 z-20 flex items-center gap-0.5 opacity-0 transition-opacity group-focus-within/row:opacity-100 group-hover/row:opacity-100">
                    {onArchiveRecent && (
                      <button
                        type="button"
                        aria-label={`Archive ${item.label}`}
                        title="Archive this chat — it leaves the list but stays on disk"
                        onClick={(event) => {
                          event.stopPropagation();
                          onArchiveRecent(item.id);
                        }}
                        className="flex size-6 items-center justify-center rounded-[6px] text-ink-3 transition-colors hover:bg-hover-2 hover:text-ink"
                      >
                        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                          <rect x="3" y="4" width="18" height="4" rx="1" />
                          <path d="M5 8v11a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8M10 12h4" />
                        </svg>
                      </button>
                    )}
                    {onDeleteRecent && (
                      <button
                        type="button"
                        aria-label={`Delete ${item.label}`}
                        title="Delete this chat for good"
                        onClick={(event) => {
                          event.stopPropagation();
                          onDeleteRecent(item.id);
                        }}
                        className="flex size-6 items-center justify-center rounded-[6px] text-ink-3 transition-colors hover:bg-hover-2 hover:text-red"
                      >
                        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                          <path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3" />
                        </svg>
                      </button>
                    )}
                  </span>
                )}
                </div>
                </Fragment>
              );
            })}
            {visibleRecents.length === 0 && (
              <div className="sidebar-copy mx-2 px-2 py-2 text-[12.5px] text-ink-3">
                {query ? "No chats found" : "No chats yet — start one and it appears here."}
              </div>
            )}
            {!query && onSeeAll && (recentsTotal ?? recents.length) > recents.length && (
              <button
                data-row
                type="button"
                onClick={() => {
                  selectNav("conversations");
                  onSeeAll();
                }}
                className="sidebar-row relative z-10 mx-2 flex h-8 items-center rounded-[8px] px-2 text-left text-[12.5px] font-medium text-ink-3 transition-[background-color,color,transform] duration-150 hover:text-ink active:scale-[0.98]"
              >
                See all {recentsTotal?.toLocaleString()} conversations
              </button>
            )}
          </GlideGroup>
          </div>
        </div>

        <div className="sidebar-copy mx-2 mt-3 w-[232px] border-t border-line pt-3">
          <button
            type="button"
            onClick={onFooterClick ?? onNewChat}
            title={footerTitle}
            className="flex h-8 w-full items-center justify-center gap-1.5 rounded-control bg-hover-2 px-2 text-[12.5px] font-medium text-ink transition-[background-color,transform] duration-150 hover:bg-line-strong active:scale-[0.98]"
          >
            {footerIcon}
            <span className="min-w-0 flex-1 truncate text-center">{footerLabel}</span>
          </button>
        </div>
      </div>
    </aside>
  );
}
