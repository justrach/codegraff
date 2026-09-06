import type { Dispatch, SetStateAction, MutableRefObject } from "react";
import type { Chat } from "./harness-types";
import { basename, findWorkspace, removeWorkspace, upsertWorkspace, type Workspace } from "@/lib/workspaces";
import { persistProjects } from "@/lib/project-preferences";
type Setter<T> = Dispatch<SetStateAction<T>>;
type Ref<T> = MutableRefObject<T>;
type Actions = {
  workspacesRef: Ref<Workspace[]>; activePathRef: Ref<string | null>;
  chatsRef: Ref<Chat[]>; chatIdRef: Ref<number>; activeId: number; root?: string;
  setWorkspaces: Setter<Workspace[]>; setActivePath: Setter<string | null>;
  setChats: Setter<Chat[]>; setPanes: Setter<number[]>; setActiveId: Setter<number>;
  setFilesOpen: Setter<boolean>; setDialog: (value: null) => void;
  refreshStored: () => Promise<void>; requireSession: (id: number, force: boolean) => Promise<string>;
  adoptCatalog: (id: number) => Promise<unknown>; openChat: (id: number) => void;
};
export function workspaceActions({workspacesRef, activePathRef, chatsRef, chatIdRef, activeId, root,
  setWorkspaces, setActivePath, setChats, setPanes, setActiveId, setFilesOpen, setDialog,
  refreshStored, requireSession, adoptCatalog, openChat}: Actions) {
  const persistWorkspaces = (list: Workspace[]) => {
    workspacesRef.current = list;
    setWorkspaces(list);
    persistProjects(window.localStorage, list, activePathRef.current);
  };

  const activate = (path: string | null) => {
    activePathRef.current = path;
    setActivePath(path);
    persistProjects(window.localStorage, workspacesRef.current, path);
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
    setPanes((current) => current.filter((pane) => pane !== chatId));
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
      const next = list[0]?.path ?? root ?? null;
      if (next) switchWorkspace(next);
      else activate(null);
    }
  };

  const newProjectChat = (path: string) => { activate(path); openChat((chatIdRef.current += 1)); };
  return { switchWorkspace, addWorkspace, saveWorkspace, forgetWorkspace, newProjectChat, activateWorkspace: activate };
}
