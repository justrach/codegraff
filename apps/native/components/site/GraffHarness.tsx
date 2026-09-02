"use client";

import { memo, useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import Markdown from "@/components/primitives/Markdown";
import PromptBar, { type PromptModel } from "@/components/primitives/PromptBar";
import SidebarNav from "@/components/primitives/SidebarNav";
import FilesPane from "@/components/site/FilesPane";
import { IconFolder } from "@/lib/icons";
import TaskRows from "@/components/primitives/TaskRows";
import ThinkingState from "@/components/primitives/ThinkingState";
import ToolChips from "@/components/primitives/ToolChips";
import { ThemeToggle } from "@/components/site/ThemeToggle";
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
import { dateGroup, listSessions, loadSession, relativeTime, type StoredSession } from "@/lib/sessions";
import { loadHistory, mergeHistory, pushHistory, saveHistory } from "@/lib/prompt-history";

const NAME = "there";

function greeting(): string {
  const hour = new Date().getHours();
  if (hour < 5) return "Up late";
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

/** Typewriter reveal over the ACP text, the way every AI app streams: a
 * readable base rate with gentle backlog catch-up (capped so a one-shot
 * final answer still visibly types out), and the drain keeps playing after
 * the turn's result lands — done-state chrome waits for the last word.
 * Mounted mid-history it starts caught-up, so old messages never replay. */
function useSmoothStream(target: string): string {
  const [shown, setShown] = useState(target);
  const shownRef = useRef(target);
  useEffect(() => {
    if (!target.startsWith(shownRef.current)) {
      shownRef.current = target;
      setShown(target);
      return;
    }
    if (target === shownRef.current) return;
    let raf = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = Math.min(now - last, 100);
      last = now;
      const behind = target.length - shownRef.current.length;
      if (behind <= 0) return;
      const rate = Math.min(160 + behind * 1.2, 2400); // chars/second
      const step = Math.max(1, Math.round((rate * dt) / 1000));
      shownRef.current = target.slice(0, shownRef.current.length + step);
      setShown(shownRef.current);
      if (shownRef.current.length < target.length) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [target]);
  return shown;
}

const HOME_REVEAL = {
  offsetY: 23,
  blur: 17,
  duration: 800,
  easing: "cubic-bezier(0.16, 1, 0.3, 1)",
};

function homeRevealStyle(visible: boolean): CSSProperties {
  return {
    opacity: visible ? 1 : 0,
    transform: visible ? "translate3d(0, 0, 0)" : `translate3d(0, ${HOME_REVEAL.offsetY}px, 0)`,
    filter: visible ? "blur(0px)" : `blur(${HOME_REVEAL.blur}px)`,
    transition: ["opacity", "transform", "filter"]
      .map((property) => `${property} ${HOME_REVEAL.duration}ms ${HOME_REVEAL.easing}`)
      .join(", "),
  };
}

/* Rows are memoized: a chunk landing in the live turn replaces that one
 * message's `turn`, and every other row keeps its props — without memo the
 * whole thread re-rendered (and re-parsed its markdown) per ACP update. */
const UserBubble = memo(function UserBubble({ text }: { text: string }) {
  return (
    <div className="flex justify-end pl-10 sm:pl-24" style={{ animation: "fade-up 300ms cubic-bezier(0.23,1,0.32,1) both" }}>
      <div
        className="rounded-xl px-3.5 py-2 text-[13px] leading-relaxed text-ink shadow-hairline"
        style={{ background: "color-mix(in oklab, var(--accent) 12%, var(--surface))" }}
      >
        {text}
      </div>
    </div>
  );
});

const AssistantBody = memo(function AssistantBody({
  turn,
  onOpenPath,
  onReview,
}: {
  turn: AssistantTurn;
  onOpenPath?: (path: string) => void;
  /** Open the workspace changes review (the Codex "Changed N files" bar). */
  onReview?: () => void;
}) {
  const thinking = turn.status === "thinking";
  const smoothText = useSmoothStream(turn.text);
  const draining = smoothText.length < turn.text.length;
  // "Thought for Ns": the harness stamps `thoughtMs` on the turn as it streams
  // (ACP updates carry no timestamps); a live turn without one yet is timed here.
  const startRef = useRef(Date.now());
  const [thoughtSecs, setThoughtSecs] = useState<number | null>(
    turn.thoughtMs !== undefined ? Math.max(1, Math.round(turn.thoughtMs / 1000)) : null,
  );
  useEffect(() => {
    if (thinking) return;
    setThoughtSecs((current) => {
      if (current !== null) return current;
      const ms = turn.thoughtMs ?? Date.now() - startRef.current;
      return Math.max(1, Math.round(ms / 1000));
    });
  }, [thinking, turn.thoughtMs]);
  const reasoningRows = turn.reasoning
    ? turn.reasoning
        .split(/\n+/)
        .map((line) => line.trim())
        .filter(Boolean)
        .map((primary) => ({ primary }))
    : [];
  const toolRows = turn.tools.map((tool) => ({
    id: tool.id,
    icon: tool.icon,
    label: tool.name,
    chip: tool.chip,
    mono: tool.icon === "run" || tool.icon === "write" || tool.icon === "read",
    detailMono: tool.icon === "run" || tool.icon === "write",
    detail: tool.detail,
    path: tool.path,
    status: tool.status,
    startedAt: tool.startedAt,
    elapsedMs: tool.elapsedMs,
  }));

  return (
    <article className="min-w-0" style={{ animation: "fade-up 450ms cubic-bezier(0.23,1,0.32,1) both" }}>
      {/* Keep the header once the model has actually thought (streamed
        * reasoning, or a think long enough to notice): unmounting it when the
        * think ends made the answer jump up into the space it left. */}
      {(thinking || reasoningRows.length > 0 || (turn.thoughtMs ?? 0) >= 1500) && (
        <ThinkingState
          variant="Reasoning"
          rows={reasoningRows.length ? reasoningRows : [{ primary: "Waiting on the model…", shimmer: true }]}
          activeLabel={turn.model ? `Thinking · ${turn.model}` : "Thinking"}
          doneLabel={thoughtSecs ? `Thought for ${thoughtSecs}s` : "Thought"}
          working={thinking}
        />
      )}
      {toolRows.length > 0 && (
        <div className="mt-4">
          <ToolChips rows={toolRows} diffs={turn.diffs} onOpenPath={onOpenPath} />
        </div>
      )}
      {turn.status === "streaming" && !turn.text ? (
        /* Between the last tool and the first text token nothing streams —
         * a lone caret here read as "stuck". Shimmer like the thinking
         * header, and say which phase the agent is actually in. */
        <div className="mt-4">
          <span
            className="bg-clip-text text-[13px] font-medium whitespace-nowrap text-transparent"
            style={{
              backgroundImage: "linear-gradient(90deg, var(--ink-3) 35%, var(--ink) 50%, var(--ink-3) 65%)",
              backgroundSize: "200% 100%",
              animation: "shimmer-text 1.4s linear infinite",
            }}
          >
            {turn.tools.some((tool) => tool.status === "running") ? "Running tools…" : "Writing…"}
          </span>
        </div>
      ) : (
        turn.text && (
          <div className="mt-4 max-w-[630px]">
            <Markdown
              text={smoothText}
              streaming={draining || turn.status === "streaming" || turn.status === "thinking"}
              onOpenPath={onOpenPath}
            />
          </div>
        )
      )}
      {turn.error && (
        <p className="mt-4 max-w-[620px] text-[13.5px] leading-[1.65] text-red">{turn.error}</p>
      )}
      {turn.recap && turn.status === "done" && !draining && (
        <p className="mt-3 text-[12px] text-ink-3">{turn.recap}</p>
      )}
      {turn.costUsd !== undefined && turn.status === "done" && !draining && (
        <p className="mt-1 font-mono text-[11px] text-ink-3">${turn.costUsd.toFixed(4)}</p>
      )}
      {turn.status === "done" && !draining && turn.diffs.length > 0 && onReview && (
        <button
          type="button"
          onClick={onReview}
          className="mt-4 flex h-9 w-full max-w-[630px] items-center gap-2 rounded-[10px] bg-surface px-3 text-left shadow-btn transition-colors duration-100 hover:bg-hover"
          style={{ animation: "fade-up 300ms cubic-bezier(0.23,1,0.32,1) both" }}
        >
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="shrink-0 text-ink-3" aria-hidden>
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
            <path d="M14 2v6h6" />
          </svg>
          <span className="text-[12.5px] font-medium text-ink">
            Changed {turn.diffs.length} file{turn.diffs.length === 1 ? "" : "s"}
          </span>
          <span className="font-mono text-[11.5px] tabular-nums">
            <span className="text-green">+{turn.diffs.reduce((n, d) => n + d.add, 0)}</span>{" "}
            <span className="text-red">−{turn.diffs.reduce((n, d) => n + d.del, 0)}</span>
          </span>
          <span className="ml-auto flex items-center gap-0.5 text-[12.5px] font-medium text-ink-2">
            Review
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
              <path d="M9 18l6-6-6-6" />
            </svg>
          </span>
        </button>
      )}
    </article>
  );
});

type Msg =
  | { id: number; role: "user"; text: string }
  | { id: number; role: "assistant"; turn: AssistantTurn };

/** `model` is what this tab's own agent was spawned with; the harness-level
 * model is only the default a new tab inherits. */
type Chat = { id: number; title: string | null; messages: Msg[]; model?: string; session?: string };

function newPageToken(): string {
  return Math.random().toString(36).slice(2, 10);
}

/** One React commit per animation frame, however many ACP chunks land in
 * it. The stream delivers `agent_message_chunk`s a few characters at a time
 * and a state update per chunk was a full render each — the thread jittered
 * under its own re-renders. Only the newest turn matters; the rest is
 * superseded before anyone could have seen it. */
function frameCoalescer<T>(apply: (value: T) => void) {
  let latest: T | undefined;
  let frame = 0;
  const flush = () => {
    frame = 0;
    if (latest !== undefined) apply(latest);
  };
  return {
    push(value: T) {
      latest = value;
      if (!frame) frame = requestAnimationFrame(flush);
    },
    /** Drop whatever is queued; the caller commits the final value itself. */
    cancel() {
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      latest = undefined;
    },
  };
}

/** A fresh tab's graff session name. Not `session-…`: that prefix is what the
 * REPL's auto-title renames, and a tab needs a name that stays put so the
 * sidebar row and the running agent keep pointing at the same file. */
function newSessionName(): string {
  return `native-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
}

function EmptyState({
  onSend,
  health,
  offset,
  shuffle,
  models,
  modelKey,
  onModelChange,
  history,
}: {
  onSend: (text: string) => void;
  health: Health | null;
  offset: number;
  shuffle: () => void;
  models: PromptModel[];
  modelKey?: string;
  onModelChange: (key: string) => void;
  history: readonly string[];
}) {
  const shown = [0, 1, 2].map((i) => STARTER_PROMPTS[(offset + i) % STARTER_PROMPTS.length]);
  const [stage, setStage] = useState(0);
  useEffect(() => {
    const timers = [
      setTimeout(() => setStage(1), 170),
      setTimeout(() => setStage(2), 330),
      setTimeout(() => setStage(3), 400),
      setTimeout(() => setStage(4), 550),
    ];
    return () => timers.forEach(clearTimeout);
  }, []);

  return (
    <div className="mx-auto flex min-h-full max-w-[720px] flex-col justify-center px-4 py-10 sm:px-8">
      <h1 className="text-[26px] font-normal tracking-[-0.02em] text-ink">
        <span className="home-reveal block text-ink-3" style={homeRevealStyle(stage >= 1)}>
          {greeting()}
        </span>
        <span className="home-reveal block" style={homeRevealStyle(stage >= 2)}>
          What should graff work on?
        </span>
      </h1>

      <div className="home-reveal relative mt-7" style={homeRevealStyle(stage >= 3)}>
        <PromptBar
          demo={false}
          tall
          placeholder="Ask graff to read, edit, or review this workspace…"
          models={models}
          modelKey={modelKey}
          onModelChange={onModelChange}
          onSend={onSend}
          disabled={health !== null && !health.ok}
          history={history}
        />
        {health && !health.ok && (
          <p className="mt-3 text-[12.5px] text-orange">
            graff acp is not reachable. From the repo root run{" "}
            <span className="font-mono text-ink">zig build</span>
            {health.detail ? ` — ${health.detail}` : ""}.
          </p>
        )}
      </div>

      <div className="home-reveal mt-6 flex flex-col" style={homeRevealStyle(stage >= 4)}>
        {shown.map((item) => (
          <button
            key={item.id}
            type="button"
            onClick={() => onSend(item.prompt)}
            className="-mx-2 flex items-center gap-3 rounded-control px-2 py-2.5 text-left text-[14px] text-ink transition-colors duration-150 hover:bg-hover"
          >
            <span className="text-ink-3">
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                <path d="M8 6l-5 6 5 6M16 6l5 6-5 6" />
              </svg>
            </span>
            <span className="min-w-0 truncate">{item.label}</span>
          </button>
        ))}
        <div className="mt-1 flex items-center gap-5 pl-0.5 text-[13px] text-ink-3">
          <span className="flex items-center gap-2 py-1" title={health?.cwd}>
            <span className={`size-1.5 rounded-full ${health?.ok ? "bg-green" : "bg-orange"}`} />
            {health?.ok
              ? `Connected · ${health.cwd ? (health.cwd.split("/").pop() ?? health.cwd) : "over ACP"}`
              : "Waiting for graff acp"}
          </span>
          <button type="button" onClick={shuffle} className="flex items-center gap-2 py-1 transition-colors duration-150 hover:text-ink">
            Shuffle suggestions
          </button>
        </div>
      </div>
    </div>
  );
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
  const chatIdRef = useRef(1);
  const msgIdRef = useRef(0);
  const scrollRef = useRef<HTMLDivElement>(null);

  const chatThread = chats.find((c) => c.id === activeId) ?? chats[0];
  const active = chatThread.messages.length > 0;
  const busy = busyIds.has(chatThread.id);
  const chatModel = chatThread.model ?? model ?? undefined;
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
  // A resumed session's prompts came from its file, not this browser; fold
  // them in so ArrowUp walks the conversation on screen first.
  const composerHistory = useMemo(
    () => mergeHistory(history, chatThread.messages.flatMap((m) => (m.role === "user" ? [m.text] : []))),
    [history, chatThread.messages],
  );

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
    const spawnModel = key ?? chats.find((c) => c.id === chatId)?.model ?? model ?? undefined;
    const id = await ensureSession(handleOf(chatId), spawnModel, reset, sessionNamesRef.current.get(chatId));
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

  /** Re-read graff's session directory; tabs adopt the titles graff saved. */
  const refreshStored = async () => {
    try {
      const list = await listSessions();
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

  // Stable callbacks: they are props of every memoized row.
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

  const send = async (text: string) => {
    const trimmed = text.trim();
    const chatId = chatThread.id;
    if (!trimmed || busyIds.has(chatId)) return;
    const userId = (msgIdRef.current += 1);
    const asstId = (msgIdRef.current += 1);
    const title = chatThread.title ?? (trimmed.length > 30 ? `${trimmed.slice(0, 30).trimEnd()}…` : trimmed);
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
                { id: asstId, role: "assistant", turn: { ...emptyTurn(), model: chatModel } },
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
    let turn: AssistantTurn = { ...emptyTurn(), model: chatModel };
    const startedAt = Date.now();
    const frames = frameCoalescer<AssistantTurn>((next) => patchAssistant(chatId, asstId, next));
    try {
      const id = await requireSession(chatId);
      for await (const update of prompt(handleOf(chatId), id, trimmed)) {
        turn = applyAcpUpdate(turn, update);
        if (turn.thoughtMs === undefined && turn.status !== "thinking") turn = { ...turn, thoughtMs: Date.now() - startedAt };
        frames.push(turn);
      }
      frames.cancel();
      turn = finishAcpTurn(turn);
      patchAssistant(chatId, asstId, turn);
    } catch (err) {
      frames.cancel();
      turn = { ...turn, error: err instanceof Error ? err.message : String(err), status: "error" };
      patchAssistant(chatId, asstId, turn);
    } finally {
      setBusyFor(chatId, false);
      // graff autosaves the turn in the background; look once now for the
      // title, and again after the write has had time to land.
      void refreshStored();
      setTimeout(() => void refreshStored(), 2500);
    }
  };

  const openChat = (id: number) => {
    const session = newSessionName();
    sessionNamesRef.current.set(id, session);
    setChats((current) => [...current, { id, title: null, messages: [], model: model ?? undefined, session }]);
    setActiveId(id);
    setFilesOpen(false);
    // Spawn eagerly so the first send is not stuck behind agent + MCP boot.
    void requireSession(id).catch(() => undefined);
  };

  /** Open a saved graff session: its transcript renders from the file at once,
   * and the tab's agent starts with `--resume` so a follow-up remembers it. */
  const openStored = async (name: string) => {
    const existing = chats.find((c) => c.session === name);
    if (existing) {
      setActiveId(existing.id);
      setFilesOpen(false);
      return;
    }
    let loaded: Awaited<ReturnType<typeof loadSession>>;
    try {
      loaded = await loadSession(name);
    } catch (err) {
      setHealth({ ok: true, detail: err instanceof Error ? err.message : String(err) });
      return;
    }
    const id = (chatIdRef.current += 1);
    const messages: Msg[] = loaded.messages.map((m) => ({ id: (msgIdRef.current += 1), ...m }));
    sessionNamesRef.current.set(id, name);
    setChats((current) => [
      ...current,
      { id, title: loaded.meta.title ?? name, messages, model: loaded.meta.model ?? undefined, session: name },
    ]);
    setActiveId(id);
    setFilesOpen(false);
    void requireSession(id, false, loaded.meta.model ?? undefined).catch(() => undefined);
  };

  const newChat = () => openChat((chatIdRef.current += 1));

  const dropChat = (id: number) => {
    sessionsRef.current.delete(id);
    sessionNamesRef.current.delete(id);
    setSessionIds((current) => {
      const { [id]: _gone, ...rest } = current;
      return rest;
    });
    setBusyFor(id, false);
    void disposeSession(handleOf(id));
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

  // A new message glides the thread to the bottom. After that the tail is
  // followed by a ResizeObserver on the thread body: every growth — a token,
  // a tool row, a typewriter frame — pins scrollTop instantly, so there is
  // no smooth scroll to restart per chunk (that restart was the judder), and
  // only while the reader is at the tail. Scrolling up to read earlier
  // history releases the pin until they come back down, so a streaming turn
  // never yanks the view away from them.
  const messageCount = chatThread.messages.length;
  const bodyRef = useRef<HTMLDivElement>(null);
  const stuckRef = useRef(true);
  const glideUntilRef = useRef(0);
  useEffect(() => {
    const el = scrollRef.current;
    const body = bodyRef.current;
    if (!active || !el || !body) return;
    const onScroll = () => {
      const fromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
      if (fromBottom < 48) {
        stuckRef.current = true;
        glideUntilRef.current = 0;
      } else if (performance.now() >= glideUntilRef.current) {
        // Positions mid-glide are the animation's, not the reader's.
        stuckRef.current = false;
      }
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    const observer = new ResizeObserver(() => {
      if (stuckRef.current && performance.now() >= glideUntilRef.current) el.scrollTop = el.scrollHeight;
    });
    observer.observe(body);
    return () => {
      el.removeEventListener("scroll", onScroll);
      observer.disconnect();
    };
  }, [active, activeId]);
  useEffect(() => {
    if (!active) return;
    const el = scrollRef.current;
    if (!el) return;
    stuckRef.current = true;
    glideUntilRef.current = performance.now() + 900;
    el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  }, [messageCount, activeId, active]);

  // The sidebar is graff's session directory, newest first, bucketed by day.
  const now = Date.now();
  const recents = stored.map((s) => ({
    id: s.name,
    label: s.title ?? s.name,
    group: dateGroup(s.updatedMs, now),
    hint: [s.model, relativeTime(s.updatedMs, now)].filter(Boolean).join(" · "),
  }));

  const workspaceName = health?.cwd ? (health.cwd.split("/").pop() || health.cwd) : "workspace";

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
          onClick={() => setFilesOpen((open) => !open)}
          title={health?.cwd ?? "Workspace files"}
          className={`flex h-7 items-center gap-1.5 rounded-[7px] px-2 text-[12px] font-medium transition-colors duration-100 ${
            filesOpen ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
          <IconFolder size={14} />
          <span className="max-w-40 truncate font-mono text-[11.5px]">{workspaceName}</span>
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
        activeNav={filesOpen ? "workspace" : "chats"}
        onNavigate={(key) => setFilesOpen(key === "workspace")}
        footerLabel={sessionId ? `Session ${sessionId.slice(0, 8)}` : "Connecting…"}
        onFooterClick={() => undefined}
      />

      <div className="flex min-w-0 flex-1 flex-col gap-2.5">
        <div className="flex min-h-0 flex-1 gap-2.5">
          <section className="flex min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page">
            {tabBar}
            {active ? (
              <div className="flex min-h-0 flex-1 flex-col">
                <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto overscroll-contain">
                  <div ref={bodyRef} className="mx-auto flex w-full max-w-[720px] flex-col gap-8 px-4 py-8 sm:px-8">
                    {chatThread.messages.map((message) =>
                      message.role === "user" ? (
                        <UserBubble key={message.id} text={message.text} />
                      ) : (
                        <AssistantBody key={message.id} turn={message.turn} onOpenPath={openPath} onReview={openChanges} />
                      ),
                    )}
                  </div>
                </div>
                <div className="shrink-0 bg-page px-4 pt-3 pb-6 sm:px-8">
                  <div className="mx-auto max-w-[720px]">
                    <PromptBar
                      demo={false}
                      tall
                      placeholder={busy ? "Agent is working…" : "Follow up"}
                      models={models}
                      modelKey={chatModel}
                      onModelChange={changeModel}
                      onSend={send}
                      disabled={busy}
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
                  offset={offset}
                  shuffle={() => setOffset((current) => (current + 3) % STARTER_PROMPTS.length)}
                  models={models}
                  modelKey={chatModel}
                  onModelChange={changeModel}
                />
              </div>
            )}
          </section>

          {filesOpen && <FilesPane requested={fileRequest} onClose={() => setFilesOpen(false)} />}

          {!filesOpen && active && paneTodos.length > 0 && (
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
    </main>
  );
}
