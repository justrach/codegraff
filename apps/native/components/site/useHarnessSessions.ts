import { useEffect, useRef, useState, type MutableRefObject, type Dispatch, type SetStateAction } from "react";
import { bindMcpAppChat, checkHealth, disposePage, ensureSession, fetchModels, type Health } from "@/lib/acp-client";
import { catalogMayWriteChatModel, catalogMayWriteGlobalKey, sameModels } from "@/lib/composer-model";
import { pumpIdlePeerTurns } from "./idle-peer-turns";
import type { AcpCommand } from "@/lib/acp";
import type { PromptModel } from "@/components/primitives/PromptBar";
import { listSessionsPage, type StoredSession } from "@/lib/sessions";
import { restoreProjects, persistProjects } from "@/lib/project-preferences";
import { findWorkspace, mergeWorkspaceActivity, restoreWorkspaceSelection, type Workspace } from "@/lib/workspaces";
import { newSessionName, type Chat } from "./harness-types";
type Ref<T> = MutableRefObject<T>;
type Setter<T> = Dispatch<SetStateAction<T>>;
type Props = {
  sessionsRef: Ref<Map<number, string>>; sessionNamesRef: Ref<Map<number, string>>;
  chatsRef: Ref<Chat[]>; workspacesRef: Ref<Workspace[]>; activePathRef: Ref<string | null>;
  pageRef: Ref<string>; runningRef: Ref<Set<number>>; model: string | null; activeId: number;
  handleOf(id: number): string; setModels: Setter<PromptModel[]>;
  setCommands: Setter<Record<number, AcpCommand[]>>; setCatalogCommands: Setter<AcpCommand[]>;
  setChatModel(id: number, key: string): void; setModelKey: Setter<string | null>;
  setSessionIds: Setter<Record<number, string>>; setHealth: Setter<Health | null>;
  setWorkspaces: Setter<Workspace[]>; setActivePath: Setter<string | null>;
  setChats: Setter<Chat[]>; setStored: Setter<StoredSession[]>; setStoredTotal: Setter<number>;
  pendingPick(): { key: string; chatId: number } | null;
};
const SIDEBAR_PAGE = 12;
export function useHarnessSessions({sessionsRef, sessionNamesRef, chatsRef, workspacesRef, activePathRef, pageRef, runningRef, model, activeId, handleOf, setModels, setCommands, setCatalogCommands, setChatModel, setModelKey, setSessionIds, setHealth, setWorkspaces, setActivePath, setChats, setStored, setStoredTotal, pendingPick}: Props) {
  const [projectsReady, setProjectsReady] = useState(false);
  const pendingRef = useRef(pendingPick);
  pendingRef.current = pendingPick;
  const idleCtl = useRef(new Map<number, AbortController>());
  const watchIdle = (chatId: number, sessionId: string) => {
    idleCtl.current.get(chatId)?.abort();
    const ac = new AbortController();
    idleCtl.current.set(chatId, ac);
    void pumpIdlePeerTurns({
      chatId, handle: handleOf(chatId), sessionId, signal: ac.signal,
      // Every pump pauses while ANY turn runs: the six-slot HTTP/1.1 pool is
      // per origin, so one chat's turn frees the idle streams of all the
      // others or a mid-turn attach never starts.
      running: () => runningRef.current.size > 0, setChats,
    });
  };
  /** A closed tab's pump would otherwise hold its stream — and its pool slot —
   * until unload; the server only ends it when the client hangs up. */
  const unwatchIdle = (chatId: number) => {
    idleCtl.current.get(chatId)?.abort();
    idleCtl.current.delete(chatId);
  };
  const adoptCatalog = async (chatId: number) => {
    // Pill follows this chat's agent. A transient /api/models process is not that agent.
    const handle = sessionsRef.current.has(chatId) ? handleOf(chatId) : undefined;
    try {
      const { models: live, current, commands: available } = await fetchModels(handle, activePathRef.current ?? undefined);
      if (live.length > 0) setModels((prev) => (sameModels(prev, live) ? prev : live));
      if (available?.length) { setCatalogCommands(available); setCommands(old => ({ ...old, [chatId]: available })); }
      if (current && handle) {
        const chat = chatsRef.current.find((c) => c.id === chatId);
        if (catalogMayWriteChatModel(chatId, pendingRef.current()) && chat?.model !== current) {
          setChatModel(chatId, current);
        }
      } else if (current && catalogMayWriteGlobalKey(false)) {
        setModelKey((key) => key ?? current);
      }
    } catch {
      // Keep the spawn model. A failed catalog must not fail the session.
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

  useEffect(() => {
    bindMcpAppChat(sessionsRef.current.has(activeId) ? handleOf(activeId) : undefined);
  }, [activeId, handleOf]);

  const requireSession = async (chatId: number, reset = false, key?: string): Promise<string> => {
    if (chatsRef.current.find(c => c.id === chatId)?.snapshot) throw new Error("Continue here before resuming this saved snapshot.");
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
    bindMcpAppChat(handleOf(chatId));
    setSessionIds((current) => ({ ...current, [chatId]: id }));
    watchIdle(chatId, id);
    // Populate the command menu from this agent's advertisement.
    if (commands.length > 0) setCommands((current) => ({ ...current, [chatId]: commands }));
    setHealth({ ok: true });
    if (spawnModel) {
      setChatModel(chatId, spawnModel);
      setModelKey(spawnModel);
    }
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
      // Keep startup context visible without persisting it as a folder choice.
      const root = h.cwd ?? "";
      const savedProjects = await restoreProjects(window.localStorage);
      if (cancelled) return;
      let { list, active } = restoreWorkspaceSelection(savedProjects.list, savedProjects.active, root);
      try {
        const query = new URLSearchParams();
        for (const row of savedProjects.list) query.append("root", row.path);
        const response = await fetch(`/api/workspace-history?${query}`, { signal: AbortSignal.timeout(5000) });
        if (response.ok) {
          const data = await response.json();
          if (Array.isArray(data.workspaces)) list = mergeWorkspaceActivity(list, data.workspaces);
        }
      } catch { /* Saved folder choices still work while history is unavailable. */ }
      if (cancelled) return;
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
        setProjectsReady(true);
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
      for (const ac of idleCtl.current.values()) ac.abort();
      idleCtl.current.clear();
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

  catalogRef.current = { adopt: (id: number) => { if (!runningRef.current.has(id)) void adoptCatalog(id).catch(() => undefined); }, activeId };
  return { adoptCatalog, requireSession, refreshStored, projectsReady, unwatchIdle };
}
