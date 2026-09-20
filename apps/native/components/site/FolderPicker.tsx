"use client";

import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  cycleFolderSort,
  displayDirPath,
  folderNameError,
  formatFolderAge,
  formatFolderModified,
  loadFolderView,
  presentFolderEntries,
  sameBrowse,
  sameDir,
  saveFolderView,
  splitFolderQuery,
  stepFolderSelection,
  uniqueFolderName,
  type FolderSort,
  type FolderView,
} from "@/lib/folder-picker";
import { browseFolders, createFolder, type FolderListing } from "@/lib/fs-client";
import { IconFolder, IconPlusMedium } from "@/lib/icons";
import { basename } from "@/lib/workspaces";

const FIELD =
  "h-8 w-full rounded-control bg-field px-2.5 text-[13px] text-ink shadow-hairline outline-none placeholder:text-ink-3 focus:bg-hover";

function Chip({
  active,
  onClick,
  children,
  title,
  pressed,
}: {
  active?: boolean;
  onClick: () => void;
  children: ReactNode;
  title?: string;
  pressed?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={title}
      aria-pressed={pressed ?? active}
      className={`h-6 shrink-0 rounded-full px-2 text-[11.5px] font-medium transition-colors ${
        active ? "bg-hover-2 text-ink" : "bg-field text-ink-2 shadow-hairline hover:bg-hover hover:text-ink"
      }`}
    >
      {children}
    </button>
  );
}

function GitBadge() {
  return <span className="shrink-0 rounded-full bg-field px-1.5 font-mono text-[10px] text-ink-2 shadow-hairline">git</span>;
}

function sortTitle(sort: FolderSort, view: FolderView): string {
  if (sort === "name") {
    if (view.sort !== "name") return "Sort by name";
    return view.reverse ? "Sorted Z to A. Click for A to Z." : "Sorted A to Z. Click for Z to A.";
  }
  if (view.sort !== "modified") return "Sort by date modified";
  return view.reverse ? "Oldest first. Click for newest." : "Newest first. Click for oldest.";
}

