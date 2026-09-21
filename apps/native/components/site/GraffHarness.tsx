"use client";
import SessionTabs from "./SessionTabs";
import { useResponsiveNavigation } from "./useResponsiveNavigation";
import { useNavigationPromptFocus } from "./useNavigationPromptFocus";
import { useUnreadChats } from "./useUnreadChats";
import { useHarnessSessions } from "./useHarnessSessions";
import { resumeQueuedPrompt } from "@/lib/prompt-queue-resume";
import { createPromptRunner } from "./harness-prompt-runner";
import { workspaceActions } from "./harness-workspace-actions";
import { useNotchObserver } from "./useNotchObserver";
import { useSavedConversation, ConversationOpenNotice } from "./useSavedConversation";
import { useQuietSettings } from "./useQuietSettings";
import { useTabDrag } from "./useTabDrag";
import { mergeChatGroups, reorderChatGroups, resumeSplitTarget } from "@/lib/chat-groups";
import { useChatGroups } from "./useChatGroups";
import HarnessChrome from "./HarnessChrome";
import ChatSplitLayout from "./ChatSplitLayout";
import { sidebarRecents } from "./harness-sidebar";
import { newPageToken, newSessionName, type Chat, type Msg } from "./harness-types";
import { modelDisplayName, paneComposerKey } from "@/lib/composer-model";
import { createModelSwitcher } from "./harness-model";
import { useBrowserVisibility } from "./useBrowserVisibility";
import { useReferenceNavigation } from "./useReferenceNavigation";
import { useThreadCallbacks } from "./useThreadCallbacks";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { type PromptModel } from "@/components/primitives/PromptBar";
import SidebarNav from "@/components/primitives/SidebarNav";
import { type BrowserPin } from "@/lib/browser/annotations";
import ChatColumn from "./ChatColumn";
import CloseConfirmDialog from "@/components/site/CloseConfirmDialog";
import ModelSwitchDialog from "@/components/site/ModelSwitchDialog";
import {
  AgentsPane, AppSettings, BrowserPane, ChangesPane, ConversationsPane, FilesPane,
  ProjectsPane, ReviewsPane, TasksSidebar, TerminalPane, WorkspaceDialog,
} from "./harness-panes";
import { useTasksVisibility } from "./useTasksVisibility";
import { MAX_COLUMNS, SPLIT_LIMIT_MESSAGE, SPLIT_LIMIT_NOTICE_MS, splitLimitReached } from "./harness-split";
import { useDesktopShortcuts } from "./useDesktopShortcuts";
import { useDesktopWorkspace } from "./useDesktopWorkspace";
import {
  answer, cancel,
  chatHandle,
  type Health,
} from "@/lib/acp-client";
import { type AcpCommand } from "@/lib/acp";
import { useChatScroll } from "./useChatScroll";
import { enqueuePrompt } from "@/lib/prompt-queue";
import { usePromptQueue, steerOrInterrupt } from "./usePromptQueue";
import { useChatClose } from "./useChatClose";
import { type StoredSession } from "@/lib/sessions";
import { loadHistory, mergeHistory } from "@/lib/prompt-history";
import {
  basename,
  findWorkspace,
  type Workspace,
} from "@/lib/workspaces";

/** Whether the sidecar browser pane was open, restored after a reload. */
const BROWSER_OPEN_KEY = "graff.native.browser.open";

