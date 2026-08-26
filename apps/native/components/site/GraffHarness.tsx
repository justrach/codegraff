"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import ApprovalCard from "@/components/primitives/ApprovalCard";
import LoadingState from "@/components/primitives/LoadingState";
import PromptBar from "@/components/primitives/PromptBar";
import SidebarNav from "@/components/primitives/SidebarNav";
import StreamingText from "@/components/primitives/StreamingText";
import TaskRows from "@/components/primitives/TaskRows";
import ThinkingState from "@/components/primitives/ThinkingState";
import ToolChips from "@/components/primitives/ToolChips";
import { ThemeToggle } from "@/components/site/ThemeToggle";
import {
  MODELS,
  STARTER_PROMPTS,
  answer,
  cancel,
  chat,
  checkHealth,
  createSession,
  setModel,
  type Health,
} from "@/lib/graff-client";
import {
  applyEvent,
  emptyTurn,
  type AssistantTurn,
} from "@/lib/graff-events";

const NAME = "there";

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

function UserBubble({ text }: { text: string }) {
  return (
    <div className="flex justify-end pl-10 sm:pl-24" style={{ animation: "fade-up 300ms cubic-bezier(0.23,1,0.32,1) both" }}>
      <div className="rounded-xl bg-field px-3.5 py-2 text-[13px] leading-relaxed text-ink shadow-hairline">{text}</div>
    </div>
  );
}

function AssistantBody({
  turn,
  onAnswer,
}: {
  turn: AssistantTurn;
  onAnswer: (text: string, callId?: string) => void;
}) {
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
  }));

  return (
    <article className="min-w-0" style={{ animation: "fade-up 450ms cubic-bezier(0.23,1,0.32,1) both" }}>
      {(turn.status === "thinking" || reasoningRows.length > 0) && (
        <ThinkingState
          variant="Reasoning"
          rows={reasoningRows.length ? reasoningRows : [{ primary: "Waiting on the model…" }]}
          activeLabel={turn.model ? `Thinking · ${turn.model}` : "Thinking"}
          doneLabel={turn.status === "thinking" ? "Thinking" : "Thought"}
          working={turn.status === "thinking"}
        />
      )}
      {toolRows.length > 0 && (
        <div className="mt-4">
          <ToolChips rows={toolRows} diffs={turn.diffs} />
        </div>
      )}
      {(turn.text || turn.status === "streaming") && (
        <div className="mt-4 max-w-[630px]">
          <StreamingText
            fill
            loop={false}
            text={turn.text}
            streaming={turn.status === "streaming" || turn.status === "thinking"}
          />
        </div>
      )}
      {turn.ask && (
        <div className="mt-5">
          <ApprovalCard
            resettable={false}
            questions={[
              {
                q: turn.ask.question,
                type: "radio",
                options: ["Continue", "Skip"],
              },
            ]}
            onSubmitted={(answers) => {
              const text = answers?.[0] && answers[0] !== "Skip" ? answers[0] : answers?.[0] === "Skip" ? "" : "continue";
              onAnswer(text || "continue", turn.ask?.callId);
            }}
          />
        </div>
      )}
      {turn.error && (
        <p className="mt-4 max-w-[620px] text-[13.5px] leading-[1.65] text-red">{turn.error}</p>
      )}
      {turn.recap && turn.status === "done" && (
        <p className="mt-3 text-[12px] text-ink-3">{turn.recap}</p>
      )}
      {turn.costUsd !== undefined && turn.status === "done" && (
        <p className="mt-1 font-mono text-[11px] text-ink-3">${turn.costUsd.toFixed(4)}</p>
      )}
    </article>
  );
}

type Msg =
  | { id: number; role: "user"; text: string }
  | { id: number; role: "assistant"; turn: AssistantTurn };

type Chat = { id: number; title: string | null; messages: Msg[] };