export function FolderPicker({ startPath, onPick, onClose }: { startPath?: string; onPick: (path: string) => void; onClose: () => void }) {
  const [listing, setListing] = useState<FolderListing | null>(null);
  const [typed, setTyped] = useState(displayDirPath(startPath ?? "~"));
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [view, setView] = useState<FolderView>(() => loadFolderView(typeof localStorage === "undefined" ? null : localStorage));
  const [creating, setCreating] = useState<string | null>(null);
  const [active, setActive] = useState<number | null>(null);
  // Only the newest navigation may land: a slow listing of a big folder
  // must not overwrite the one the user has already moved on to.
  const seq = useRef(0);
  const pickRef = useRef(onPick);
  pickRef.current = onPick;
  const creatingRef = useRef(false);
  const results = useRef<HTMLDivElement>(null);
  const keyboard = useRef(false);
  const listId = useId();
  const go = useCallback(async (target: string, opts: { pick?: boolean; refresh?: boolean } = {}) => {
    const n = (seq.current += 1);
    const refresh = opts.refresh === true;
    setActive(null);
    if (!refresh) setBusy(true);
    setError(null);
    try {
      const next = await browseFolders(target);
      if (n !== seq.current) return;
      setListing(next);
      if (!refresh) setTyped(displayDirPath(next.path));
      setError(null);
      if (opts.pick) pickRef.current(next.path);
    } catch (err) {
      if (n !== seq.current) return;
      if (!refresh) setError(err instanceof Error ? err.message : String(err));
    } finally {
      if (n === seq.current) setBusy(false);
    }
  }, []);
  useEffect(() => {
    void go(startPath ?? "~");
    return () => { seq.current++; };
  }, [go, startPath]);
  useEffect(() => {
    saveFolderView(typeof localStorage === "undefined" ? null : localStorage, view);
  }, [view]);

  const parsed = splitFolderQuery(typed, listing?.path);
  const listingPath = listing?.path ?? null;
  const listingHome = listing?.home ?? null;
  useEffect(() => {
    if (!listingPath || !parsed.browse) return;
    if (sameBrowse(parsed.browse, listingPath, listingHome)) return;
    void go(parsed.browse, { refresh: true });
    const request = seq.current;
    return () => { if (seq.current === request) seq.current++; };
  }, [go, listingHome, listingPath, parsed.browse]);
  useEffect(() => {
    setCreating(null);
  }, [listingPath]);
  const shown = useMemo(
    () => (listing ? presentFolderEntries(listing.entries, parsed.needle, view) : []),
    [listing, parsed.needle, view],
  );
  const activeEntry = active == null ? undefined : shown[active];
  useLayoutEffect(() => {
    if (active == null || !keyboard.current) return;
    keyboard.current = false;
    const viewport = results.current;
    const row = viewport?.querySelector<HTMLElement>(`[data-folder-index="${active}"]`);
    if (!viewport || !row) return;
    const viewportRect = viewport.getBoundingClientRect();
    const rowRect = row.getBoundingClientRect();
    if (rowRect.top < viewportRect.top) viewport.scrollTop -= viewportRect.top - rowRect.top;
    else if (rowRect.bottom > viewportRect.bottom) viewport.scrollTop += rowRect.bottom - viewportRect.bottom;
  }, [active]);

  const crumbs = listing ? listing.path.split("/").filter(Boolean) : [];
  const crumbPath = (i: number) => `/${crumbs.slice(0, i + 1).join("/")}`;
  const home = listing?.home;
  const repo = listing?.default;

  const beginCreate = () => {
    if (!listing) return;
    setActive(null);
    const needle = parsed.needle.trim();
    const base = needle && folderNameError(needle) == null ? needle : "untitled folder";
    setView((current) => (current.gitOnly ? { ...current, gitOnly: false } : current));
    setCreating(uniqueFolderName(listing.entries.map((entry) => entry.name), base));
    setError(null);
  };

  const submitCreate = async () => {
    if (!listing || creating == null || creatingRef.current) return;
    const reason = folderNameError(creating);
    if (reason) {
      setError(reason);
      return;
    }
    creatingRef.current = true;
    setError(null);
    try {
      await createFolder(listing.path, creating);
      setCreating(null);
      await go(listing.path, { refresh: true });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      creatingRef.current = false;
    }
  };

  return (
    <>
      <div className="flex shrink-0 flex-col gap-2 border-b border-line px-4 py-3">
        <form
          className="flex items-center gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            void go(typed);
          }}
        >
          <span className="flex size-5 shrink-0 items-center justify-center text-ink-2">
            <IconFolder size={16} />
          </span>
          <input
            value={typed}
            onChange={(event) => {
              // Editing an explicit lookup retires it and makes the new path
              // actionable immediately, even if the old folder is still loading.
              if (busy) { seq.current++; setBusy(false); }
              setActive(null);
              keyboard.current = false;
              if (results.current) results.current.scrollTop = 0;
              setTyped(event.target.value); setError(null);
            }}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing) return;
              if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                event.preventDefault();
                keyboard.current = shown.length > 0;
                setActive((current) => stepFolderSelection(shown.length, current, event.key === "ArrowDown" ? "down" : "up"));
              } else if (event.key === "Enter" && activeEntry) {
                event.preventDefault();
                void go(activeEntry.path);
              }
            }}
            spellCheck={false}
            autoFocus
            role="combobox"
            aria-label="Folder path"
            aria-autocomplete="list"
            aria-expanded={listing != null}
            aria-controls={listId}
            aria-activedescendant={activeEntry ? `${listId}-folder-${active}` : undefined}
            placeholder="/path/to/project"
            className={`${FIELD} font-mono text-[12.5px]`}
          />
          <button
            type="submit"
            className="h-8 shrink-0 rounded-[8px] bg-hover-2 px-3 text-[12.5px] font-medium text-ink transition-colors hover:bg-line-strong"
          >
            Go
          </button>
        </form>
        <div className="flex flex-wrap items-center gap-1.5 text-[11.5px] text-ink-3">
          <Chip onClick={() => void go("~")} active={sameDir(listing?.path, home)}>
            Home
          </Chip>
          {repo && (
            <Chip onClick={() => void go(repo)} active={sameDir(listing?.path, repo)}>
              {basename(repo)}
            </Chip>
          )}
          <span className="min-w-0 flex-1" />
          <div role="group" aria-label="Sort folders" className="flex items-center gap-1.5">
            <Chip
              active={view.sort === "name"}
              title={sortTitle("name", view)}
              onClick={() => {
                setActive(null);
                setView((current) => cycleFolderSort(current, "name"));
              }}
            >
              Name
            </Chip>
            <Chip
              active={view.sort === "modified"}
              title={sortTitle("modified", view)}
              onClick={() => {
                setActive(null);
                setView((current) => cycleFolderSort(current, "modified"));
              }}
            >
              Modified
            </Chip>
          </div>
          <Chip
            active={view.gitOnly}
            pressed={view.gitOnly}
            title={view.gitOnly ? "Showing git repositories. Click to show every folder." : "Only git repositories"}
            onClick={() => {
              setActive(null);
              setView((current) => ({ ...current, gitOnly: !current.gitOnly }));
            }}
          >
            Git
          </Chip>
        </div>
      </div>

      <div className="flex h-9 shrink-0 items-center gap-1 overflow-x-auto border-b border-line px-3 text-[12px] whitespace-nowrap text-ink-3 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <button type="button" onClick={() => void go("/")} className="rounded px-1 py-0.5 font-medium transition-colors hover:bg-hover hover:text-ink">
          /
        </button>
        {crumbs.map((seg, i) => (
          <span key={crumbPath(i)} className="flex items-center gap-1">
            {i > 0 && <span className="text-line-strong">/</span>}
            <button
              type="button"
              onClick={() => void go(crumbPath(i))}
              className={`rounded px-1 py-0.5 transition-colors hover:bg-hover hover:text-ink ${i === crumbs.length - 1 ? "font-medium text-ink" : ""}`}
            >
              {seg}
            </button>
          </span>
        ))}
        {listing?.git && (
          <span className="ml-1">
            <GitBadge />
          </span>
        )}
      </div>

      <div ref={results} className="min-h-0 flex-1 overflow-y-auto" style={{ minHeight: 200 }}>
        {busy && <p role="status" className="px-4 py-3 text-[12.5px] text-ink-3">Reading folder…</p>}
        {error && <p role="alert" className="px-4 py-3 text-[12.5px] text-red">{error}</p>}
        {!listing && !busy && !error && <p className="px-4 py-3 text-[12.5px] text-ink-3">Press Enter to browse, or open this folder directly.</p>}
        {listing && (
          <div className="flex flex-col px-2 py-1.5">
            {listing.parent && (
              <button
                type="button"
                onClick={() => void go(listing.parent as string)}
                className="flex h-8 items-center gap-2 rounded-[7px] px-2 text-left text-[13px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
              >
                <span className="flex size-4 shrink-0 items-center justify-center">…</span>
                <span>Up one level</span>
              </button>
            )}
            {creating == null ? (
              <button
                type="button"
                disabled={busy}
                onClick={beginCreate}
                className="flex h-8 items-center gap-2 rounded-[7px] px-2 text-left text-[13px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink disabled:opacity-50"
              >
                <span className="flex size-4 shrink-0 items-center justify-center">
                  <IconPlusMedium size={14} />
                </span>
                <span>New folder</span>
              </button>
            ) : (
              <form
                className="flex h-8 items-center gap-2 rounded-[7px] bg-hover px-2"
                onSubmit={(event) => {
                  event.preventDefault();
                  void submitCreate();
                }}
              >
                <span className="flex size-4 shrink-0 items-center justify-center text-ink-3">
                  <IconFolder size={14} />
                </span>
                <input
                  value={creating}
                  onChange={(event) => {
                    setCreating(event.target.value);
                    setError(null);
                  }}
                  onKeyDown={(event) => {
                    if (event.key !== "Escape") return;
                    event.preventDefault();
                    event.stopPropagation();
                    setCreating(null);
                    setError(null);
                  }}
                  onFocus={(event) => event.currentTarget.select()}
                  onBlur={() => {
                    if (!creatingRef.current) {
                      setCreating(null);
                      setError(null);
                    }
                  }}
                  spellCheck={false}
                  autoFocus
                  aria-label="New folder name"
                  className={`${FIELD} h-7 font-mono text-[12.5px]`}
                />
              </form>
            )}
            <div id={listId} role="listbox" aria-label="Matching folders" className="flex flex-col">
              {shown.map((entry, index) => (
                <div
                  key={entry.path}
                  data-folder-index={index}
                  className={`group flex h-8 items-center gap-2 rounded-[7px] px-2 transition-colors duration-100 ${index === active ? "bg-hover" : "hover:bg-hover"}`}
                >
                  <button
                    id={`${listId}-folder-${index}`}
                    type="button"
                    role="option"
                    aria-selected={index === active}
                    onClick={() => void go(entry.path)}
                    title={entry.path}
                    className="flex min-w-0 flex-1 items-center gap-2 text-left"
                  >
                    <span className={`flex size-4 shrink-0 items-center justify-center ${entry.git ? "text-accent-ink" : "text-ink-3"}`}>
                      <IconFolder size={14} />
                    </span>
                    <span className="min-w-0 flex-1 truncate text-[13px] text-ink">{entry.name}</span>
                  </button>
                  {view.sort === "modified" && entry.mtime > 0 && (
                    <span className="shrink-0 font-mono text-[11px] text-ink-3 tabular-nums" title={formatFolderModified(entry.mtime)}>
                      {formatFolderAge(entry.mtime)}
                    </span>
                  )}
                  {entry.git && <GitBadge />}
                  <button
                    type="button"
                    onClick={() => onPick(entry.path)}
                    className="h-6 shrink-0 rounded-[6px] px-1.5 text-[11.5px] font-medium text-ink-3 opacity-0 transition-[opacity,background-color,color] duration-100 group-hover:opacity-100 hover:bg-hover-2 hover:text-ink focus:opacity-100"
                  >
                    Use
                  </button>
                </div>
              ))}
              {shown.length === 0 && creating == null && (
                <p className="px-2 py-2 text-[12.5px] text-ink-3">
                  {parsed.needle ? "No folders match this name." : view.gitOnly ? "No git folders here" : "No folders here"}
                </p>
              )}
            </div>
          </div>
        )}
      </div>

      <div className="flex shrink-0 items-center gap-2 border-t border-line px-4 py-3">
        <span className="min-w-0 flex-1 truncate font-mono text-[11.5px] text-ink-3" title={listing ? displayDirPath(listing.path) : ""}>
          {listing ? displayDirPath(listing.path) : ""}
        </span>
        <button
          type="button"
          onClick={onClose}
          className="h-8 rounded-full px-3 text-[12.5px] font-medium text-ink-2 transition-colors hover:bg-hover hover:text-ink"
        >
          Cancel
        </button>
        <button
          type="button"
          disabled={!typed.trim() || busy}
          onClick={() => void go(typed, { pick: true })}
          className="h-8 rounded-full bg-ink px-3.5 text-[12.5px] font-medium text-canvas transition-opacity hover:opacity-90 disabled:opacity-50"
        >
          Open folder
        </button>
      </div>
    </>
  );
}
