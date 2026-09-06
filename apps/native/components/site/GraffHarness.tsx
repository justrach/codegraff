"use client";

import { workspaceActions } from "./harness-workspace-actions";
import ProjectsPane from "./ProjectsPane";
import { useSavedConversation, ConversationOpenNotice } from "./useSavedConversation";
import { restoreProjects, persistProjects } from "@/lib/project-preferences";
import { createTurnPainter } from "@/lib/turn-painter";
import { useQuietSettings } from "./useQuietSettings";
import HarnessChrome from "./HarnessChrome";
import ChatSplitLayout from "./ChatSplitLayout";
import TerminalPane from "./TerminalPane";
import { sidebarRecents, sessionFooterTitle } from "./harness-sidebar";
import AgentsPane from "./AgentsPane";
import { newPageToken, newSessionName, type Chat, type Msg } from "./harness-types";
import ChangesPane from "./ChangesPane";
import { useBrowserVisibility } from "./useBrowserVisibility";
import { useCallback, useEffect, useMemo, useRef, useState, type RefObject } from "react";
import PromptBar, { type PromptModel } from "@/components/primitives/PromptBar";
import SidebarNav from "@/components/primitives/SidebarNav";
import ConversationsPane from "@/components/site/ConversationsPane";
import FilesPane from "@/components/site/FilesPane";
import BrowserPane from "@/components/site/DesktopBrowserPane";
import { annotationsBlock, type BrowserPin } from "@/lib/browser/annotations";
import { browserClose, browserHandle, browserNav } from "@/lib/browser-client";
import TaskRows from "@/components/primitives/TaskRows";
import ChatTranscript from "./ChatTranscript";
import { useDesktopShortcuts } from "./useDesktopShortcuts";
import EmptyState from "@/components/site/ChatEmpty";
import {
  cancel,
  chatHandle,
  checkHealth,
  disposePage,
  disposeSession,
  ensureSession,
  fetchModels,
  prompt,
  type Health,
} from "@/lib/acp-client";
import { applyAcpUpdate, emptyTurn, finishAcpTurn, type AcpCommand, type AssistantTurn } from "@/lib/acp";
import { isFollowingTail, pinScrollerTail } from "@/lib/follow-scroll";
import { dropQueuedPrompt, enqueuePrompt, shiftQueuedPrompt, type QueuedPrompt } from "@/lib/prompt-queue";
import { dateGroup, listSessionsPage, relativeTime, removeSession, type StoredSession } from "@/lib/sessions";
import { loadHistory, mergeHistory, pushHistory, saveHistory } from "@/lib/prompt-history";
import WorkspaceDialog from "@/components/site/WorkspaceDialog";
import {
  basename,
  findWorkspace,
  shellQuote,
  upsertWorkspace,
  type Workspace,
} from "@/lib/workspaces";

/** Whether the sidecar browser pane was open, restored after a reload. */
const BROWSER_OPEN_KEY = "graff.native.browser.open";

/** Columns the split view will show at once, the active chat included. */
const MAX_COLUMNS = 4;

/** Rows the sidebar previews; the library pages the rest. */
const SIDEBAR_PAGE = 12;

