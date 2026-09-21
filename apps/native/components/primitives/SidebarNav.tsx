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
  IconPlusMedium,
  IconSettingsGear1,
  IconSidebarLeftArrow,
  IconSidebarLeftOpen,
} from "@/lib/icons";
import CodeGraffMark from "./CodeGraffMark";
import GlideMenu from "@/components/primitives/GlideMenu";
import ActionMenu from "./ActionMenu";
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
  { key: "agents", label: "Agents", icon: <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden><circle cx="9" cy="8" r="3"/><circle cx="16" cy="9" r="2.4"/><path d="M4 19c.5-2.6 2.6-4.5 5-4.5s4.5 1.9 5 4.5M13.5 19c.4-1.7 1.8-3 3.5-3s3.1 1.3 3.5 3"/></svg> },
  { key: "workspace", label: "Files", icon: <IconFolder size={18} /> },
  { key: "changes", label: "Changes", icon: <IconEditBig size={18} /> },
  { key: "browser", label: "Browser", icon: <IconGlobe size={18} /> },
];

export type SidebarRecent = {
  unread?: boolean;
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
  onCloseNavigation?: () => void;
  onCollapsedChange?: (collapsed: boolean) => void;
  openSessions?: ReactNode;
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
  footerControls?: ReactNode;
  /** Always-visible account control; stays clickable when the rail collapses. */
  accountControl?: ReactNode;
  onFooterClick?: () => void;
  /** Tooltip on the footer control. */
  footerTitle?: string;
  recents?: SidebarRecent[];
  /** How many saved sessions exist (sidebar only shows a preview). */
  recentsTotal?: number;
  onSeeAll?: () => void;
  agentsCount?: number;
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

export type SidebarWorkspace = { path: string; name: string; source?: "saved" | "startup" | "history" };

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
  onCloseNavigation, onCollapsedChange, openSessions,
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
  footerControls,
  accountControl,
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
  agentsCount = 0,
}: SidebarNavProps) {
  const [collapsed, setCollapsed] = useState(false);
  useEffect(() => { onCollapsedChange?.(collapsed); }, [collapsed, onCollapsedChange]);
  useEffect(() => {
    const toggle = () => setCollapsed(value => !value);
    window.addEventListener("graff-toggle-sidebar", toggle);
    return () => window.removeEventListener("graff-toggle-sidebar", toggle);
  }, []);
  useEffect(() => { if (onCloseNavigation) setCollapsed(false); }, [!!onCloseNavigation]);
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
  const searchButtonRef = useRef<HTMLButtonElement>(null);
  const expandButtonRef = useRef<HTMLButtonElement>(null);
  const collapseButtonRef = useRef<HTMLButtonElement>(null);

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
    if (onCloseNavigation) { setWorkspaceOpen(false); onCloseNavigation(); return; }
    setCollapsed(true);
    setWorkspaceOpen(false);
    setSearchOpen(false);
    setQuery("");
    requestAnimationFrame(() => expandButtonRef.current?.focus());
  };
  const closeSearch = () => {
    setSearchOpen(false);
    setQuery("");
    searchButtonRef.current?.focus();
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
        <div className="relative mb-2.5 flex h-10 shrink-0 items-center gap-1 px-2">
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
            className="sidebar-workspace-control flex h-8 min-w-0 flex-1 items-center rounded-[8px] px-2 text-left transition-[background-color,transform] duration-100 hover:bg-hover-2 active:scale-[0.99]"
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
            ref={collapseButtonRef}
            type="button"
            aria-label={onCloseNavigation ? "Close navigation" : "Collapse sidebar"}
            title={onCloseNavigation ? "Close navigation" : "Collapse sidebar (⌘B)"}
            aria-hidden={collapsed}
            tabIndex={collapsed ? -1 : 0}
            onClick={collapse}
            className="sidebar-collapse-control flex size-8 shrink-0 items-center justify-center rounded-[8px] text-ink-3 transition-[opacity,background-color,color] duration-150 hover:bg-hover-2 hover:text-ink"
          >
            <IconSidebarLeftArrow size={18} />
          </button>
          <button
            ref={expandButtonRef}
            type="button"
            aria-label="Expand sidebar"
            title="Expand sidebar (⌘B)"
            aria-hidden={!collapsed}
            tabIndex={collapsed ? 0 : -1}
            onClick={() => { setCollapsed(false); requestAnimationFrame(() => collapseButtonRef.current?.focus()); }}
            className="sidebar-expand-control absolute left-2 top-0.5 z-10 flex size-9 items-center justify-center rounded-[8px] text-ink-3 transition-[opacity,background-color,color] duration-150 hover:bg-hover-2 hover:text-ink"
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
          {NAV_ITEMS.filter(item => !footerControls || !["workspace", "changes", "browser"].includes(item.key)).map((item) => (
            <RailButton
              key={item.key}
              icon={item.icon}
              label={item.label}
              count={item.key === "agents" && agentsCount > 0 ? String(agentsCount) : item.count}
              active={currentNav === item.key}
              onClick={() => selectNav(item.key)}
            />
          ))}
          {onSeeAll && (
            <RailButton
              icon={<IconMagnifyingGlass size={18} />}
              label="Conversations"
              active={currentNav === "conversations"}
              onClick={() => {
                selectNav("conversations");
                onSeeAll();
              }}
            />
          )}
        </GlideGroup>

        <div inert={collapsed} aria-hidden={collapsed} className="mt-3 min-h-0 flex-1 overflow-y-auto">
          {openSessions}
          <div className="sidebar-copy relative mx-2 mb-1 h-8">
            <button
              type="button"
              aria-hidden={searchOpen}
              tabIndex={searchOpen ? -1 : 0}
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
              <span>History</span>
              {visibleRecents.length > 0 && <span className="tabular-nums text-ink-3">{visibleRecents.length}</span>}
            </button>

            <button
              ref={searchButtonRef}
              type="button"
              aria-label="Search chats"
              aria-hidden={searchOpen}
              tabIndex={searchOpen ? -1 : 0}
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
              inert={!searchOpen}
              aria-hidden={!searchOpen}
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
                    event.preventDefault();
                    event.stopPropagation();
                    closeSearch();
                  }
                }}
                placeholder="Search chats"
                aria-label="Search chat history"
                className="ml-1.5 min-w-0 flex-1 bg-transparent text-[13px] font-medium text-ink outline-none placeholder:text-ink-3"
              />
              <button
                type="button"
                aria-label="Close chat search"
                onClick={closeSearch}
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
                  data-session-name={item.id}
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
                  <span className={`sidebar-copy flex min-w-0 flex-1 flex-col ${onArchiveRecent || onDeleteRecent ? "pr-6" : ""}`}>
                    <span className={`truncate text-[13.5px] font-medium ${active ? "text-ink" : "text-ink-2"}`}>
                      {item.unread && <span role="img" aria-label="Unread response" className="mr-1.5 inline-block size-1.5 rounded-full bg-blue-500" />}
                      {item.label}
                    </span>
                    {item.hint && (
                      <span className="truncate text-[11px] text-ink-3">{item.hint}</span>
                    )}
                  </span>
                </button>
                {!collapsed && (onArchiveRecent || onDeleteRecent) && (
                  <ActionMenu label={`Actions for ${item.label}`} className="absolute right-3 top-2 z-20 opacity-0 transition-opacity group-hover/row:opacity-100 group-focus-within/row:opacity-100 [@media(hover:none)]:opacity-100">
                    {onArchiveRecent && <button type="button" aria-label={`Archive ${item.label}`} onClick={() => onArchiveRecent(item.id)}>Archive chat</button>}
                    {onDeleteRecent && <button type="button" aria-label={`Delete ${item.label}`} className="text-red" onClick={() => onDeleteRecent(item.id)}>Delete chat…</button>}
                  </ActionMenu>
                )}
                </div>
                </Fragment>
              );
            })}
            {visibleRecents.length === 0 && (query || !openSessions) && (
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
                className="sidebar-copy sidebar-row relative z-10 mx-2 flex h-8 items-center rounded-[8px] px-2 text-left text-[12.5px] font-medium text-ink-3 transition-[background-color,color,transform] duration-150 hover:text-ink active:scale-[0.98]"
              >
                See all {recentsTotal?.toLocaleString()} conversations
              </button>
            )}
          </GlideGroup>
          </div>
        </div>

        {accountControl && <div data-account-control className="mt-auto shrink-0 pb-1">{accountControl}</div>}
        {footerControls ? <div inert={collapsed} aria-hidden={collapsed} className="sidebar-copy">{footerControls}</div> : <div inert={collapsed} aria-hidden={collapsed} className="sidebar-copy mx-2 mt-3 w-[232px] border-t border-line pt-3">
          <button
            type="button"
            onClick={onFooterClick ?? onNewChat}
            title={footerTitle}
            className="flex h-8 w-full items-center justify-center gap-1.5 rounded-control px-2 text-[11px] font-medium text-ink-3 transition-[background-color,transform] duration-150 hover:bg-line-strong active:scale-[0.98]"
          >
            {footerIcon}
            <span className="min-w-0 flex-1 truncate text-center">{footerLabel}</span>
          </button>
        </div>}
      </div>
    </aside>
  );
}
