"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
import { dateGroup, listSessions, loadSession, relativeTime, type StoredSession } from "@/lib/sessions";
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

type Msg =
  | { id: number; role: "user"; text: string }
  | { id: number; role: "assistant"; turn: AssistantTurn };

/** `model` is what this tab's own agent was spawned with; the harness-level
 * model is only the default a new tab inherits. `cwd` is the workspace the
 * tab's agent runs in — fixed at spawn, like the model. */
type Chat = { id: number; title: string | null; messages: Msg[]; model?: string; session?: string; cwd?: string };

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
  const chatsRef = useRef(chats);
  chatsRef.current = chats;
  const [following, setFollowing] = useState(true);
  const queuesRef = useRef<Record<number, QueuedPrompt[]>>({});
  const [queues, setQueues] = useState<Record<number, QueuedPrompt[]>>({});
  const queueIdRef = useRef(0);
  const runningRef = useRef(new Set<number>());

  const chatThread = chats.find((c) => c.id === activeId) ?? chats[0];
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

  const changeModel = (key: string) => {
    // New tabs inherit the pick; the active tab respawns its agent with it
    // (a fresh context — the agent cannot swap models mid-session).
    const chatId = chatThread.id;
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

  const send = async (text: string) => {
    const trimmed = text.trim();
    const chatId = chatThread.id;
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
  const openStored = async (name: string) => {
    // The sidebar lists the active workspace, so the session lives there;
    // the same name in another workspace is a different conversation.
    const cwd = activePathRef.current ?? undefined;
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

  /** Switch the sidebar to a workspace and land on a tab that runs there:
   * an empty tab of its own if one is open, else a fresh one. Tabs already
   * running elsewhere keep their agents — a workspace is fixed at spawn. */
  const switchWorkspace = (path: string) => {
    if (path === activePathRef.current) return;
    activate(path);
    const empty = chatsRef.current.find((c) => c.cwd === path && c.messages.length === 0);
    if (empty) {
      setActiveId(empty.id);
      setFilesOpen(false);
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

  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    setFollowing(true);
    el.scrollTop = el.scrollHeight;
    const onScroll = () => {
      const next = isFollowingTail(el);
      setFollowing((current) => (current === next ? current : next));
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, [activeId, active]);

  useEffect(() => {
    if (!active) return;
    pinScrollerTail(scrollRef.current, following);
  }, [active, following, lastAssistant?.turn.text, lastAssistant?.turn.reasoning, lastAssistant?.turn.tools.length]);

  // The sidebar is graff's session directory, newest first, bucketed by day.
  const now = Date.now();
  const recents = stored.map((s) => ({
    id: s.name,
    label: s.title ?? s.name,
    group: dateGroup(s.updatedMs, now),
    hint: [s.model, relativeTime(s.updatedMs, now)].filter(Boolean).join(" · "),
  }));

  // The tab bar's folder chip is the *tab's* workspace; the sidebar's
  // switcher is the *active* one (where new tabs open). They differ only
  // after a switch, and each says so on hover.
  const chatCwd = chatThread.cwd ?? health?.cwd;
  const chatWorkspace = findWorkspace(workspaces, chatCwd);
  const workspaceName = chatWorkspace?.name ?? (chatCwd ? basename(chatCwd) : "workspace");
  const pinCount = (pinsByChat[chatThread.id] ?? []).length;
  const activeWorkspace = findWorkspace(workspaces, activePath);
  const sidebarWorkspace = activeWorkspace ?? (activePath ? { path: activePath, name: basename(activePath) } : undefined);
  const footerTitle = chatThread.session
    ? `graff session ${chatThread.session}${sessionId ? ` · ACP ${sessionId}` : ""}${chatCwd ? ` · ${chatCwd}` : ""}\nClick to copy the command that resumes it in a terminal.`
    : undefined;

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
          <button type="button" aria-pressed={c.id === activeId} onClick={() => setActiveId(c.id)} title={c.title ?? "New chat"} className="min-w-0 flex-1 text-left">
            <span className="block truncate">{c.title ?? "New chat"}</span>
          </button>
          <button
            type="button"
            aria-label="Close tab"
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
          aria-pressed={filesOpen}
          onClick={() => {
            setBrowserOpen(false);
            setFilesOpen((open) => !open);
          }}
          title={chatCwd ?? "Workspace files"}
          className={`flex h-7 items-center gap-1.5 rounded-[7px] px-2 text-[12px] font-medium transition-colors duration-100 ${
            filesOpen ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
          <IconFolder size={14} />
          <span className="max-w-40 truncate font-mono text-[11.5px]">{workspaceName}</span>
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

  const paneTodos = lastAssistant?.turn.todos ?? [];

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
        onNewWorkspace={() => setDialog({ mode: "new" })}
        onWorkspaceSettings={() => setDialog(sidebarWorkspace ? { mode: "settings" } : { mode: "new" })}
        footerLabel={copiedResume ? "Copied resume command" : (chatThread.session ?? "Connecting…")}
        footerTitle={footerTitle}
        onFooterClick={copyResume}
      />

      <div className="flex min-w-0 flex-1 flex-col gap-2.5">
        <div className="flex min-h-0 flex-1 gap-2.5">
          <section className="flex min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page">
            {tabBar}
            {active ? (
              <div className="flex min-h-0 flex-1 flex-col">
                <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto overscroll-contain" style={{ overflowAnchor: "none" }}>
                  <div className="mx-auto flex w-full max-w-[720px] flex-col gap-8 px-4 py-8 sm:px-8">
                    {chatThread.messages.map((message, index) =>
                      message.role === "user" ? (
                        <UserBubble key={message.id} text={message.text} />
                      ) : (
                        <AssistantBody
                          key={message.id}
                          turn={message.turn}
                          onOpenPath={openPath}
                          onReview={openChanges}
                          scroller={scrollRef}
                          following={following && index === chatThread.messages.length - 1}
                        />
                      ),
                    )}
                  </div>
                </div>
                <div className="shrink-0 bg-page px-4 pt-3 pb-6 sm:px-8">
                  <div className="mx-auto max-w-[720px]">
                    {pinCount > 0 && (
                      <div className="mb-2 flex items-center gap-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12.5px] text-ink-2 shadow-hairline">
                        <span className="shrink-0 text-[11px] font-medium tracking-wide text-ink-3 uppercase">Pinned</span>
                        <span className="min-w-0 flex-1 truncate text-ink">
                          {pinCount} element{pinCount === 1 ? "" : "s"} in the browser go with your next message
                        </span>
                        <button
                          type="button"
                          onClick={() => {
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
                          onClick={() => setPins(chatThread.id, [])}
                          className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-3 hover:bg-hover hover:text-ink"
                        >
                          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden>
                            <path d="M18 6L6 18M6 6l12 12" />
                          </svg>
                        </button>
                      </div>
                    )}
                    {queued.length > 0 && (
                      <ul className="mb-2 flex flex-col gap-1">
                        {queued.map((item) => (
                          <li
                            key={item.id}
                            className="flex items-center gap-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12.5px] text-ink-2 shadow-hairline"
                          >
                            <span className="shrink-0 text-[11px] font-medium tracking-wide text-ink-3 uppercase">Queued</span>
                            <span className="min-w-0 flex-1 truncate text-ink">{item.text}</span>
                            <button
                              type="button"
                              aria-label="Remove from queue"
                              onClick={() => setQueue(chatThread.id, dropQueuedPrompt(queuesRef.current[chatThread.id] ?? [], item.id))}
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
                      placeholder={busy ? "Queue a follow-up…" : "Follow up"}
                      models={models}
                      modelKey={chatModel}
                      onModelChange={changeModel}
                      onSend={send}
                      history={composerHistory}
                      busy={busy}
                      onStop={() => {
                        const live = sessionsRef.current.get(chatThread.id);
                        if (live) void cancel(handleOf(chatThread.id), live);
                      }}
                    />
                  </div>
                </div>
              </div>
            ) : (
              <div className="min-h-0 flex-1 overflow-y-auto">
                <EmptyState
                  onSend={send}
                  health={health}
                  history={composerHistory}
                  cwd={chatThread.cwd}
                  offset={offset}
                  shuffle={() => setOffset((current) => (current + 3) % STARTER_PROMPTS.length)}
                  models={models}
                  modelKey={chatModel}
                  onModelChange={changeModel}
                />
              </div>
            )}
          </section>

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
