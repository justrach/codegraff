"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { fsOpen, fsReveal, fsStat, gitChanges, gitFileDiff, type FsDir, type FsFile, type GitChanges } from "@/lib/fs-client";

type Read = { kind: "files"; path: string } | { kind: "changes" } | { kind: "diff"; path: string };
type Action = { kind: "open" | "reveal"; path: string };
type Failure<T> = { message: string; operation: T };
export type FileRequest = { path: string; n: number; changes?: boolean } | null;
const message = (error: unknown) => error instanceof Error ? error.message : String(error);

/** Every navigation owns its reads; leaving a view also retires pending errors. */
export function useFilesPane(root?: string, requested?: FileRequest) {
  const navigation = useRef(0);
  const actionSequence = useRef(0);
  const [dir, setDir] = useState<FsDir | null>(null);
  const [file, setFile] = useState<FsFile | null>(null);
  const [view, setView] = useState<"files" | "changes">("files");
  const [changes, setChanges] = useState<GitChanges | null>(null);
  const [diff, setDiff] = useState<{ path: string; text: string } | null>(null);
  const [loading, setLoading] = useState<string | null>("Loading files…");
  const [failure, setFailure] = useState<Failure<Read> | null>(null);
  const [actionFailure, setActionFailure] = useState<Failure<Action> | null>(null);
  const [actionLoading, setActionLoading] = useState<string | null>(null);

  const cancelAction = useCallback(() => {
    actionSequence.current++;
    setActionFailure(null);
    setActionLoading(null);
  }, []);

  const read = useCallback(async (operation: Read) => {
    const request = ++navigation.current;
    cancelAction();
    setFailure(null);
    setLoading(operation.kind === "changes" ? "Loading changes…" : operation.kind === "diff" ? "Loading diff…" : "Loading files…");
    setView(operation.kind === "files" ? "files" : "changes");
    setDiff(operation.kind === "diff" ? { path: operation.path, text: "" } : null);
    if (operation.kind === "changes") setChanges(null);
    try {
      if (operation.kind === "files") {
        const result = await fsStat(operation.path, root);
        if (request !== navigation.current) return;
        if (result.dir) { setDir(result); setFile(null); }
        else setFile(result);
      } else if (operation.kind === "changes") {
        const result = await gitChanges(root);
        if (request !== navigation.current) return;
        setChanges(result);
      } else {
        const text = await gitFileDiff(operation.path, root);
        if (request !== navigation.current) return;
        setDiff({ path: operation.path, text });
      }
    } catch (error) {
      if (request === navigation.current) setFailure({ message: message(error), operation });
    } finally {
      if (request === navigation.current) setLoading(null);
    }
  }, [root, cancelAction]);

  const show = useCallback((path: string) => read({ kind: "files", path }), [read]);
  const loadChanges = useCallback(() => read({ kind: "changes" }), [read]);
  const openFileDiff = useCallback((path: string) => read({ kind: "diff", path }), [read]);
  const backToChanges = useCallback(() => {
    navigation.current++;
    cancelAction();
    setLoading(null);
    setFailure(null);
    setDiff(null);
    if (!changes) void loadChanges();
  }, [changes, cancelAction, loadChanges]);
  const openFilesView = useCallback(() => {
    // Reload the last successful location, including after a cancelled diff.
    void show(file?.path ?? dir?.path ?? "");
  }, [show, file?.path, dir?.path]);

  const act = useCallback(async (operation: Action) => {
    const request = ++actionSequence.current, location = navigation.current;
    setActionFailure(null);
    setActionLoading(operation.kind === "open" ? "Opening file…" : "Revealing in Finder…");
    try {
      await (operation.kind === "open" ? fsOpen : fsReveal)(operation.path, root);
    } catch (error) {
      if (request === actionSequence.current && location === navigation.current) setActionFailure({ message: message(error), operation });
    } finally {
      if (request === actionSequence.current && location === navigation.current) setActionLoading(null);
    }
  }, [root]);

  useEffect(() => {
    void show("");
    return () => { navigation.current++; actionSequence.current++; };
  }, [show]);
  useEffect(() => {
    if (!requested) return;
    if (requested.changes) void loadChanges();
    else void show(requested.path);
  }, [requested, show, loadChanges]);

  return {
    dir, file, view, changes, diff, loading, error: failure?.message, actionError: actionFailure?.message, actionLoading,
    show, loadChanges, openFileDiff, backToChanges, openFilesView, act,
    retry: () => { if (failure) void read(failure.operation); },
    retryAction: () => { if (actionFailure) void act(actionFailure.operation); },
  };
}
