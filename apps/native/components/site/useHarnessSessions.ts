import { useEffect, useRef, useState, type MutableRefObject, type Dispatch, type SetStateAction } from "react";
import { checkHealth, disposePage, ensureSession, fetchModels, type Health } from "@/lib/acp-client";
import type { AcpCommand } from "@/lib/acp";
import type { PromptModel } from "@/components/primitives/PromptBar";
import { listSessionsPage, type StoredSession } from "@/lib/sessions";
import { restoreProjects, persistProjects } from "@/lib/project-preferences";
import { basename, findWorkspace, upsertWorkspace, type Workspace } from "@/lib/workspaces";
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
};
const SIDEBAR_PAGE = 12;
export function useHarnessSessions({sessionsRef, sessionNamesRef, chatsRef, workspacesRef, activePathRef, pageRef, runningRef, model, activeId, handleOf, setModels, setCommands, setCatalogCommands, setChatModel, setModelKey, setSessionIds, setHealth, setWorkspaces, setActivePath, setChats, setStored, setStoredTotal}: Props) {
  const [projectsReady, setProjectsReady] = useState(false);
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
  return { adoptCatalog, requireSession, refreshStored, projectsReady };
}
