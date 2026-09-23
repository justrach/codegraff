import type { PermissionRequest } from "@/lib/acp-permission";
import type { MutableRefObject, Dispatch, SetStateAction } from "react";
import { createTurnPainter } from "@/lib/turn-painter";
import { applyAcpUpdate, emptyTurn, finishAcpTurn, type AssistantTurn } from "@/lib/acp";
import { prompt } from "@/lib/acp-client";
import { annotationsBlock, type BrowserPin } from "@/lib/browser/annotations";
import { browserHandle, browserNav } from "@/lib/browser-client";
import { extensionAnnotationsBlock } from "@/lib/extension-annotations";
import { pushHistory, saveHistory } from "@/lib/prompt-history";
import type { QueuedPrompt } from "@/lib/prompt-queue";
import type { createQueueSteerer } from "@/lib/prompt-queue-steer";
import type { Chat } from "./harness-types";
import { playUiSound } from "@/lib/ui-sounds";
type Ref<T> = MutableRefObject<T>;
type Setter<T> = Dispatch<SetStateAction<T>>;
type Props = {
  onPermission?(chatId: number, request: PermissionRequest | null): void;
  onStarted(id: number): void;
  onCompleted(id: number): void;
  runningRef: Ref<Set<number>>; steerer: ReturnType<typeof createQueueSteerer>; setFollowing: Setter<boolean>;
  chatsRef: Ref<Chat[]>; model: string | null; msgIdRef: Ref<number>; setChats: Setter<Chat[]>;
  setCancelError: Setter<Record<number, string>>;
  setBusyFor(id: number, on: boolean): void; setHistory: Setter<string[]>;
  pinsRef: Ref<Record<number, BrowserPin[]>>; handleOf(id: number): string;
  setPins(id: number, pins: BrowserPin[]): void; requireSession(id: number): Promise<string>;
  sessionIsCurrent(id: number, sessionId: string): boolean;
  prepareModel(id: number): Promise<void>;
  adoptCatalog(id: number): Promise<void>; refreshChangedCatalog(id: number, sessionId: string): Promise<void>;
  refreshStored(): Promise<void>;
  takeQueuedPrompt(id: number): QueuedPrompt | undefined;
};
export function createPromptRunner({onPermission, onStarted, onCompleted, runningRef, steerer, setFollowing, chatsRef, model, msgIdRef, setChats, setBusyFor, setHistory, pinsRef, handleOf, setPins, requireSession, sessionIsCurrent, prepareModel, adoptCatalog, refreshChangedCatalog, refreshStored, takeQueuedPrompt, setCancelError}: Props) {
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

  const runPrompt = async (chatId: number, trimmed: string, opts?: { edit?: number }) => {
    setCancelError(current => { const next = { ...current }; delete next[chatId]; return next; });
    runningRef.current.add(chatId);
    onStarted(chatId);
    steerer.begin(chatId);
    setFollowing(true);
    const thread = chatsRef.current.find((c) => c.id === chatId);
    const spawnModel = thread?.nextModel ?? thread?.model ?? model ?? undefined;
    const userId = (msgIdRef.current += 1);
    const asstId = (msgIdRef.current += 1);
    const title = thread?.title ?? (trimmed.length > 30 ? `${trimmed.slice(0, 30).trimEnd()}…` : trimmed);
    // The first prompt of a tab names it, in the model's words.
    if (!thread?.title) nameChat(chatId, trimmed, thread?.cwd);
    const editN = opts?.edit;
    setChats((current) =>
      current.map((c) => {
        if (c.id !== chatId) return c;
        if (editN) {
          let seen = 0;
          const keep = [];
          for (const message of c.messages) {
            if (message.role === "user" && message.origin !== "notification") {
              seen += 1;
              if (seen === editN) { keep.push({ ...message, text: trimmed }); break; }
            }
            keep.push(message);
          }
          return { ...c, title, snapshot: undefined, messages: [...keep, { id: asstId, role: "assistant", turn: { ...emptyTurn(), model: spawnModel, startedAt: Date.now() } }] };
        }
        return {
          ...c, title, snapshot: undefined,
          messages: [...c.messages, { id: userId, role: "user", text: trimmed }, { id: asstId, role: "assistant", turn: { ...emptyTurn(), model: spawnModel, startedAt: Date.now() } }],
        };
      }),
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
    const settingsCommand = /^\/(effort|reasoning|fast)(?:\s|$)/.test(trimmed);
    const pins = settingsCommand ? [] : pinsRef.current[chatId] ?? [];
    if (pins.length > 0) {
      const handle = await browserHandle(handleOf(chatId)).catch(() => null);
      const blocks = [annotationsBlock(pins.filter((p) => p.source !== "extension"), handle),
        extensionAnnotationsBlock(pins.filter((p) => p.source === "extension"))].filter(Boolean);
      wire = `${trimmed}\n\n${blocks.join("\n\n")}`;
      setPins(chatId, []);
    }
    let turn: AssistantTurn = { ...emptyTurn(), model: spawnModel, startedAt: Date.now() };
    const painter = createTurnPainter<AssistantTurn>(next => patchAssistant(chatId, asstId, next));
    const startedAt = Date.now();
    let sessionId: string | null = null;
    let configChanged = false;
    let promptCompleted = false;
    try {
      await prepareModel(chatId);
      const id = await requireSession(chatId);
      sessionId = id;
      if (editN) {
        for await (const _ of prompt(handleOf(chatId), id, `/edit ${editN} ${trimmed}`)) { /* rewind only */ }
      }
      turn = { ...turn, connected: true, lastUpdateAt: Date.now() };
      painter.update(turn);
      for await (const update of prompt(handleOf(chatId), id, wire)) {
        if (update.sessionUpdate === "gui_permission") { onPermission?.(chatId, update.permission as PermissionRequest); continue; }
        if (update.sessionUpdate === "config_option_update") configChanged = true;
        // The bridge acknowledges prompt dispatch before model output, so
        // queued steering can cancel even during a slow first response.
        if (update.sessionUpdate === "gui_turn_end") steerer.finish(chatId);
        else steerer.ready(chatId);
        turn = applyAcpUpdate(turn, update);
        if (turn.thoughtMs === undefined && turn.status !== "thinking") turn = { ...turn, thoughtMs: Date.now() - startedAt };
        painter.update(turn);
      }
      promptCompleted = true;
      // The turn carried pins, so the agent most likely changed the page:
      // reload the chat's tab so the pane shows the result without a click.
      if (pins.length > 0) void browserNav(handleOf(chatId), "reload").catch(() => undefined);
      turn = finishAcpTurn(turn);
      painter.finish(turn);
      if (turn.status === "done" && !turn.error) {
        onCompleted(chatId);
        if (!trimmed.startsWith("/")) playUiSound("ready");
      } else if (turn.error) playUiSound("error");
    } catch (err) {
      turn = finishAcpTurn({ ...turn, error: err instanceof Error ? err.message : String(err), status: "error" });
      painter.finish(turn);
      playUiSound("error");
    } finally {
      onPermission?.(chatId, null);
      painter.dispose();
      steerer.finish(chatId);
      runningRef.current.delete(chatId);
      setBusyFor(chatId, false);
      // A turn may change effort without a slash command. Refresh once after
      // its stream ends, even on cancellation or a later transport error.
      if (sessionId && sessionIsCurrent(chatId, sessionId)) {
        if (configChanged) void refreshChangedCatalog(chatId, sessionId).catch(() => undefined);
        else if (settingsCommand && promptCompleted) void adoptCatalog(chatId).catch(() => undefined);
      }
      void refreshStored();
      setTimeout(() => void refreshStored(), 2500);
      const next = takeQueuedPrompt(chatId);
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
  return runPrompt;
}