export default function GraffHarness() {
  const navigation = useResponsiveNavigation();
  const [chats, setChats] = useState<Chat[]>([{ id: 1, title: null, messages: [] }]);
  const [activeId, setActiveId] = useState(1);
  const [health, setHealth] = useState<Health | null>(null);
  // Every chat owns a `graff acp` child (the agent keeps one session per
  // process), so sessions, busy state and the spawned model are all per chat.
  const pageRef = useRef<string>(newPageToken());
  const sessionsRef = useRef(new Map<number, string>());
  // chat id → graff session name (the `--resume` target / sidebar identity).
  const sessionNamesRef = useRef(new Map<number, string>());
  const [sessionIds, setSessionIds] = useState<Record<number, string>>({});
  /** Per tab, the slash commands its agent advertised at session/new. */
  const [commands, setCommands] = useState<Record<number, AcpCommand[]>>({});
  const [terminalVisible, setTerminalVisible] = useState(false);
  const [terminalUsed, setTerminalUsed] = useState(false);
  const toggleTerminal = () => { setTerminalUsed(true); setTerminalVisible(v => !v); };
  const [catalogCommands, setCatalogCommands] = useState<AcpCommand[]>([]);
  const [stored, setStored] = useState<StoredSession[]>([]);
  const [storedTotal, setStoredTotal] = useState(0);
  const [busyIds, setBusyIds] = useState<ReadonlySet<number>>(() => new Set());
  // No hardcoded default: until graff/models answers, the agent's own model
  // resolution decides, and `current` from that call re-points the picker.
  const [models, setModels] = useState<PromptModel[]>([{ key: "", name: "Loading graff models…" }]);
  const [model, setModelKey] = useState<string | null>(process.env.NEXT_PUBLIC_GRAFF_MODEL || null);
  const [agentsOpen, setAgentsOpen] = useState(false);
  const [workingAgents, setWorkingAgents] = useState(0);
  const [tasksOpen, setTasksOpen] = useTasksVisibility();
  const [filesOpen, setFilesOpen] = useState(false);
  const [reviewsOpen, setReviewsOpen] = useState(false);
  const [claims, setClaims] = useState<{ kind: string; key: string; session: string }[]>([]);
  const [fileRequest, setFileRequest] = useState<{ path: string; n: number; changes?: boolean } | null>(null);
  const fileReqRef = useRef(0);
  // Shell-style prompt recall (ArrowUp in the composer), kept per browser so
  // a new tab or a reload still has the last prompts under the cursor.
  const [history, setHistory] = useState<string[]>([]);
  useEffect(() => {
    setHistory(loadHistory(window.localStorage));
  }, []);
  // Workspaces are the folders graff runs in. The list and the active pick
  // persist in desktop settings, with browser storage as a migration/fallback.
  // Refs mirror the state for the async paths (spawn, session list) that
  // must not read a stale closure.
  const [workspaces, setWorkspaces] = useState<Workspace[]>([]);
  const [activePath, setActivePath] = useState<string | null>(null);
  const workspacesRef = useRef<Workspace[]>([]);
  const activePathRef = useRef<string | null>(null);
  const [dialog, setDialog] = useState<null | { mode: "new" } | { mode: "settings" }>(null);
  // The sidecar browser: one Chrome tab per chat, and the pins the user
  // drops on it, which ride ahead of the chat's next prompt.
  const [browserOpen, setBrowserOpen] = useBrowserVisibility(BROWSER_OPEN_KEY, (chat) => {
    const target = chats.find(c => chat ? chatHandle(pageRef.current, c.id) === chat : c.id === activeId);
    if (target) { focusChat(target.id); setFilesOpen(false); } return target ? chatHandle(pageRef.current, target.id) : false;
  });
  // The conversation library: every saved chat, paged and searchable. It takes
  // the whole chat area, so opening it leaves the other side panes.
  const [projectsOpen, setProjectsOpen] = useState(false);
  const [conversationsOpen, setConversationsOpen] = useState(false);
  const [splitNotice, setSplitNotice] = useState<string | null>(null);
  // The pane-cap notice is a transient hint and clears itself; navigation
  // errors sharing this slot persist until replaced (#825).
  useEffect(() => {
    if (splitNotice !== SPLIT_LIMIT_MESSAGE) return;
    const timer = setTimeout(() => setSplitNotice(null), SPLIT_LIMIT_NOTICE_MS);
    return () => clearTimeout(timer);
  }, [splitNotice]);
  const openConversations = () => {
    setProjectsOpen(false);
    setAgentsOpen(false);
    setFilesOpen(false);
    setBrowserOpen(false);
    setConversationsOpen(true);
  };
  const [pinsByChat, setPinsByChat] = useState<Record<number, BrowserPin[]>>({});
  const pinsRef = useRef<Record<number, BrowserPin[]>>({});
  const { promptFocusRoot, requestPromptFocus } = useNavigationPromptFocus();
  const chatIdRef = useRef(1);
  const msgIdRef = useRef(0);
  // Split view: ordered visible chats, independent of focus. Each keeps its
  // own scroller and its own place in its transcript.
  const groups = useChatGroups(chats, activeId);
  const { panes, setPanes, direction: splitDirection } = groups;
  const groupsRef = useRef(groups);
  groupsRef.current = groups;
  const activeIdRef = useRef(activeId);
  activeIdRef.current = activeId;
  const [zoomedPane, setZoomedPane] = useState<number | null>(null);
  const chatsRef = useRef(chats);
  chatsRef.current = chats;
  const panesRef = useRef<number[]>([]);
  panesRef.current = panes;
  const [, setFollowing] = useState(true);
  const { queuesRef, queues, queueIdRef, setQueue, steerer, steerStatus, remove: removeQueued, edit: editQueued, beginEdit, cancelEdit, changeEdit, take: takeQueuedPrompt } = usePromptQueue();
  const [cancelError, setCancelError] = useState<Record<number, string>>({});
  // A model pick awaiting confirmation: switching respawns the tab's agent.
  const [pendingModel, setPendingModel] = useState<{ key: string; chatId: number } | null>(null);
  const pendingPickRef = useRef<{ key: string; chatId: number } | null>(null);
  const runningRef = useRef(new Set<number>());
  const queueResumesRef = useRef(new Set<number>());

  const chatThread = chats.find((c) => c.id === activeId) ?? chats[0];
  // Split positions are independent of keyboard focus.
  const columnIds = (panes.length ? panes : [chatThread.id])
    .filter((id, i, all) => all.indexOf(id) === i && chats.some((c) => c.id === id))
    .slice(0, MAX_COLUMNS);
  const { unread, started, completed } = useUnreadChats(chats.map(c => c.id), projectsOpen || conversationsOpen || agentsOpen || filesOpen ? [] : zoomedPane !== null ? [zoomedPane] : columnIds);
  const columnKey = columnIds.join(",");
  const { paneRef, tailing } = useChatScroll(chats, columnKey);
  const sessionId = sessionIds[chatThread.id] ?? null;
  const handleOf = (chatId: number) => chatHandle(pageRef.current, chatId);
  const setBusyFor = (chatId: number, on: boolean) =>
    setBusyIds((current) => {
      if (current.has(chatId) === on) return current;
      const next = new Set(current);
      if (on) next.add(chatId);
      else next.delete(chatId);
      return next;
    });
  const setChatModel = (chatId: number, key: string) =>
    setChats((current) => current.map((c) => (c.id === chatId ? { ...c, model: key } : c)));
  const lastAssistant = [...chatThread.messages].reverse().find((m): m is Extract<Msg, { role: "assistant" }> => m.role === "assistant");
  const setPins = (chatId: number, list: BrowserPin[]) => {
    pinsRef.current = { ...pinsRef.current, [chatId]: list };
    setPinsByChat(pinsRef.current);
  };

  const { adoptCatalog, requireSession, refreshStored, projectsReady, unwatchIdle } = useHarnessSessions({
    sessionsRef, sessionNamesRef, chatsRef, workspacesRef, activePathRef, pageRef, runningRef, model, activeId, handleOf, setModels, setCommands, setCatalogCommands, setChatModel, setModelKey, setSessionIds, setHealth, setWorkspaces, setActivePath, setChats, setStored, setStoredTotal,
    pendingPick: () => pendingPickRef.current ?? pendingModel,
  });
  useOpenWorkspace({
    chats, chatsRef, sessionNamesRef, chatIdRef, msgIdRef, groups, activeId,
    filesOpen, fileRequest, zoomedPane, setChats, setActiveId, setFilesOpen, setFileRequest, setZoomedPane,
  });

  const { openPath, openReference } = useReferenceNavigation({
    context: (id = activeIdRef.current) => ({ root: chatsRef.current.find(c => c.id === id)?.cwd ?? activePathRef.current ?? health?.cwd, chat: handleOf(id), focus: () => focusChat(id) }),
    hideOtherPanes: () => { setProjectsOpen(false); setAgentsOpen(false); setConversationsOpen(false); setReviewsOpen(false); },
    files: setFilesOpen, browser: setBrowserOpen, error: setSplitNotice,
    request: path => setFileRequest({ path, n: (fileReqRef.current += 1) }),
  });

  const openChanges = useCallback(() => {
    setProjectsOpen(false);
    setAgentsOpen(false);
    setBrowserOpen(false); setConversationsOpen(false);
    setFilesOpen(true);
    setFileRequest({ path: "", n: (fileReqRef.current += 1), changes: true });
  }, []);
  const toggleChanges = useCallback(() => {
    if (filesOpen && fileRequest?.changes) {
      setFilesOpen(false);
      setFileRequest(null);
      return;
    }
    openChanges();
  }, [filesOpen, fileRequest, openChanges]);

  const { changeModel, cancelPending, confirmPending } = createModelSwitcher({
    chatsRef, runningRef, pendingPickRef, activeChatId: () => chatThread.id,
    requireSession, setChatModel, setCancelError, setPendingModel,
  });
  const modelLabel = (key: string | null | undefined) => modelDisplayName(models, key);

  const runPrompt = createPromptRunner({ onStarted: started, onCompleted: completed,
    runningRef, steerer, setFollowing, chatsRef, model, msgIdRef, setChats, setBusyFor, setHistory, pinsRef, handleOf, setPins, requireSession, adoptCatalog, refreshStored, takeQueuedPrompt, setCancelError
  });
  const settings = useQuietSettings({ requireSession, handleOf, running: runningRef.current, apply: (catalog) => setModels(catalog.models) });

  const send = async (text: string, forChat?: number) => {
    const trimmed = text.trim();
    const chatId = forChat ?? chatThread.id;
    if (!trimmed || chatsRef.current.find(c => c.id === chatId)?.snapshot) return;
    await settings.wait(chatId);
    if (runningRef.current.has(chatId) || busyIds.has(chatId)) {
      setQueue(chatId, enqueuePrompt(queuesRef.current[chatId] ?? [], trimmed, (queueIdRef.current += 1)));
      return;
    }
    await runPrompt(chatId, trimmed);
  };

  const openChat = (id: number) => {
    setProjectsOpen(false); setAgentsOpen(false);
    const session = newSessionName();
    sessionNamesRef.current.set(id, session);
    const cwd = activePathRef.current ?? undefined;
    const ws = findWorkspace(workspacesRef.current, cwd);
    const next = [...chatsRef.current, { id, title: null, messages: [], model: ws?.model ?? model ?? undefined, session, cwd }];
    chatsRef.current = next; setChats(next);
    setZoomedPane(null);
    setActiveId(id); requestPromptFocus(id);
    setFilesOpen(false);
    setConversationsOpen(false);
    setFollowing(true);
    // The desktop defers agent + MCP boot until the first request.
    if (!window.graffDesktop) void requireSession(id).catch(() => undefined);
  };

  const selectStored = (id: number, cwd?: string) => {
    focusChat(id); setFilesOpen(false); setFollowing(true);
  };
  const savedConversation = useSavedConversation({
    context: `${activePath ?? ""}:${activeId}`,
    findOpen: (name, cwd) => chatsRef.current.find(c => c.session === name && (c.cwd ?? null) === (cwd ?? null))?.id,
    select: selectStored,
    restore: (name, cwd, loaded) => {
      const id = ++chatIdRef.current;
      const messages: Msg[] = loaded.messages.map(m => ({ id: ++msgIdRef.current, ...m }));
      sessionNamesRef.current.set(id, name);
      const next = [...chatsRef.current, { id, title: loaded.meta.title ?? name, messages, model: loaded.meta.model ?? undefined, session: name, cwd, snapshot: loaded.snapshot }];
      chatsRef.current = next; setChats(next);
      const host = loaded.snapshot ? null : resumeSplitTarget(chatsRef.current, groupsRef.current.groups, activeIdRef.current, cwd, activePathRef.current, MAX_COLUMNS);
      if (host != null) groupsRef.current.split(id, host, "right");
      selectStored(id, cwd);
    },
  });
  const openStored = (name: string, cwd = activePathRef.current ?? undefined) => savedConversation.open(name, cwd);

  const newChat = () => openChat((chatIdRef.current += 1));

  /** Focus a pane in place, or restore the selected workspace tab’s layout. */
  const focusChat = (id: number, focusPrompt = true) => {
    setProjectsOpen(false); setAgentsOpen(false);
    setConversationsOpen(false);
    const folder = chatsRef.current.find(chat => chat.id === id)?.cwd;
    if (folder && folder !== activePathRef.current) activateWorkspace(folder);
    if (!columnIds.includes(id) || (zoomedPane !== null && zoomedPane !== id)) setZoomedPane(null);
    setActiveId(id);
    if (focusPrompt) requestPromptFocus(id);
  };

  const tabDrag = useTabDrag((id, drop) => {
    if (drop.kind === "tab") { setChats(current => reorderChatGroups(current, groups.groups, id, drop.id, drop.after)); return; }
    if (!chatsRef.current.some(chat => chat.id === id)) return;
    let sourceId = id;
    const sourceGroup = groups.groups.find(group => group.ids.includes(id));
    const targetGroup = groups.groups.find(group => group.ids.includes(drop.id));
    if (id === drop.id || (sourceGroup && targetGroup && sourceGroup === targetGroup)) {
      if (splitLimitReached(columnIds.length)) { setSplitNotice(SPLIT_LIMIT_MESSAGE); return; }
      sourceId = (chatIdRef.current += 1);
      openChat(sourceId);
    }
    const source = groups.groups.find(group => group.ids.includes(sourceId))?.ids ?? [sourceId];
    const next = mergeChatGroups(columnIds, source, drop.id, drop.edge === "right" || drop.edge === "bottom");
    if (!next) { if (!source.some(pane => columnIds.includes(pane)) && columnIds.length + source.length > MAX_COLUMNS) setSplitNotice(SPLIT_LIMIT_MESSAGE); return; }
    setSplitNotice(null); setZoomedPane(null);
    groups.split(sourceId, drop.id, drop.edge); setActiveId(sourceId);
    const folder = chatsRef.current.find(chat => chat.id === sourceId)?.cwd;
    if (folder && folder !== activePathRef.current) activateWorkspace(folder);
  });

  /** Another chat beside the ones on screen, in the workspace the active
   * chat is in. Up to four columns; past that they are too narrow to read. */
  const addPane = (direction: "row" | "column" = splitDirection) => {
    if (splitLimitReached(columnIds.length)) {
      setSplitNotice(SPLIT_LIMIT_MESSAGE);
      return;
    }
    setSplitNotice(null);
    const id = (chatIdRef.current += 1);
    openChat(id);
    groups.split(id,activeId,direction === "row" ? "right" : "bottom");
  };

  /** The toolbar button: split when there is one column, close the split
   * when there are more. ⌘D always adds one. */
  const toggleSplit = () => {
    if (panesRef.current.length > 0) setPanes([]);
    else addPane();
  };

  const { closeChat, closeTab, reopenClosed, dropStored, pendingClose, cancelPendingClose, confirmPendingClose } = useChatClose({
    sessionsRef, sessionNamesRef, chatsRef, runningRef, chatIdRef, pinsRef, activePathRef, groups, columnIds, activeId,
    handleOf, setBusyFor, setQueue, steerer, setSessionIds, setCommands, setCancelError, setPinsByChat, setZoomedPane,
    setChats, setStored, openChat, focusChat, openStored, newChat, refreshStored, unwatchIdle,
  });

  const pickRecent = (id: string) => {
    void openStored(id);
  };

  const { switchWorkspace, addWorkspace, saveWorkspace, forgetWorkspace, newProjectChat, activateWorkspace } = workspaceActions({
    workspacesRef, activePathRef, chatsRef, chatIdRef, activeId, root: health?.cwd,
    setWorkspaces, setActivePath, setChats, setActiveId: focusChat, setFilesOpen, setDialog,
    refreshStored, requireSession, adoptCatalog, openChat,
  });
  useDesktopWorkspace(projectsReady, ({ cwd, file }) => {
    setProjectsOpen(false); setAgentsOpen(false); setConversationsOpen(false);
    addWorkspace(cwd);
    if (file) openPath(file);
  });

  const recents = sidebarRecents(stored, chats, unread);

  // The tab bar's folder chip is the *tab's* workspace; the sidebar's
  // switcher is the *active* one (where new tabs open). They differ only
  // after a switch, and each says so on hover.
  const cwdOf = (thread: Chat) => thread.cwd ?? activePath ?? health?.cwd;
  const workspaceNameOf = (thread: Chat) => {
    const dir = cwdOf(thread);
    return findWorkspace(workspaces, dir)?.name ?? (dir ? basename(dir) : "workspace");
  };
  const chatCwd = cwdOf(chatThread);
  useEffect(() => {
    let alive = true;
    const tick = () => {
      const params = new URLSearchParams();
      if (chatCwd) params.set("root", chatCwd);
      void fetch(`/api/claims?${params}`, { cache: "no-store" }).then((response) => response.json()).then((body: { claims?: { kind: string; key: string; session: string }[] }) => {
        if (alive && Array.isArray(body.claims)) setClaims(body.claims);
      }).catch(() => {});
    };
    tick();
    const id = setInterval(tick, 5000);
    return () => { alive = false; clearInterval(id); };
  }, [chatCwd]);
  const chatWorkspace = findWorkspace(workspaces, chatCwd);
  const workspaceName = chatWorkspace?.name ?? (chatCwd ? basename(chatCwd) : "workspace");
  const pinCount = (pinsByChat[chatThread.id] ?? []).length;
  const activeWorkspace = findWorkspace(workspaces, activePath);
  const sidebarWorkspace = activeWorkspace ?? (activePath ? { path: activePath, name: basename(activePath) } : undefined);

  const resumeQueue = (chatId: number) => void resumeQueuedPrompt(chatId, {
    pending: queueResumesRef.current,
    canStart: id => !runningRef.current.has(id) && chatsRef.current.some(chat => chat.id === id),
    wait: settings.wait, take: takeQueuedPrompt, run: runPrompt,
  });

  const steerQueued = (chat: number, item: number) => steerer.steer(chat, item, () => {
    const session = sessionsRef.current.get(chat);
    return session ? cancel(handleOf(chat), session) : Promise.reject(new Error("Session unavailable"));
  });

  // Stable per-column callbacks: the harness renders on every token, and a
  // fresh closure here would re-render every markdown block in every column.
  const threadCallbacks = useThreadCallbacks({
    onOpenPath: (path, chatId) => openReference(path, chatId),
    onAnswer: (chatId, text, cancelled) => { const live = sessionsRef.current.get(chatId); const ask = chats.find(c => c.id === chatId)?.messages.findLast(m => m.role === "assistant")?.turn.ask; if (live && ask) void answer(handleOf(chatId), live, { callId: ask.callId, text, cancelled }); },
    onEditPrompt: (chatId, n, text) => {
      const live = sessionsRef.current.get(chatId);
      if (live) void cancel(handleOf(chatId), live).catch(() => undefined);
      runningRef.current.delete(chatId);
      void runPrompt(chatId, text, { edit: n });
    },
  }, chats.map(c => c.id));

  const columnBody = (thread: Chat) => <ChatColumn key={thread.id} thread={thread}
    compact={columnIds.length > 1 || navigation.focusedMode || filesOpen || browserOpen || agentsOpen || reviewsOpen || !!(fileRequest?.changes)} following={tailing[thread.id] ?? true} register={paneRef(thread.id)}
    onOpenPath={threadCallbacks(thread.id).onOpenPath} onReview={openChanges}
    onAnswer={threadCallbacks(thread.id).onAnswer}
    onEditPrompt={threadCallbacks(thread.id).onEditPrompt}
    onRefresh={loaded => {
      const messages: Msg[] = loaded.messages.map(m => ({ id: ++msgIdRef.current, ...m }));
      setChats(current => current.map(c => c.id === thread.id && c.snapshot ? { ...c, messages } : c));
    }}
    onContinue={() => {
      const next = chatsRef.current.map(c => c.id === thread.id ? { ...c, snapshot: false } : c);
      chatsRef.current = next; setChats(next);
    }}
    prompt={{ demo: false, models, commands: commands[thread.id] ?? catalogCommands,
      root: cwdOf(thread), modelKey: paneComposerKey(thread.model, model, sessionsRef.current.has(thread.id), pendingModel, thread.id),
      onModelChange: key => changeModel(key, thread.id), onSend: text => void send(text, thread.id),
      onSetting: text => settings.change(thread.id, text),
      onSteerQueued: () => steerOrInterrupt(queuesRef.current[thread.id]?.[0], runningRef.current.has(thread.id), id => steerQueued(thread.id, id), () => {
        const live = sessionsRef.current.get(thread.id);
        if (live) void cancel(handleOf(thread.id), live).catch(() => undefined);
      }),
      history: mergeHistory(history, thread.messages.flatMap(m => m.role === "user" && m.origin !== "notification" ? [m.text] : [])),
      busy: busyIds.has(thread.id), onStop: () => {
        const live = sessionsRef.current.get(thread.id);
        if (!live) { setCancelError(current => ({ ...current, [thread.id]: "Nothing to interrupt yet." })); return; }
        void cancel(handleOf(thread.id), live).catch(err => {
          setCancelError(current => ({ ...current, [thread.id]: err instanceof Error ? err.message : "Could not interrupt the current turn" }));
        });
      },
    }}
    queue={{ items: queues[thread.id] ?? [], busy: busyIds.has(thread.id), status: steerStatus[thread.id], error: cancelError[thread.id],
      onBeginEdit: item => beginEdit(thread.id, item),
      onChangeEdit: (item, draft) => changeEdit(thread.id, item, draft),
      onEdit: (item, text) => { editQueued(thread.id, item, text); resumeQueue(thread.id); },
      onCancelEdit: item => { cancelEdit(thread.id, item); resumeQueue(thread.id); },
      onRemove: item => { removeQueued(thread.id, item); resumeQueue(thread.id); }, onSteer: item => steerQueued(thread.id, item),
    }}
    pins={(pinsByChat[thread.id] ?? []).length}
    onShowPins={() => { focusChat(thread.id, false); setFilesOpen(false); setBrowserOpen(true); }}
    onClearPins={() => setPins(thread.id, [])} health={health}
    onOpenProject={() => setDialog({ mode: "new" })} onProjects={() => setProjectsOpen(true)} onConversations={openConversations} />;

  useNotchObserver(chats, busyIds, focusChat);
  useDesktopShortcuts({ closeChat, newChat, reopenClosed, toggleSplit, focusChat, chats: groups.tabs.map(tab => ({ id: groups.focusOf(tab.id) })), activeId, columns: columnIds,
    split: direction => { setZoomedPane(null); addPane(direction); },
    zoomPane: () => setZoomedPane(value => value === null ? activeId : null),
    resizePane: delta => groups.resize(delta/4),
    toggleTerminal, equalize: groups.balance, openWorkspace: () => setDialog({ mode: "new" }),
  });

  const paneTodos = lastAssistant?.turn.todos ?? [];
  // Zoom only changes visibility; the split order is retained.
  const columns = (zoomedPane !== null ? [zoomedPane] : columnIds).map((id) => chats.find((c) => c.id === id)).filter((c): c is Chat => c !== undefined);


  return (
    <main ref={promptFocusRoot} data-graff-main data-workspace-ready={projectsReady} className="flex h-[100dvh] gap-0 bg-canvas p-2.5 text-ink lg:pl-0">
      <div {...navigation.panelProps}><SidebarNav
        onCloseNavigation={navigation.close} onCollapsedChange={navigation.onCollapsedChange}
        openSessions={navigation.sidebarVisible && <div className="mb-4">
          <p className="mb-1 px-4 text-[11px] font-medium text-ink-3">Open chats</p>
          <SessionTabs vertical chats={groups.tabs} activeId={groups.activeTab} agentsOpen={agentsOpen}
            busyIds={new Set(groups.groups.filter(group => group.ids.some(id => busyIds.has(id))).map(group => group.ids[0]))} unreadIds={unread}
            focusChat={id => focusChat(groups.focusOf(id))} closeChat={closeTab}
            onTabPointerDown={tabDrag.begin} onTabClickCapture={tabDrag.suppressClick} />
        </div>}
        fill
        className="bg-canvas"
        recents={recents.filter(recent => !chats.some(chat => chat.session === recent.id))}
        recentsTotal={storedTotal}
        agentsCount={workingAgents}
        activeTitle={chatThread.title}
        activeId={chatThread.session ?? null}
        onPick={pickRecent}
        onNewChat={newChat}
        onSeeAll={openConversations}
        activeNav={agentsOpen ? "agents" : projectsOpen ? "projects" : filesOpen ? (fileRequest?.changes ? "changes" : "workspace") : browserOpen ? "browser" : conversationsOpen ? "conversations" : "home"}
        onNavigate={(key) => {
          if (key === "home") requestPromptFocus(activeId);
          if (key === "agents") {
            setProjectsOpen(false); setFilesOpen(false); setBrowserOpen(false); setConversationsOpen(false);
            setAgentsOpen(open => !open);
            return;
          }
          setAgentsOpen(false);
          setProjectsOpen(key === "projects");
          if (key === "changes") { openChanges(); return; }
          if (key === "workspace") setFileRequest(null);
          setFilesOpen(key === "workspace");
          setBrowserOpen(key === "browser");
          setConversationsOpen(key === "conversations");
        }}
        workspace={sidebarWorkspace}
        workspaces={workspaces}
        onSwitchWorkspace={switchWorkspace}
        onArchiveRecent={(id) => dropStored(id, true)}
        onDeleteRecent={(id) => dropStored(id, false)}
        onNewWorkspace={() => setDialog({ mode: "new" })}
        onWorkspaceSettings={() => setDialog(sidebarWorkspace ? { mode: "settings" } : { mode: "new" })}
        footerControls={<AppSettings sidebar />}
      /></div>

      <div className="flex min-w-0 flex-1 flex-col gap-2.5">
        {tabDrag.overlay}
        <HarnessChrome sidebarVisible={navigation.sidebarVisible} navigationToggle={navigation.trigger} unreadIds={unread} onTabPointerDown={tabDrag.begin} onTabClickCapture={tabDrag.suppressClick} chats={groups.tabs} activeId={groups.activeTab} busyIds={new Set(groups.groups.filter(group => group.ids.some(id => busyIds.has(id))).map(group => group.ids[0]))} focusChat={id => focusChat(groups.focusOf(id))} closeChat={closeTab} newChat={newChat}
          conversationsOpen={conversationsOpen} openConversations={openConversations} split={panes.length > 0} toggleSplit={toggleSplit}
          filesOpen={filesOpen} onFiles={() => { setAgentsOpen(false); setFileRequest(null); setProjectsOpen(false); setBrowserOpen(false); setConversationsOpen(false); setFilesOpen(fileRequest?.changes ? true : !filesOpen); }}
          chatCwd={chatCwd} workspaceName={workspaceName} onFolder={() => setDialog({ mode: "new" })} openChanges={toggleChanges} changesOpen={!!(filesOpen && fileRequest?.changes)}
          reviewsOpen={reviewsOpen} onReviews={() => { setAgentsOpen(false); setProjectsOpen(false); setBrowserOpen(false); setConversationsOpen(false); setFilesOpen(false); setReviewsOpen(open => !open); }}
          browserOpen={browserOpen} onBrowser={() => { setAgentsOpen(false); setProjectsOpen(false); setConversationsOpen(false); setFilesOpen(false); setBrowserOpen(open => !open); }} pinCount={pinCount}
          terminalVisible={terminalVisible} toggleTerminal={toggleTerminal} agentsOpen={agentsOpen}
          workingAgents={workingAgents}
          tasksOpen={tasksOpen} taskCount={paneTodos.length} onTasks={() => { setAgentsOpen(false); setTasksOpen(!tasksOpen); }}
          splitNotice={splitNotice}
          onAgents={() => { setProjectsOpen(false); setAgentsOpen(!agentsOpen); setFilesOpen(false); setBrowserOpen(false); setConversationsOpen(false); }} />
        <ConversationOpenNotice request={savedConversation.request} onCancel={savedConversation.cancel} onRetry={savedConversation.retry} />
        <div className="flex min-h-0 flex-1 gap-2.5">
          {projectsOpen ? (
            <ProjectsPane workspaces={workspaces} current={activePath} onOpen={() => setDialog({ mode: "new" })}
              onClose={() => setProjectsOpen(false)}
              onContinue={path => { switchWorkspace(path); openConversations(); }}
              onNewChat={newProjectChat} />
          ) : conversationsOpen ? (
            <section className="flex min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page">
              <ConversationsPane
                root={chatCwd}
                activeId={chatThread.session ?? null}
                onPick={pickRecent}
                onNewChat={() => {
                  setConversationsOpen(false);
                  newChat();
                }}
              />
            </section>
          ) : null}
          <div className="min-h-0 min-w-0 flex-1" style={{ display: projectsOpen || conversationsOpen || agentsOpen ? "none" : "flex" }}>
            <ChatSplitLayout threads={columns} liveChatIds={chats.map(chat => chat.id)} activeId={activeId} direction={splitDirection} layout={groups.tree} onLayoutChange={groups.setTree}
              onFocus={id => focusChat(id, false)} onClose={closeChat} folder={thread => ({name: workspaceNameOf(thread), path: cwdOf(thread)})}
              body={columnBody} split={columnIds.length > 1} claims={claims} />
          </div>

          {agentsOpen && !projectsOpen && !filesOpen && !browserOpen && !conversationsOpen && <AgentsPane key={chatCwd} root={chatCwd} fullWidth onOccupancy={setWorkingAgents} onClose={() => setAgentsOpen(false)} />}
          {filesOpen && !projectsOpen && !conversationsOpen && !reviewsOpen && (fileRequest?.changes ? <ChangesPane root={chatThread.cwd} onClose={() => setFilesOpen(false)} /> : <FilesPane root={chatThread.cwd} requested={fileRequest} onClose={() => setFilesOpen(false)} />)}
          {reviewsOpen && !projectsOpen && !conversationsOpen && <ReviewsPane root={chatThread.cwd} onClose={() => setReviewsOpen(false)} />}

          {browserOpen && !projectsOpen && !conversationsOpen && (
            <BrowserPane
              key={chatThread.id}
              chat={handleOf(chatThread.id)}
              memoryKey={chatCwd}
              pins={pinsByChat[chatThread.id] ?? []}
              onPinsChange={(next) => setPins(chatThread.id, next)}
              onAsk={() => void send("Make the changes I pinned in the browser.")}
              onClose={() => setBrowserOpen(false)}
            />
          )}

          {!agentsOpen && !projectsOpen && !filesOpen && !browserOpen && !conversationsOpen && tasksOpen && (
            <TasksSidebar items={paneTodos} onClose={() => setTasksOpen(false)} />
          )}
        </div>
        {terminalUsed && chatCwd && <TerminalPane key={chatCwd} cwd={chatCwd} visible={terminalVisible} onHide={() => setTerminalVisible(false)} />}
      </div>

      {pendingModel && (
        <ModelSwitchDialog
          from={modelLabel(chatsRef.current.find(c => c.id === pendingModel.chatId)?.model ?? model)}
          to={modelLabel(pendingModel.key)}
          onCancel={cancelPending}
          onConfirm={() => confirmPending(pendingModel)}
        />
      )}
      {pendingClose && (
        <CloseConfirmDialog
          tabs={pendingClose.ids.length}
          workers={pendingClose.workers}
          onCancel={cancelPendingClose}
          onConfirm={confirmPendingClose}
        />
      )}
      {dialog && (
        <WorkspaceDialog
          mode={dialog.mode}
          workspace={dialog.mode === "settings" ? sidebarWorkspace : undefined}
          startPath={activePath ?? health?.home ?? undefined}
          models={models}
          onClose={() => setDialog(null)}
          onPick={path => { addWorkspace(path); setProjectsOpen(false); }}
          onSave={saveWorkspace}
          onForget={forgetWorkspace}
        />
      )}
    </main>
  );
}
