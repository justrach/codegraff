"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type RefObject } from "react";
import PromptBar, { type PromptModel } from "@/components/primitives/PromptBar";
import SidebarNav from "@/components/primitives/SidebarNav";
import FilesPane from "@/components/site/FilesPane";
import BrowserPane from "@/components/site/BrowserPane";
import { IconFolder, IconGlobe } from "@/lib/icons";
import { annotationsBlock, type BrowserPin } from "@/lib/browser/annotations";
import { browserClose, browserHandle, browserNav } from "@/lib/browser-client";
import TaskRows from "@/components/primitives/TaskRows";
import { ThemeToggle } from "@/components/site/ThemeToggle";
import { AssistantBody, UserBubble } from "@/components/site/ChatBubbles";
import EmptyState from "@/components/site/ChatEmpty";
import {
  MODELS,
  STARTER_PROMPTS,
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
import { applyAcpUpdate, emptyTurn, finishAcpTurn, type AssistantTurn } from "@/lib/acp";
import { isFollowingTail, pinScrollerTail } from "@/lib/follow-scroll";
import { dropQueuedPrompt, enqueuePrompt, shiftQueuedPrompt, type QueuedPrompt } from "@/lib/prompt-queue";
import { dateGroup, listSessions, loadSession, relativeTime, removeSession, type StoredSession } from "@/lib/sessions";
import { loadHistory, mergeHistory, pushHistory, saveHistory } from "@/lib/prompt-history";
import WorkspaceDialog from "@/components/site/WorkspaceDialog";
import {
  basename,
  findWorkspace,
  loadActiveWorkspace,
  loadWorkspaces,
  removeWorkspace,
  saveActiveWorkspace,
  saveWorkspaces,
  shellQuote,
  upsertWorkspace,
  type Workspace,
} from "@/lib/workspaces";

/** Whether the sidecar browser pane was open, restored after a reload. */
const BROWSER_OPEN_KEY = "graff.native.browser.open";

/** Columns the split view will show at once, the active chat included. */
const MAX_COLUMNS = 4;

type Msg =
  | { id: number; role: "user"; text: string }
  | { id: number; role: "assistant"; turn: AssistantTurn };

/** `model` is what this tab's own agent was spawned with; the harness-level
 * model is only the default a new tab inherits. `cwd` is the workspace the
 * tab's agent runs in — fixed at spawn, like the model. */
type Chat = { id: number; title: string | null; messages: Msg[]; model?: string; session?: string; cwd?: string;
  /** The model named this tab from its first prompt: the session poller,
   * which reads graff's own saved title, must leave it alone. */
  titledByModel?: boolean };

function newPageToken(): string {
  return Math.random().toString(36).slice(2, 10);
}

/** A fresh tab's graff session name. Not `session-…`: that prefix is what the
 * REPL's auto-title renames, and a tab needs a name that stays put so the
 * sidebar row and the running agent keep pointing at the same file. */
function newSessionName(): string {
  return `native-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
}

export default function GraffHarness() {
  const [chats, setChats] = useState<Chat[]>([{ id: 1, title: null, messages: [] }]);
  const [activeId, setActiveId] = useState(1);
  const [offset, setOffset] = useState(0);
  const [health, setHealth] = useState<Health | null>(null);
  // Every tab owns a `graff acp` child (the agent keeps one session per
  // process), so sessions, busy state and the spawned model are all per chat.
  const pageRef = useRef<string>(newPageToken());
  const sessionsRef = useRef(new Map<number, string>());
  // chat id → graff session name (the `--resume` target / sidebar identity).
  const sessionNamesRef = useRef(new Map<number, string>());
  const [sessionIds, setSessionIds] = useState<Record<number, string>>({});
  const [stored, setStored] = useState<StoredSession[]>([]);
  const [busyIds, setBusyIds] = useState<ReadonlySet<number>>(() => new Set());
  // No hardcoded default: until graff/models answers, the agent's own model
  // resolution decides, and `current` from that call re-points the picker.
  const [models, setModels] = useState<PromptModel[]>(MODELS);
  const [model, setModelKey] = useState<string | null>(process.env.NEXT_PUBLIC_GRAFF_MODEL || null);
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
  // live in this browser; the server only validates a root it is handed.
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
  const [browserOpen, setBrowserOpen] = useState(false);
  // The pane comes back after a reload (with its last page: the pane
  // remembers that itself). Read after mount so the server render matches.
  const browserOpenRestored = useRef(false);
  useEffect(() => {
    try {
      if (!browserOpenRestored.current) {
        browserOpenRestored.current = true;
        if (window.localStorage.getItem(BROWSER_OPEN_KEY) === "1") setBrowserOpen(true);
        return;
      }
      window.localStorage.setItem(BROWSER_OPEN_KEY, browserOpen ? "1" : "0");
    } catch {
      // no storage
    }
  }, [browserOpen]);
  const [pinsByChat, setPinsByChat] = useState<Record<number, BrowserPin[]>>({});
  const pinsRef = useRef<Record<number, BrowserPin[]>>({});
  const chatIdRef = useRef(1);
  const msgIdRef = useRef(0);
  const scrollRef = useRef<HTMLDivElement>(null);
  // Split view: chats shown beside the active one. Each column keeps its
  // own scroller and its own place in its transcript.
  const [panes, setPanes] = useState<number[]>([]);
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
  // The ids on screen, in order: the active chat then its split panes.
  const columnIds = [chatThread.id, ...panes.filter((id) => id !== chatThread.id && chats.some((c) => c.id === id))].slice(0, MAX_COLUMNS);
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
    // What did the agent actually resolve? The picker should show graff's
    // answer (fuzzy --model resolution, election-ranked seats), not our guess.
    try {
      const { models: live, current } = await fetchModels(handleOf(chatId));
      if (live.length > 0) setModels(live);
      if (current) {
        setChatModel(chatId, current);
        setModelKey((fallback) => fallback ?? current);
      }
    } catch {
      // keep the static fallback; the picker still works
    }
  };

  // The picker falls back to a built-in list until the agent answers with
  // what it actually has. A window that missed that answer — its agent was
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
    const id = await ensureSession(handleOf(chatId), {
      model: spawnModel,
      reset,
      resume: sessionNamesRef.current.get(chatId),
      cwd,
      yolo: ws?.yolo,
      mcp: ws?.mcp,
    });
    sessionsRef.current.set(chatId, id);
    setSessionIds((current) => ({ ...current, [chatId]: id }));
    setHealth({ ok: true });
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
      let list = loadWorkspaces(window.localStorage);
      if (root && !findWorkspace(list, root)) list = upsertWorkspace(list, { path: root, name: basename(root) });
      const remembered = loadActiveWorkspace(window.localStorage);
      const active = findWorkspace(list, remembered)?.path ?? findWorkspace(list, root)?.path ?? list[0]?.path ?? null;
      workspacesRef.current = list;
      activePathRef.current = active;
      setWorkspaces(list);
      setActivePath(active);
      saveWorkspaces(window.localStorage, list);
      if (active) setChats((current) => current.map((c) => (c.id === 1 && !c.cwd ? { ...c, cwd: active } : c)));
      void refreshStored();
      try {
        const session = newSessionName();
        sessionNamesRef.current.set(1, session);
        setChats((current) => current.map((c) => (c.id === 1 ? { ...c, session } : c)));
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
      const list = await listSessions(activePathRef.current ?? undefined);
      setStored(list);
      setChats((current) =>
        current.map((c) => {
          if (c.titledByModel) return c;
          const saved = c.session ? list.find((s) => s.name === c.session) : undefined;
          return saved?.title && saved.title !== c.title ? { ...c, title: saved.title } : c;
        }),
      );
    } catch {
      // the sidebar keeps its last list
    }
  };

  const openPath = useCallback((path: string) => {
    setFilesOpen(true);
    setFileRequest({ path, n: (fileReqRef.current += 1) });
  }, []);

  const openChanges = useCallback(() => {
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
                { id: asstId, role: "assistant", turn: { ...emptyTurn(), model: spawnModel } },
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
    const pins = pinsRef.current[chatId] ?? [];
    if (pins.length > 0) {
      const handle = await browserHandle(handleOf(chatId)).catch(() => null);
      wire = `${trimmed}\n\n${annotationsBlock(pins, handle)}`;
      setPins(chatId, []);
    }
    let turn: AssistantTurn = { ...emptyTurn(), model: spawnModel };
    const startedAt = Date.now();
    try {
      const id = await requireSession(chatId);
      // Paint at most once per frame. ACP text/tool events can arrive dozens
      // of times per 16ms; each setChats used to re-parse every settled
      // markdown block in the thread.
      let paint = 0;
      const turnRef = { current: turn };
      for await (const update of prompt(handleOf(chatId), id, wire)) {
        turn = applyAcpUpdate(turn, update);
        if (turn.thoughtMs === undefined && turn.status !== "thinking") turn = { ...turn, thoughtMs: Date.now() - startedAt };
        turnRef.current = turn;
        if (!paint) {
          paint = requestAnimationFrame(() => {
            paint = 0;
            patchAssistant(chatId, asstId, turnRef.current);
          });
        }
      }
      if (paint) cancelAnimationFrame(paint);
      // The turn carried pins, so the agent most likely changed the page:
      // reload the chat's tab so the pane shows the result without a click.
      if (pins.length > 0) void browserNav(handleOf(chatId), "reload").catch(() => undefined);
      turn = finishAcpTurn(turn);
      patchAssistant(chatId, asstId, turn);
    } catch (err) {
      turn = { ...turn, error: err instanceof Error ? err.message : String(err), status: "error" };
      patchAssistant(chatId, asstId, turn);
    } finally {
      runningRef.current.delete(chatId);
      setBusyFor(chatId, false);
      void refreshStored();
      setTimeout(() => void refreshStored(), 2500);
      const { next, rest } = shiftQueuedPrompt(queuesRef.current[chatId] ?? []);
      setQueue(chatId, rest);
      if (next) void runPrompt(chatId, next.text);
    }
  };

  /** Name the tab from what was asked, in the model's words. The prompt's
   * first words stand in until this answers (a few seconds), and stay if it
   * cannot. Only the first message of a tab names it. */
  const nameChat = (chatId: number, prompt: string, cwd: string | undefined) => {
    void fetch("/api/title", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ prompt, cwd }),
    })
      .then((res) => (res.ok ? (res.json() as Promise<{ title?: string | null }>) : null))
      .then((body) => {
        const title = body?.title?.trim();
        if (!title) return;
        setChats((current) => current.map((c) => (c.id === chatId ? { ...c, title, titledByModel: true } : c)));
      })
      .catch(() => undefined);
  };

  const send = async (text: string, forChat?: number) => {
    const trimmed = text.trim();
    const chatId = forChat ?? chatThread.id;
    if (!trimmed) return;
    if (runningRef.current.has(chatId) || busyIds.has(chatId)) {
      setQueue(chatId, enqueuePrompt(queuesRef.current[chatId] ?? [], trimmed, (queueIdRef.current += 1)));
      return;
    }
    await runPrompt(chatId, trimmed);
  };

  const openChat = (id: number) => {
    const session = newSessionName();
    sessionNamesRef.current.set(id, session);
    const cwd = activePathRef.current ?? undefined;
    const ws = findWorkspace(workspacesRef.current, cwd);
    setChats((current) => [...current, { id, title: null, messages: [], model: ws?.model ?? model ?? undefined, session, cwd }]);
    setActiveId(id);
    setFilesOpen(false);
    setFollowing(true);
    // Spawn eagerly so the first send is not stuck behind agent + MCP boot.
    void requireSession(id).catch(() => undefined);
  };

  /** Open a saved graff session: its transcript renders from the file at once,
   * and the tab's agent starts with `--resume` so a follow-up remembers it. */
  const openStored = async (name: string, atCwd?: string) => {
    // The sidebar lists the active workspace, so the session lives there;
    // the same name in another workspace is a different conversation. A
    // reopened tab names its own workspace instead.
    const cwd = atCwd ?? activePathRef.current ?? undefined;
    const existing = chats.find((c) => c.session === name && (c.cwd ?? null) === (cwd ?? null));
    if (existing) {
      setActiveId(existing.id);
      setFilesOpen(false);
      return;
    }
    let loaded: Awaited<ReturnType<typeof loadSession>>;
    try {
      loaded = await loadSession(name, cwd);
    } catch (err) {
      setHealth((current) => ({ ...(current ?? { ok: true }), detail: err instanceof Error ? err.message : String(err) }));
      return;
    }
    const id = (chatIdRef.current += 1);
    const messages: Msg[] = loaded.messages.map((m) => ({ id: (msgIdRef.current += 1), ...m }));
    sessionNamesRef.current.set(id, name);
    setChats((current) => [
      ...current,
      { id, title: loaded.meta.title ?? name, messages, model: loaded.meta.model ?? undefined, session: name, cwd },
    ]);
    setActiveId(id);
    setFilesOpen(false);
    setFollowing(true);
    void requireSession(id, false, loaded.meta.model ?? undefined).catch(() => undefined);
  };

  const newChat = () => openChat((chatIdRef.current += 1));

  /** Make a chat the active one. If it is already a split pane, the chat it
   * replaces takes that pane, so the same two stay on screen. */
  const focusChat = (id: number) => {
    const here = activeId;
    setPanes((current) => (current.includes(id) ? current.map((pane) => (pane === id ? here : pane)) : current));
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
    if (panesRef.current.length + 1 >= MAX_COLUMNS) return;
    const keep = activeId;
    const id = (chatIdRef.current += 1);
    openChat(id);
    // openChat makes the new tab active; the split keeps the current chat
    // where it is and puts the new one beside it.
    setActiveId(keep);
    setPanes((current) => [...current, id]);
  };

  const closePane = (id: number) => setPanes((current) => current.filter((pane) => pane !== id));

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
    setPanes((current) => current.filter((pane) => pane !== id));
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
    const remaining = chats.filter((c) => c.id !== id);
    if (remaining.length === 0) {
      setChats([]);
      openChat((chatIdRef.current += 1));
      return;
    }
    setChats(remaining);
    if (id === activeId) setActiveId(remaining[remaining.length - 1].id);
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

  /* ── workspaces ── */

  const persistWorkspaces = (list: Workspace[]) => {
    workspacesRef.current = list;
    setWorkspaces(list);
    saveWorkspaces(window.localStorage, list);
  };

  const activate = (path: string | null) => {
    activePathRef.current = path;
    setActivePath(path);
    saveActiveWorkspace(window.localStorage, path);
    void refreshStored();
  };

  /** Move a tab to another folder. Only sound for a tab with no messages:
   * an agent is bound to its folder at spawn, so this starts a fresh one
   * there, and a conversation would lose the ground it was standing on. */
  const moveChatTo = (chatId: number, path: string) => {
    const ws = findWorkspace(workspacesRef.current, path);
    const next = chatsRef.current.map((c) => (c.id === chatId ? { ...c, cwd: path, model: c.model ?? ws?.model } : c));
    // requireSession reads the chat from this ref in the same tick, before
    // React has re-rendered with the new cwd.
    chatsRef.current = next;
    setChats(next);
    setActiveId(chatId);
    void requireSession(chatId, true)
      .then(() => adoptCatalog(chatId))
      .catch(() => undefined);
  };

  /** Switch the sidebar to a workspace and land on a tab that runs there.
   * The tab in front follows the switch when nothing has been asked in it
   * yet — picking a folder should change the folder you are looking at.
   * A tab with a conversation keeps its own folder, and says which. */
  const switchWorkspace = (path: string) => {
    if (path === activePathRef.current) return;
    activate(path);
    setFilesOpen(false);
    const here = chatsRef.current.find((c) => c.id === activeId);
    if (here && here.messages.length === 0) {
      moveChatTo(here.id, path);
      return;
    }
    const empty = chatsRef.current.find((c) => c.cwd === path && c.messages.length === 0);
    if (empty) {
      setActiveId(empty.id);
      return;
    }
    openChat((chatIdRef.current += 1));
  };

  const addWorkspace = (path: string) => {
    const list = upsertWorkspace(workspacesRef.current, { path, name: basename(path) });
    persistWorkspaces(list);
    setDialog(null);
    const added = findWorkspace(list, path);
    if (added) switchWorkspace(added.path);
  };

  const saveWorkspace = (ws: Workspace) => {
    persistWorkspaces(upsertWorkspace(workspacesRef.current, ws));
    setDialog(null);
  };

  /** Drop a workspace from the switcher (nothing on disk changes). If it
   * was active, the next row — or the server default — takes over. */
  const forgetWorkspace = (path: string) => {
    const list = removeWorkspace(workspacesRef.current, path);
    persistWorkspaces(list);
    setDialog(null);
    if (activePathRef.current === path) {
      const next = list[0]?.path ?? health?.cwd ?? null;
      if (next) switchWorkspace(next);
      else activate(null);
    }
  };

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
  useEffect(() => {
    const off: (() => void)[] = [];
    for (const id of columnKey.split(",").filter(Boolean).map(Number)) {
      const el = scrollEls.current.get(id);
      if (!el) continue;
      el.scrollTop = el.scrollHeight;
      setTailing((current) => (current[id] === true ? current : { ...current, [id]: true }));
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

  // The sidebar is graff's session directory, newest first, bucketed by day.
  const now = Date.now();
  // A session open in a tab shows the tab's name (the model wrote it from
  // the first prompt); one only on disk shows whatever graff saved.
  const recents = stored.map((s) => ({
    id: s.name,
    label: chats.find((c) => c.session === s.name)?.title ?? s.title ?? s.name,
    group: dateGroup(s.updatedMs, now),
    hint: [s.model, relativeTime(s.updatedMs, now)].filter(Boolean).join(" · "),
  }));

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
  const footerTitle = chatThread.session
    ? `graff session ${chatThread.session}${sessionId ? ` · ACP ${sessionId}` : ""}${chatCwd ? ` · ${chatCwd}` : ""}\nClick to copy the command that resumes it in a terminal.`
    : undefined;

  /** One chat column: its transcript (or the empty state) and its composer.
   * A plain function, not a component, so the split view can render two of
   * them without React remounting either on every parent render. */
  const columnBody = (thread: Chat) => {
    const isFollowing = tailing[thread.id] ?? true;
    const hasMessages = thread.messages.length > 0;
    const threadBusy = busyIds.has(thread.id);
    const threadModel = thread.model ?? model ?? undefined;
    const threadQueued = queues[thread.id] ?? [];
    const threadPins = (pinsByChat[thread.id] ?? []).length;
    const threadHistory = mergeHistory(history, thread.messages.flatMap((m) => (m.role === "user" ? [m.text] : [])));
    return (
      <>

            {hasMessages ? (
              <div className="flex min-h-0 flex-1 flex-col">
                <div ref={paneRef(thread.id)} className="min-h-0 flex-1 overflow-y-auto overscroll-contain" style={{ overflowAnchor: "none" }}>
                  <div className="mx-auto flex w-full max-w-[720px] flex-col gap-8 px-4 py-8 sm:px-8">
                    {thread.messages.map((message, index) =>
                      message.role === "user" ? (
                        <UserBubble key={message.id} text={message.text} />
                      ) : (
                        <AssistantBody
                          key={message.id}
                          turn={message.turn}
                          onOpenPath={openPath}
                          onReview={openChanges}
                          scroller={scrollRef}
                          following={isFollowing && index === thread.messages.length - 1}
                        />
                      ),
                    )}
                  </div>
                </div>
                <div className="shrink-0 bg-page px-4 pt-3 pb-6 sm:px-8">
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
                            setActiveId(thread.id);
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
                      tall
                      placeholder={threadBusy ? "Queue a follow-up…" : "Follow up"}
                      models={models}
                      modelKey={threadModel}
                      onModelChange={(key: string) => changeModel(key, thread.id)}
                      onSend={(text: string) => void send(text, thread.id)}
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
                <EmptyState
                  onSend={(text: string) => void send(text, thread.id)}
                  health={health}
                  history={threadHistory}
                  cwd={cwdOf(thread)}
                  offset={offset}
                  shuffle={() => setOffset((current) => (current + 3) % STARTER_PROMPTS.length)}
                  models={models}
                  modelKey={threadModel}
                  onModelChange={(key: string) => changeModel(key, thread.id)}
                />
              </div>
            )}
      </>
    );
  };

  const tabBar = (
    <div className="flex h-11 shrink-0 items-center gap-1 overflow-x-auto border-b border-line px-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
      {chats.map((c) => (
        <div
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
            onClick={() => focusChat(c.id)}
            title={c.title ?? "New chat"}
            className="min-w-0 flex-1 text-left"
          >
            <span className="block truncate">{c.title ?? "New chat"}</span>
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
      <div className="ml-auto flex items-center gap-2 pr-1">
        <button
          type="button"
          aria-pressed={panes.length > 0}
          onClick={toggleSplit}
          title={panes.length > 0 ? "Close the splits (⌘\\)" : "Split the view: another chat beside this one (⌘D adds one)"}
          className={`flex size-7 items-center justify-center rounded-[7px] transition-colors duration-100 ${
            panes.length > 0 ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
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
          onClick={() => {
            setBrowserOpen(false);
            setFilesOpen((open) => !open);
          }}
          title={`${chatCwd ?? "Workspace"}\nShow this chat's files`}
          className={`flex h-7 items-center gap-1.5 rounded-l-[7px] pl-2 pr-1.5 text-[12px] font-medium transition-colors duration-100 ${
            filesOpen ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
          <IconFolder size={14} />
          <span className="max-w-40 truncate font-mono text-[11.5px]">{workspaceName}</span>
        </button>
        <button
          type="button"
          aria-label="Open a folder"
          onClick={() => setDialog({ mode: "new" })}
          title="Open another folder to work in"
          className="-ml-2 flex h-7 items-center rounded-r-[7px] pl-0.5 pr-1.5 text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
        >
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <path d="M6 9l6 6 6-6" />
          </svg>
        </button>
        <button
          type="button"
          aria-pressed={browserOpen}
          onClick={() => {
            setFilesOpen(false);
            setBrowserOpen((open) => !open);
          }}
          title="Sidecar browser — a Chrome tab this chat and its agent share"
          className={`flex h-7 items-center gap-1.5 rounded-[7px] px-2 text-[12px] font-medium transition-colors duration-100 ${
            browserOpen ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
          <IconGlobe size={14} />
          <span className="text-[11.5px]">Browser</span>
          {pinCount > 0 && (
            <span className="rounded-full bg-accent px-1.5 text-[10px] font-semibold text-white tabular-nums">{pinCount}</span>
          )}
        </button>
        <ThemeToggle />
      </div>
    </div>
  );

  // The shortcuts read the current handlers through a ref, so the window
  // listener below is installed once instead of on every render.
  const keysRef = useRef({ closeChat, newChat, reopenClosed, toggleSplit, addPane, focusChat, chats, activeId });
  keysRef.current = { closeChat, newChat, reopenClosed, toggleSplit, addPane, focusChat, chats, activeId };

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || event.altKey) return;
      const keys = keysRef.current;
      const key = event.key.toLowerCase();
      const take = () => {
        event.preventDefault();
        event.stopPropagation();
      };
      if (key === "w" && !event.shiftKey) {
        take();
        keys.closeChat(keys.activeId);
        return;
      }
      if (key === "t") {
        take();
        if (event.shiftKey) keys.reopenClosed();
        else keys.newChat();
        return;
      }
      if (key === "d" && !event.shiftKey) {
        take();
        keys.addPane();
        return;
      }
      if (key === "\\" && !event.shiftKey) {
        take();
        keys.toggleSplit();
        return;
      }
      // ⌘1…⌘9 jump to a tab, ⌘9 to the last one, as in a browser.
      if (!event.shiftKey && key >= "1" && key <= "9") {
        const nth = Number(key);
        const target = nth === 9 ? keys.chats[keys.chats.length - 1] : keys.chats[nth - 1];
        if (!target) return;
        take();
        keys.focusChat(target.id);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  catalogRef.current = { adopt: (id: number) => void adoptCatalog(id).catch(() => undefined), activeId };

  const paneTodos = lastAssistant?.turn.todos ?? [];
  // The active chat is the first column; the panes follow it. A chat that
  // was closed, or became the active one, leaves the split rather than
  // showing twice. Four columns is as narrow as a chat stays readable.
  const columns = columnIds.map((id) => chats.find((c) => c.id === id)).filter((c): c is Chat => c !== undefined);


  return (
    <main className="flex h-[100dvh] gap-0 bg-canvas p-2.5 text-ink lg:pl-0">
      <SidebarNav
        fill
        className="hidden lg:flex"
        recents={recents}
        activeTitle={chatThread.title}
        activeId={chatThread.session ?? null}
        onPick={pickRecent}
        onNewChat={newChat}
        activeNav={filesOpen ? "workspace" : browserOpen ? "browser" : "chats"}
        onNavigate={(key) => {
          setFilesOpen(key === "workspace");
          setBrowserOpen(key === "browser");
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
        <div className="flex min-h-0 flex-1 gap-2.5">
          {columns.map((thread, slot) => (
            <section
              key={thread.id}
              className="flex min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page"
            >
              {slot === 0 ? (
                tabBar
              ) : (
                <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-3">
                  {busyIds.has(thread.id) && (
                    <span className="size-1.5 shrink-0 animate-pulse rounded-full" style={{ background: "var(--accent)" }} aria-label="Working" />
                  )}
                  <button
                    type="button"
                    onClick={() => focusChat(thread.id)}
                    title="Make this the main chat"
                    className="min-w-0 flex-1 truncate text-left text-[12.5px] font-medium text-ink"
                  >
                    {thread.title ?? "New chat"}
                  </button>
                  <span
                    title={cwdOf(thread) ?? "workspace"}
                    className="flex h-7 shrink-0 items-center gap-1.5 rounded-[7px] px-1.5 text-[12px] font-medium text-ink-2"
                  >
                    <IconFolder size={14} />
                    <span className="max-w-32 truncate font-mono text-[11.5px]">{workspaceNameOf(thread)}</span>
                  </span>
                  <button
                    type="button"
                    aria-label="Close this split"
                    title="Close this split"
                    onClick={() => closePane(thread.id)}
                    className="flex size-7 shrink-0 items-center justify-center rounded-[6px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
                  >
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden>
                      <path d="M18 6L6 18M6 6l12 12" />
                    </svg>
                  </button>
                </div>
              )}
              {columnBody(thread)}
            </section>
          ))}

          {filesOpen && <FilesPane root={chatThread.cwd} requested={fileRequest} onClose={() => setFilesOpen(false)} />}

          {browserOpen && (
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

          {!filesOpen && !browserOpen && active && paneTodos.length > 0 && (
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
      </div>

      {dialog && (
        <WorkspaceDialog
          mode={dialog.mode}
          workspace={dialog.mode === "settings" ? sidebarWorkspace : undefined}
          startPath={activePath ?? health?.home ?? undefined}
          models={models}
          onClose={() => setDialog(null)}
          onPick={addWorkspace}
          onSave={saveWorkspace}
          onForget={forgetWorkspace}
        />
      )}
    </main>
  );
}