function EmptyState({
  onSend,
  health,
  offset,
  shuffle,
}: {
  onSend: (text: string) => void;
  health: Health | null;
  offset: number;
  shuffle: () => void;
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
          Hello {NAME}
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
          models={MODELS}
          onSend={onSend}
          disabled={health !== null && !health.ok}
        />
        {health && !health.ok && (
          <p className="mt-3 text-[12.5px] text-orange">
            graff serve is not reachable. From the repo root run{" "}
            <span className="font-mono text-ink">graff serve --port 8787</span>
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
          <span className="flex items-center gap-2 py-1">
            <span className={`size-1.5 rounded-full ${health?.ok ? "bg-green" : "bg-orange"}`} />
            {health?.ok ? "Connected to graff serve" : "Waiting for graff serve"}
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
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [model, setModelKey] = useState(process.env.NEXT_PUBLIC_GRAFF_MODEL || MODELS[0].key);
  const [busy, setBusy] = useState(false);
  const chatIdRef = useRef(1);
  const msgIdRef = useRef(0);
  const sessionRef = useRef<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  const chatThread = chats.find((c) => c.id === activeId) ?? chats[0];
  const active = chatThread.messages.length > 0;
  const lastAssistant = [...chatThread.messages].reverse().find((m): m is Extract<Msg, { role: "assistant" }> => m.role === "assistant");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const h = await checkHealth();
      if (cancelled) return;
      setHealth(h);
      if (!h.ok) return;
      try {
        const info = await createSession({ model, yolo: true });
        if (cancelled) return;
        sessionRef.current = info.session_id;
        setSessionId(info.session_id);
      } catch (err) {
        if (!cancelled) {
          setHealth({ ok: false, detail: err instanceof Error ? err.message : String(err) });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
    // session is created once per mount; model changes go through set_model
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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

  const ensureSession = async (): Promise<string> => {
    if (sessionRef.current) return sessionRef.current;
    const info = await createSession({ model, yolo: true });
    sessionRef.current = info.session_id;
    setSessionId(info.session_id);
    setHealth({ ok: true });
    return info.session_id;
  };

  const send = async (text: string) => {
    const trimmed = text.trim();
    if (!trimmed || busy) return;
    const userId = (msgIdRef.current += 1);
    const asstId = (msgIdRef.current += 1);
    const title = chatThread.title ?? (trimmed.length > 30 ? `${trimmed.slice(0, 30).trimEnd()}…` : trimmed);
    setChats((current) =>
      current.map((c) =>
        c.id !== chatThread.id
          ? c
          : {
              ...c,
              title,
              messages: [
                ...c.messages,
                { id: userId, role: "user", text: trimmed },
                { id: asstId, role: "assistant", turn: emptyTurn() },
              ],
            },
      ),
    );
    setBusy(true);
    let turn = emptyTurn();
    try {
      const id = await ensureSession();
      for await (const ev of chat(id, trimmed)) {
        turn = applyEvent(turn, ev);
        patchAssistant(chatThread.id, asstId, turn);
      }
    } catch (err) {
      turn = applyEvent(turn, { type: "error", message: err instanceof Error ? err.message : String(err) });
      patchAssistant(chatThread.id, asstId, turn);
    } finally {
      setBusy(false);
    }
  };

  const answerAsk = async (text: string, callId?: string) => {
    const id = sessionRef.current;
    if (!id || !lastAssistant) return;
    try {
      await answer(id, { text, callId });
      patchAssistant(chatThread.id, lastAssistant.id, { ...lastAssistant.turn, ask: undefined, status: "streaming" });
    } catch (err) {
      patchAssistant(chatThread.id, lastAssistant.id, {
        ...lastAssistant.turn,
        error: err instanceof Error ? err.message : String(err),
        status: "error",
      });
    }
  };

  const newChat = () => {
    const id = (chatIdRef.current += 1);
    setChats((current) => [...current, { id, title: null, messages: [] }]);
    setActiveId(id);
  };

  const closeChat = (id: number) => {
    const remaining = chats.filter((c) => c.id !== id);
    if (remaining.length === 0) {
      const nid = (chatIdRef.current += 1);
      setChats([{ id: nid, title: null, messages: [] }]);
      setActiveId(nid);
      return;
    }
    setChats(remaining);
    if (id === activeId) setActiveId(remaining[remaining.length - 1].id);
  };

  const pickRecent = (_id: string, label: string, prompt?: string) => {
    const existing = chats.find((c) => c.title === label);
    if (existing) {
      setActiveId(existing.id);
      return;
    }
    if (chatThread.messages.length === 0) {
      void send(prompt ?? label);
      return;
    }
    const id = (chatIdRef.current += 1);
    setChats((current) => [...current, { id, title: null, messages: [] }]);
    setActiveId(id);
    queueMicrotask(() => void send(prompt ?? label));
  };

  useEffect(() => {
    if (!active) return;
    const el = scrollRef.current;
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  }, [chatThread.messages, active, lastAssistant?.turn.text, lastAssistant?.turn.tools.length]);

  const recents = [
    ...STARTER_PROMPTS.map((p) => ({ id: p.id, label: p.label, prompt: p.prompt })),
    ...chats.filter((c) => c.title).map((c) => ({ id: `chat-${c.id}`, label: c.title as string, prompt: undefined })),
  ];

  const tabBar = (
    <div className="flex h-11 shrink-0 items-center gap-1 overflow-x-auto border-b border-line px-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
      {chats.map((c) => (
        <div
          key={c.id}
          className={`group/tab flex h-7 w-36 shrink-0 items-center gap-0.5 rounded-[7px] pl-2.5 pr-1 text-[12.5px] font-medium transition-colors duration-100 ${
            c.id === activeId ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
          }`}
        >
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
        onPick={pickRecent}
        onNewChat={newChat}
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
                  <div className="mx-auto flex w-full max-w-[720px] flex-col gap-8 px-4 py-8 sm:px-8">
                    {chatThread.messages.map((message) =>
                      message.role === "user" ? (
                        <UserBubble key={message.id} text={message.text} />
                      ) : (
                        <AssistantBody key={message.id} turn={message.turn} onAnswer={answerAsk} />
                      ),
                    )}
                    {busy && lastAssistant?.turn.status === "thinking" && !lastAssistant.turn.reasoning && (
                      <div className="flex min-h-6 items-center">
                        <LoadingState label="Thinking" variant="Dots" />
                      </div>
                    )}
                  </div>
                </div>
                <div className="shrink-0 bg-page px-4 pt-3 pb-6 sm:px-8">
                  <div className="mx-auto max-w-[720px]">
                    <PromptBar
                      demo={false}
                      tall
                      placeholder={busy ? "Agent is working…" : "Reply"}
                      models={MODELS}
                      modelKey={model}
                      onModelChange={(key) => {
                        setModelKey(key);
                        if (sessionRef.current) void setModel(sessionRef.current, key);
                      }}
                      onSend={send}
                      disabled={busy}
                    />
                    {busy && (
                      <button
                        type="button"
                        onClick={() => sessionRef.current && void cancel(sessionRef.current)}
                        className="mt-2 text-[12px] text-ink-3 transition-colors hover:text-ink"
                      >
                        Cancel turn
                      </button>
                    )}
                  </div>
                </div>
              </div>
            ) : (
              <div className="min-h-0 flex-1 overflow-y-auto">
                <EmptyState
                  onSend={send}
                  health={health}
                  offset={offset}
                  shuffle={() => setOffset((current) => (current + 3) % STARTER_PROMPTS.length)}
                />
              </div>
            )}
          </section>

          {active && paneTodos.length > 0 && (
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