export default function GraffHarness() {
  const [chats, setChats] = useState<Chat[]>([{ id: 1, title: null, messages: [] }]);
  const [activeId, setActiveId] = useState(1);
  const [health, setHealth] = useState<Health | null>(null);
  // Every tab owns a `graff acp` child (the agent keeps one session per
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
  const [filesOpen, setFilesOpen] = useState(false);
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
  const [copiedResume, setCopiedResume] = useState(false);
  // The sidecar browser: one Chrome tab per chat, and the pins the user
  // drops on it, which ride ahead of the chat's next prompt.
  const [browserOpen, setBrowserOpen] = useBrowserVisibility(BROWSER_OPEN_KEY, (chat) => {
    const target = chats.find(c => chatHandle(pageRef.current, c.id) === chat);
    if (target) { focusChat(target.id); setFilesOpen(false); } return !!target;
  });
  // The conversation library: every saved chat, paged and searchable. It takes
  // the whole chat area, so opening it leaves the other side panes.
  const [projectsOpen, setProjectsOpen] = useState(false);
  const [conversationsOpen, setConversationsOpen] = useState(false);
  const openConversations = () => {
    setProjectsOpen(false);
    setAgentsOpen(false);
    setFilesOpen(false);
    setBrowserOpen(false);
    setConversationsOpen(true);
  };
  const [pinsByChat, setPinsByChat] = useState<Record<number, BrowserPin[]>>({});
  const pinsRef = useRef<Record<number, BrowserPin[]>>({});
  const chatIdRef = useRef(1);
  const msgIdRef = useRef(0);
  // Split view: ordered visible chats, independent of focus. Each keeps its
  // own scroller and its own place in its transcript.
  const [panes, setPanes] = useState<number[]>([]);
  const [splitDirection, setSplitDirection] = useState<"row" | "column">("row");
  const [zoomedPane, setZoomedPane] = useState(false);
  const [paneWeights, setPaneWeights] = useState<Record<number, number>>({});
  const scrollEls = useRef(new Map<number, HTMLDivElement>());
  const [tailing, setTailing] = useState<Record<number, boolean>>({});
  const paneRef = (id: number) => (el: HTMLDivElement | null) => {
    if (el) scrollEls.current.set(id, el);
    else scrollEls.current.delete(id);
  };
  const chatsRef = useRef(chats);
  chatsRef.current = chats;
  const panesRef = useRef<number[]>([]);
  panesRef.current = panes;
  const [following, setFollowing] = useState(true);
  const queuesRef = useRef<Record<number, QueuedPrompt[]>>({});
  const [queues, setQueues] = useState<Record<number, QueuedPrompt[]>>({});
  const queueIdRef = useRef(0);
  const runningRef = useRef(new Set<number>());
  // Closed tabs, oldest first, for the reopen shortcut.
  const closedRef = useRef<{ session: string | null; cwd?: string; resumable: boolean }[]>([]);

  const chatThread = chats.find((c) => c.id === activeId) ?? chats[0];
  // Split positions are independent of keyboard focus.
  const columnIds = (panes.length ? panes : [chatThread.id])
    .filter((id, i, all) => all.indexOf(id) === i && chats.some((c) => c.id === id))
    .slice(0, MAX_COLUMNS);
  const columnKey = columnIds.join(",");
  const active = chatThread.messages.length > 0;
  const busy = busyIds.has(chatThread.id);
  const chatModel = chatThread.model ?? model ?? undefined;
  const sessionId = sessionIds[chatThread.id] ?? null;
  const queued = queues[chatThread.id] ?? [];
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
  // A resumed session's prompts came from its file, not this browser; fold
  // them in so ArrowUp walks the conversation on screen first.
  const composerHistory = useMemo(
    () => mergeHistory(history, chatThread.messages.flatMap((m) => (m.role === "user" ? [m.text] : []))),
    [history, chatThread.messages],
  );
  const setQueue = (chatId: number, list: QueuedPrompt[]) => {
    queuesRef.current = { ...queuesRef.current, [chatId]: list };
    setQueues(queuesRef.current);
  };
  const setPins = (chatId: number, list: BrowserPin[]) => {
    pinsRef.current = { ...pinsRef.current, [chatId]: list };
    setPinsByChat(pinsRef.current);
  };

  const adoptCatalog = async (chatId: number) => {
    // Use the provider and model actually resolved by graff.
    try {
      const { models: live, current, commands: available } = await fetchModels(sessionsRef.current.has(chatId) ? handleOf(chatId) : undefined, activePathRef.current ?? undefined);
      if (live.length > 0) setModels(live);
      if (available?.length) { setCatalogCommands(available); setCommands(old => ({ ...old, [chatId]: available })); }
      if (current) {
        setChatModel(chatId, current);
        setModelKey((fallback) => fallback ?? current);
      }
    } catch {
      // Do not invent a selected model when the catalog is unavailable.
    }
  };

  // Refresh the catalog on focus. If its agent was
  // not up yet, or the page outlived a restart — would show the fallback
  // for good, so ask again whenever the window comes back to the front.
  const catalogRef = useRef({ adopt: (_: number) => {}, activeId: 1 });
  useEffect(() => {
    const again = () => {
      if (document.visibilityState === "hidden") return;
      catalogRef.current.adopt(catalogRef.current.activeId);
    };
    window.addEventListener("focus", again);
    document.addEventListener("visibilitychange", again);
    return () => {
      window.removeEventListener("focus", again);
      document.removeEventListener("visibilitychange", again);
    };
  }, []);

  const requireSession = async (chatId: number, reset = false, key?: string): Promise<string> => {
    const live = sessionsRef.current.get(chatId);
    if (!reset && live) return live;
    const chat = chatsRef.current.find((c) => c.id === chatId);
    // A tab spawns where it was opened; the first tab, opened before the
    // workspace list loaded, takes the active workspace.
    const cwd = chat?.cwd ?? activePathRef.current ?? undefined;
    const ws = findWorkspace(workspacesRef.current, cwd);
    const spawnModel = key ?? chat?.model ?? ws?.model ?? model ?? undefined;
    const { sessionId: id, commands } = await ensureSession(handleOf(chatId), {
      model: spawnModel,
      reset,
      resume: sessionNamesRef.current.get(chatId),
      cwd,
      yolo: ws?.yolo,
      mcp: ws?.mcp,
    });
    sessionsRef.current.set(chatId, id);
    setSessionIds((current) => ({ ...current, [chatId]: id }));
    // Populate the command menu from this agent's advertisement.
    if (commands.length > 0) setCommands((current) => ({ ...current, [chatId]: commands }));
    setHealth({ ok: true });
    await adoptCatalog(chatId);
    return id;
  };

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const h = await checkHealth();
      if (cancelled) return;
      setHealth(h);
      if (!h.ok) return;
      // The server's default workspace is always a row; the remembered pick
      // wins when it is still listed, else the default is active.
      const root = h.cwd ?? "";
      const savedProjects = await restoreProjects(window.localStorage);
      if (cancelled) return;
      let list = savedProjects.list;
      if (root && !findWorkspace(list, root)) list = upsertWorkspace(list, { path: root, name: basename(root) });
      const remembered = savedProjects.active;
      const active = findWorkspace(list, remembered)?.path ?? findWorkspace(list, root)?.path ?? list[0]?.path ?? null;
      workspacesRef.current = list;
      activePathRef.current = active;
      setWorkspaces(list);
      setActivePath(active);
      persistProjects(window.localStorage, list, active);
      if (active) setChats((current) => current.map((c) => (c.id === 1 && !c.cwd ? { ...c, cwd: active } : c)));
      void refreshStored();
      try {
        const session = newSessionName();
        sessionNamesRef.current.set(1, session);
        setChats((current) => current.map((c) => (c.id === 1 ? { ...c, session } : c)));
        if (window.graffDesktop) { await adoptCatalog(1); return; } // No coding session needed.
        await requireSession(1);
        if (cancelled) return;
        await adoptCatalog(1);
      } catch (err) {
        if (!cancelled) {
          setHealth({ ok: false, detail: err instanceof Error ? err.message : String(err) });
        }
      }
    })();
    void refreshStored();
    // Reap this page's agents when it goes away — without this every reload
    // leaves a `graff acp` (and its MCP children) running under the dev server.
    const page = pageRef.current;
    const reap = () => disposePage(page);
    window.addEventListener("pagehide", reap);
    return () => {
      cancelled = true;
      window.removeEventListener("pagehide", reap);
    };
    // The first tab's agent is spawned once per mount; later tabs spawn their
    // own on creation, and a model change respawns only the active tab's.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /** Re-read the active workspace's session directory; tabs adopt the
   * titles graff saved. */
  const refreshStored = async () => {
    try {
      const page = await listSessionsPage({ root: activePathRef.current ?? undefined, limit: SIDEBAR_PAGE });
      setStored(page.sessions);
      setStoredTotal(page.total);
      setChats((current) =>
        current.map((c) => {
          if (c.titledByModel) return c;
          const saved = c.session ? page.sessions.find((s) => s.name === c.session) : undefined;
          return saved?.title && saved.title !== c.title ? { ...c, title: saved.title } : c;
        }),
      );
    } catch {
      // the sidebar keeps its last list
    }
  };

  const openPath = useCallback((path: string) => {
    setProjectsOpen(false); setAgentsOpen(false); setBrowserOpen(false);
    setConversationsOpen(false);
    setFilesOpen(true);
    setFileRequest({ path, n: (fileReqRef.current += 1) });
  }, []);

  const openChanges = useCallback(() => {
    setProjectsOpen(false);
    setAgentsOpen(false);
    setBrowserOpen(false); setConversationsOpen(false);
    setFilesOpen(true);
    setFileRequest({ path: "", n: (fileReqRef.current += 1), changes: true });
  }, []);

  const changeModel = (key: string, forChat?: number) => {
    // New tabs inherit the pick; the tab respawns its agent with it
    // (a fresh context — the agent cannot swap models mid-session).
    const chatId = forChat ?? chatThread.id;
    setModelKey(key);
    setChatModel(chatId, key);
    void requireSession(chatId, true, key)
      .then(() => adoptCatalog(chatId))
      .catch(() => undefined);
  };

  const patchAssistant = (chatId: number, msgId: number, next: AssistantTurn) => {
    setChats((current) =>
      current.map((c) =>
        c.id !== chatId
          ? c
          : {
              ...c,
              messages: c.messages.map((m) => (m.role === "assistant" && m.id === msgId ? { ...m, turn: next } : m)),
            },
      ),
    );
  };

  const runPrompt = async (chatId: number, trimmed: string) => {
    runningRef.current.add(chatId);
    setFollowing(true);
    const thread = chatsRef.current.find((c) => c.id === chatId);
    const spawnModel = thread?.model ?? model ?? undefined;
    const userId = (msgIdRef.current += 1);
    const asstId = (msgIdRef.current += 1);
    const title = thread?.title ?? (trimmed.length > 30 ? `${trimmed.slice(0, 30).trimEnd()}…` : trimmed);
    // The first prompt of a tab names it, in the model's words.
    if (!thread?.title) nameChat(chatId, trimmed, thread?.cwd);
    setChats((current) =>
      current.map((c) =>
        c.id !== chatId
          ? c
          : {
              ...c,
              title,
              messages: [
                ...c.messages,
                { id: userId, role: "user", text: trimmed },
                { id: asstId, role: "assistant", turn: { ...emptyTurn(), model: spawnModel, startedAt: Date.now() } },
              ],
            },
      ),
    );
    setBusyFor(chatId, true);
    setHistory((current) => {
      const next = pushHistory(current, trimmed);
      saveHistory(window.localStorage, next);
      return next;
    });
    // Pins from the sidecar ride behind the prompt, with the tab's handle
    // so the agent can drive the same page; they are spent on send. Behind,
    // not ahead: graff titles the session from the message's first line.
    let wire = trimmed;
    const pins = /^\/(effort|reasoning|fast)(?:\s|$)/.test(trimmed) ? [] : pinsRef.current[chatId] ?? [];
    if (pins.length > 0) {
      const handle = await browserHandle(handleOf(chatId)).catch(() => null);
      wire = `${trimmed}\n\n${annotationsBlock(pins, handle)}`;
      setPins(chatId, []);
    }
    let turn: AssistantTurn = { ...emptyTurn(), model: spawnModel, startedAt: Date.now() };
    const painter = createTurnPainter<AssistantTurn>(next => patchAssistant(chatId, asstId, next));
    const startedAt = Date.now();
    try {
      const id = await requireSession(chatId);
      turn = { ...turn, connected: true, lastUpdateAt: Date.now() };
      painter.update(turn);
      for await (const update of prompt(handleOf(chatId), id, wire)) {
        turn = applyAcpUpdate(turn, update);
        if (turn.thoughtMs === undefined && turn.status !== "thinking") turn = { ...turn, thoughtMs: Date.now() - startedAt };
        painter.update(turn);
      }
      // The turn carried pins, so the agent most likely changed the page:
      // reload the chat's tab so the pane shows the result without a click.
      if (pins.length > 0) void browserNav(handleOf(chatId), "reload").catch(() => undefined);
      if (/^\/(effort|reasoning|fast)(?:\s|$)/.test(trimmed)) void adoptCatalog(chatId);
      turn = finishAcpTurn(turn);
      painter.finish(turn);
    } catch (err) {
      turn = finishAcpTurn({ ...turn, error: err instanceof Error ? err.message : String(err), status: "error" });
      painter.finish(turn);
    } finally {
      painter.dispose();
      runningRef.current.delete(chatId);
      setBusyFor(chatId, false);
      void refreshStored();
      setTimeout(() => void refreshStored(), 2500);
      const { next, rest } = shiftQueuedPrompt(queuesRef.current[chatId] ?? []);
      setQueue(chatId, rest);
      if (next) void runPrompt(chatId, next.text);
    }
  };

  const nameChat = (chatId: number, prompt: string, cwd: string | undefined) => {
    void fetch("/api/title", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ prompt, cwd }) })
      .then(res => res.ok ? res.json() : null).then(body => {
        const title = body?.title?.trim();
        if (title) setChats(current => current.map(c => c.id === chatId ? { ...c, title, titledByModel: true } : c));
      }).catch(() => undefined);
  };
  const settings = useQuietSettings({ requireSession, handleOf, running: runningRef.current, apply: (catalog) => setModels(catalog.models) });

  const send = async (text: string, forChat?: number) => {
    const trimmed = text.trim();
    const chatId = forChat ?? chatThread.id;
    if (!trimmed) return;
    await settings.wait(chatId);
    if (runningRef.current.has(chatId) || busyIds.has(chatId)) {
      setQueue(chatId, enqueuePrompt(queuesRef.current[chatId] ?? [], trimmed, (queueIdRef.current += 1)));
      return;
    }
    await runPrompt(chatId, trimmed);
  };

  const openChat = (id: number) => {
    setProjectsOpen(false);
    const session = newSessionName();
    sessionNamesRef.current.set(id, session);
    const cwd = activePathRef.current ?? undefined;
    const ws = findWorkspace(workspacesRef.current, cwd);
    const next = [...chatsRef.current, { id, title: null, messages: [], model: ws?.model ?? model ?? undefined, session, cwd }];
    chatsRef.current = next; setChats(next);
    setPanes(current => current.map(pane => pane === activeId ? id : pane));
    setActiveId(id);
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
      const next = [...chatsRef.current, { id, title: loaded.meta.title ?? name, messages, model: loaded.meta.model ?? undefined, session: name, cwd }];
      chatsRef.current = next; setChats(next);
      selectStored(id, cwd);
      void requireSession(id, false, loaded.meta.model ?? undefined).catch(() => undefined);
    },
  });
  const openStored = (name: string, cwd = activePathRef.current ?? undefined) => savedConversation.open(name, cwd);

  const newChat = () => openChat((chatIdRef.current += 1));

  /** Focus a visible chat in place, or replace only the focused split. */
  const focusChat = (id: number) => {
    setProjectsOpen(false);
    setConversationsOpen(false);
    const folder = chatsRef.current.find(chat => chat.id === id)?.cwd;
    if (folder && folder !== activePathRef.current) activateWorkspace(folder);
    setPanes(current => current.includes(id) ? current : current.map(pane => pane === activeId ? id : pane));
    setActiveId(id);
  };

  /** Bring back the tab that was closed last, resuming its graff session so
   * the conversation comes back with it. A tab that never got a message has
   * nothing saved, so it returns as a fresh one. */
  const reopenClosed = () => {
    const stack = closedRef.current;
    const last = stack[stack.length - 1];
    if (!last) return;
    closedRef.current = stack.slice(0, -1);
    if (last.session && last.resumable) void openStored(last.session, last.cwd);
    else newChat();
  };

  /** Another chat beside the ones on screen, in the workspace the active
   * chat is in. Up to four columns; past that they are too narrow to read. */
  const addPane = () => {
    if (columnIds.length >= MAX_COLUMNS) return;
    const id = (chatIdRef.current += 1);
    openChat(id);
    setPanes([...columnIds, id]);
  };

  /** The toolbar button: split when there is one column, close the split
   * when there are more. ⌘D always adds one. */
  const toggleSplit = () => {
    if (panesRef.current.length > 0) setPanes([]);
    else addPane();
  };

  const dropChat = (id: number) => {
    sessionsRef.current.delete(id);
    sessionNamesRef.current.delete(id);
    runningRef.current.delete(id);
    setQueue(id, []);
    setSessionIds((current) => {
      const { [id]: _gone, ...rest } = current;
      return rest;
    });
    setBusyFor(id, false);
    setPins(id, []);
    void disposeSession(handleOf(id));
    void browserClose(handleOf(id)).catch(() => undefined);
  };

  const closeChat = (id: number) => {
    const visible = columnIds.filter(pane => pane !== id);
    setPanes(visible.length > 1 ? visible : []);
    const going = chatsRef.current.find((c) => c.id === id);
    if (going) {
      // Keep the last few closed tabs; a tab that got as far as a message
      // has a graff session on disk to resume, an empty one has nothing.
      closedRef.current = [
        ...closedRef.current.slice(-9),
        { session: going.session ?? null, cwd: going.cwd, resumable: going.messages.length > 0 },
      ];
    }
    dropChat(id);
    const remaining = chatsRef.current.filter((c) => c.id !== id);
    chatsRef.current = remaining;
    if (remaining.length === 0) {
      setChats([]);
      openChat((chatIdRef.current += 1));
      return;
    }
    setChats(remaining);
    if (id === activeId) focusChat(visible[Math.min(columnIds.indexOf(id), visible.length - 1)] ?? remaining[remaining.length - 1].id);
  };

  const pickRecent = (id: string) => {
    void openStored(id);
  };

  /** Put a saved chat away, or remove it for good. Its tab closes with it,
   * and the row goes at once rather than after the next poll. */
  const dropStored = (name: string, archive: boolean) => {
    const cwd = activePathRef.current ?? undefined;
    const open = chatsRef.current.find((c) => c.session === name && (c.cwd ?? null) === (cwd ?? null));
    if (open) closeChat(open.id);
    setStored((current) => current.filter((s) => s.name !== name));
    void removeSession(name, { root: cwd, archive })
      .catch(() => undefined)
      .then(() => refreshStored());
  };

  const { switchWorkspace, addWorkspace, saveWorkspace, forgetWorkspace, newProjectChat, activateWorkspace } = workspaceActions({
    workspacesRef, activePathRef, chatsRef, chatIdRef, activeId, root: health?.cwd,
    setWorkspaces, setActivePath, setChats, setActiveId: focusChat, setFilesOpen, setDialog,
    refreshStored, requireSession, adoptCatalog, openChat,
  });

  /** The footer names the tab's own graff session; clicking it copies the
   * command that continues the same conversation in a terminal. */
  const copyResume = () => {
    const name = chatThread.session;
    if (!name || typeof navigator === "undefined" || !navigator.clipboard) return;
    const cmd = chatThread.cwd ? `cd ${shellQuote(chatThread.cwd)} && graff --resume ${name}` : `graff --resume ${name}`;
    void navigator.clipboard
      .writeText(cmd)
      .then(() => {
        setCopiedResume(true);
        window.setTimeout(() => setCopiedResume(false), 1400);
      })
      .catch(() => undefined);
  };

  // Every visible column follows its own tail: jump to the bottom when it
  // appears, and stop following as soon as the reader scrolls up in it.
  const initializedScrollers = useRef(new WeakSet<HTMLElement>());
  useEffect(() => {
    const off: (() => void)[] = [];
    for (const id of columnKey.split(",").filter(Boolean).map(Number)) {
      const el = scrollEls.current.get(id);
      if (!el) continue;
      if (!initializedScrollers.current.has(el)) {
        el.scrollTop = el.scrollHeight;
        initializedScrollers.current.add(el);
        setTailing(current => ({ ...current, [id]: true }));
      }
      const onScroll = () => {
        const next = isFollowingTail(el);
        setTailing((current) => (current[id] === next ? current : { ...current, [id]: next }));
      };
      el.addEventListener("scroll", onScroll, { passive: true });
      off.push(() => el.removeEventListener("scroll", onScroll));
    }
    return () => off.forEach((stop) => stop());
  }, [columnKey]);

  useEffect(() => {
    for (const id of columnKey.split(",").filter(Boolean).map(Number)) {
      pinScrollerTail(scrollEls.current.get(id) ?? null, tailing[id] ?? true);
    }
  }, [chats, tailing, columnKey]);

  const recents = sidebarRecents(stored, chats);

  // The tab bar's folder chip is the *tab's* workspace; the sidebar's
  // switcher is the *active* one (where new tabs open). They differ only
  // after a switch, and each says so on hover.
  const cwdOf = (thread: Chat) => thread.cwd ?? activePath ?? health?.cwd;
  const workspaceNameOf = (thread: Chat) => {
    const dir = cwdOf(thread);
    return findWorkspace(workspaces, dir)?.name ?? (dir ? basename(dir) : "workspace");
  };
  const chatCwd = cwdOf(chatThread);
  const chatWorkspace = findWorkspace(workspaces, chatCwd);
  const workspaceName = chatWorkspace?.name ?? (chatCwd ? basename(chatCwd) : "workspace");
  const pinCount = (pinsByChat[chatThread.id] ?? []).length;
  const activeWorkspace = findWorkspace(workspaces, activePath);
  const sidebarWorkspace = activeWorkspace ?? (activePath ? { path: activePath, name: basename(activePath) } : undefined);
  const footerTitle = sessionFooterTitle(chatThread.session, sessionId, chatCwd);

  /** One chat column: its transcript (or the empty state) and its composer.
   * A plain function, not a component, so the split view can render two of
   * them without React remounting either on every parent render. */
  const columnBody = (thread: Chat) => {
    const isFollowing = tailing[thread.id] ?? true;
    const hasMessages = thread.messages.length > 0;
    const compactPane = columnIds.length > 1;
    const threadBusy = busyIds.has(thread.id);
    const threadModel = thread.model ?? model ?? undefined;
    const threadQueued = queues[thread.id] ?? [];
    const threadPins = (pinsByChat[thread.id] ?? []).length;
    const threadHistory = mergeHistory(history, thread.messages.flatMap((m) => (m.role === "user" ? [m.text] : [])));
    return (
      <>

            {hasMessages ? (
              <div className="flex min-h-0 flex-1 flex-col">
                <ChatTranscript key={thread.id} messages={thread.messages} register={paneRef(thread.id)} following={isFollowing} onOpenPath={openPath} onReview={openChanges} />
                <div className={`shrink-0 bg-page px-4 ${compactPane ? "py-2" : "pt-3 pb-6 sm:px-8"}`}>
                  <div className="mx-auto max-w-[720px]">
                    {threadPins > 0 && (
                      <div className="mb-2 flex items-center gap-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12.5px] text-ink-2 shadow-hairline">
                        <span className="shrink-0 text-[11px] font-medium tracking-wide text-ink-3 uppercase">Pinned</span>
                        <span className="min-w-0 flex-1 truncate text-ink">
                          {threadPins} element{threadPins === 1 ? "" : "s"} in the browser go with your next message
                        </span>
                        <button
                          type="button"
                          onClick={() => {
                            focusChat(thread.id);
                            setFilesOpen(false);
                            setBrowserOpen(true);
                          }}
                          className="shrink-0 rounded px-1.5 text-[11.5px] font-medium text-ink-2 hover:bg-hover hover:text-ink"
                        >
                          Show
                        </button>
                        <button
                          type="button"
                          aria-label="Clear pins"
                          onClick={() => setPins(thread.id, [])}
                          className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-3 hover:bg-hover hover:text-ink"
                        >
                          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden>
                            <path d="M18 6L6 18M6 6l12 12" />
                          </svg>
                        </button>
                      </div>
                    )}
                    {threadQueued.length > 0 && (
                      <ul className="mb-2 flex flex-col gap-1">
                        {threadQueued.map((item) => (
                          <li
                            key={item.id}
                            className="flex items-center gap-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12.5px] text-ink-2 shadow-hairline"
                          >
                            <span className="shrink-0 text-[11px] font-medium tracking-wide text-ink-3 uppercase">Queued</span>
                            <span className="min-w-0 flex-1 truncate text-ink">{item.text}</span>
                            <button
                              type="button"
                              aria-label="Remove from queue"
                              onClick={() => setQueue(thread.id, dropQueuedPrompt(queuesRef.current[thread.id] ?? [], item.id))}
                              className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-3 hover:bg-hover hover:text-ink"
                            >
                              <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden>
                                <path d="M18 6L6 18M6 6l12 12" />
                              </svg>
                            </button>
                          </li>
                        ))}
                      </ul>
                    )}
                    <PromptBar
                      demo={false}
                      tall={!compactPane}
                      placeholder={threadBusy ? "Queue a follow-up…" : "Follow up"}
                      models={models}
                      commands={commands[thread.id] ?? catalogCommands}
                      root={cwdOf(thread)}
                      modelKey={threadModel}
                      onModelChange={(key: string) => changeModel(key, thread.id)}
                      onSend={(text: string) => void send(text, thread.id)} onSetting={text => settings.change(thread.id, text)}
                      history={threadHistory}
                      busy={threadBusy}
                      onStop={() => {
                        const live = sessionsRef.current.get(thread.id);
                        if (live) void cancel(handleOf(thread.id), live);
                      }}
                    />
                  </div>
                </div>
              </div>
            ) : (
              <div className="min-h-0 flex-1 overflow-y-auto">
                <EmptyState compact={compactPane}
                  onOpenProject={() => setDialog({ mode: "new" })}
                  onProjects={() => setProjectsOpen(true)}
                  onContinue={openConversations} onReview={openChanges}
                  onSend={(text: string) => void send(text, thread.id)} onSetting={text => settings.change(thread.id, text)}
                  health={health}
                  history={threadHistory}
                  cwd={cwdOf(thread)}
                  models={models}
                  modelKey={threadModel}
                  onModelChange={(key: string) => changeModel(key, thread.id)}
                  commands={commands[thread.id] ?? catalogCommands}
                />
              </div>
            )}
      </>
    );
  };


  useDesktopShortcuts({ closeChat, newChat, reopenClosed, toggleSplit, focusChat, chats, activeId, columns: columnIds,
    split: direction => { setSplitDirection(direction); setZoomedPane(false); addPane(); },
    zoomPane: () => setZoomedPane(value => !value),
    resizePane: delta => setPaneWeights(old => ({ ...old, [activeId]: Math.max(0.4, Math.min(3, (old[activeId] ?? 1) + delta)) })),
    toggleTerminal, equalize: () => setPaneWeights({}), openWorkspace: () => setDialog({ mode: "new" }),
  });

  catalogRef.current = { adopt: (id: number) => { if (!runningRef.current.has(id)) void adoptCatalog(id).catch(() => undefined); }, activeId };

  const paneTodos = lastAssistant?.turn.todos ?? [];
  // Zoom only changes visibility; the split order is retained.
  const columns = (zoomedPane ? [activeId] : columnIds).map((id) => chats.find((c) => c.id === id)).filter((c): c is Chat => c !== undefined);


  return (
    <main data-graff-main className="flex h-[100dvh] gap-0 bg-canvas p-2.5 text-ink lg:pl-0">
      <SidebarNav
        fill
        className="hidden lg:flex"
        recents={recents}
        recentsTotal={storedTotal}
        activeTitle={chatThread.title}
        activeId={chatThread.session ?? null}
        onPick={pickRecent}
        onNewChat={newChat}
        onSeeAll={openConversations}
        activeNav={projectsOpen ? "projects" : filesOpen ? (fileRequest?.changes ? "changes" : "workspace") : browserOpen ? "browser" : conversationsOpen ? "conversations" : "home"}
        onNavigate={(key) => {
          setAgentsOpen(false);
          setProjectsOpen(key === "projects");
          if (key === "changes") { openChanges(); return; }
          if (key === "workspace") setFileRequest(null);
          setFilesOpen(key === "workspace");
          setBrowserOpen(key === "browser");
          setConversationsOpen(key === "conversations");
        }}
        workspace={sidebarWorkspace}
        workspaces={workspaces.map((w) => ({ path: w.path, name: w.name }))}
        onSwitchWorkspace={switchWorkspace}
        onArchiveRecent={(id) => dropStored(id, true)}
        onDeleteRecent={(id) => dropStored(id, false)}
        onNewWorkspace={() => setDialog({ mode: "new" })}
        onWorkspaceSettings={() => setDialog(sidebarWorkspace ? { mode: "settings" } : { mode: "new" })}
        footerLabel={copiedResume ? "Copied resume command" : (chatThread.session ?? "Connecting…")}
        footerTitle={footerTitle}
        onFooterClick={copyResume}
      />

      <div className="flex min-w-0 flex-1 flex-col gap-2.5">
        <HarnessChrome chats={chats} activeId={activeId} busyIds={busyIds} focusChat={focusChat} closeChat={closeChat} newChat={newChat}
          conversationsOpen={conversationsOpen} openConversations={openConversations} split={panes.length > 0} toggleSplit={toggleSplit}
          filesOpen={filesOpen} onFiles={() => { setAgentsOpen(false); setFileRequest(null); setProjectsOpen(false); setBrowserOpen(false); setConversationsOpen(false); setFilesOpen(fileRequest?.changes ? true : !filesOpen); }}
          chatCwd={chatCwd} workspaceName={workspaceName} onFolder={() => setDialog({ mode: "new" })} openChanges={openChanges}
          browserOpen={browserOpen} onBrowser={() => { setAgentsOpen(false); setProjectsOpen(false); setConversationsOpen(false); setFilesOpen(false); setBrowserOpen(open => !open); }} pinCount={pinCount}
          terminalVisible={terminalVisible} toggleTerminal={toggleTerminal} agentsOpen={agentsOpen}
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
          <div className="min-h-0 min-w-0 flex-1" style={{ display: projectsOpen || conversationsOpen ? "none" : "flex" }}>
            <ChatSplitLayout threads={columns} activeId={activeId} direction={splitDirection} weights={paneWeights} setWeights={setPaneWeights}
              onFocus={focusChat} onClose={closeChat} folder={thread => ({name: workspaceNameOf(thread), path: cwdOf(thread)})}
              body={columnBody} split={columnIds.length > 1} />
          </div>

          {agentsOpen && !projectsOpen && !filesOpen && !browserOpen && !conversationsOpen && <AgentsPane key={chatCwd} root={chatCwd} onClose={() => setAgentsOpen(false)} />}
          {filesOpen && !projectsOpen && !conversationsOpen && (fileRequest?.changes ? <ChangesPane root={chatThread.cwd} onClose={() => setFilesOpen(false)} /> : <FilesPane root={chatThread.cwd} requested={fileRequest} onClose={() => setFilesOpen(false)} />)}

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

          {!projectsOpen && !filesOpen && !browserOpen && !conversationsOpen && active && paneTodos.length > 0 && (
            <aside
              className="hidden w-[360px] shrink-0 flex-col overflow-hidden rounded-[14px] border border-line bg-page lg:flex"
              style={{ animation: "fade-in 300ms ease both" }}
            >
              <div className="flex h-11 shrink-0 items-center border-b border-line px-4">
                <span className="text-[13px] font-semibold text-ink">Tasks</span>
              </div>
              <div className="min-h-0 flex-1 overflow-y-auto p-4">
                <TaskRows
                  variant="List"
                  items={paneTodos.map((todo) => ({
                    key: todo.id,
                    label: todo.content,
                    status: todo.status === "in_progress" ? "in_progress" : todo.status === "completed" ? "completed" : "pending",
                  }))}
                />
              </div>
            </aside>
          )}
        </div>
        {terminalUsed && chatCwd && <TerminalPane key={chatCwd} cwd={chatCwd} visible={terminalVisible} onHide={() => setTerminalVisible(false)} />}
      </div>

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
