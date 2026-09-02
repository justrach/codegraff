"use client";

import { useEffect, useRef, useState } from "react";
import { IconEditBig, IconMagnifyingGlass } from "@/lib/icons";
import {
  groupSessions,
  listSessionsPage,
  relativeTime,
  type SessionScope,
  type StoredSession,
} from "@/lib/sessions";

const PAGE = 24;
const SCOPES: { key: SessionScope; label: string }[] = [
  { key: "all", label: "All" },
  { key: "local", label: "This workspace" },
  { key: "elsewhere", label: "Saved elsewhere" },
];

function useDebounced(value: string, ms = 180): string {
  const [out, setOut] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setOut(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return out;
}

export default function ConversationsPane({
  activeId,
  onPick,
  onNewChat,
}: {
  activeId?: string | null;
  onPick: (name: string) => void;
  onNewChat?: () => void;
}) {
  const [query, setQuery] = useState("");
  const [scope, setScope] = useState<SessionScope>("all");
  const [rows, setRows] = useState<StoredSession[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const sentinelRef = useRef<HTMLDivElement>(null);
  const q = useDebounced(query);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    void listSessionsPage({ limit: PAGE, q, scope })
      .then((page) => {
        if (cancelled) return;
        setRows(page.sessions);
        setCursor(page.nextCursor);
        setTotal(page.total);
      })
      .catch((err: unknown) => {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [q, scope]);

  useEffect(() => {
    const el = sentinelRef.current;
    if (!el || !cursor) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (!entries.some((e) => e.isIntersecting)) return;
        if (loadingMore || loading) return;
        const next = cursor;
        if (!next) return;
        setLoadingMore(true);
        void listSessionsPage({ limit: PAGE, cursor: next, q, scope })
          .then((page) => {
            setRows((current) => {
              const seen = new Set(current.map((r) => r.name));
              return [...current, ...page.sessions.filter((r) => !seen.has(r.name))];
            });
            setCursor(page.nextCursor);
            setTotal(page.total);
          })
          .catch(() => undefined)
          .finally(() => setLoadingMore(false));
      },
      { rootMargin: "160px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [cursor, loading, loadingMore, q, scope]);

  const groups = groupSessions(rows);
  const empty = !loading && rows.length === 0;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="shrink-0 border-b border-line px-5 pt-5 pb-4 sm:px-8">
        <div className="mx-auto flex w-full max-w-[720px] flex-col gap-4">
          <div className="flex items-end justify-between gap-4">
            <div>
              <h1 className="text-[22px] font-medium tracking-[-0.02em] text-ink">Conversations</h1>
              <p className="mt-0.5 text-[12.5px] text-ink-3">
                {loading && rows.length === 0
                  ? "Reading saved sessions…"
                  : total === 1
                    ? "1 saved session"
                    : `${total.toLocaleString()} saved sessions`}
                {scope === "elsewhere" ? " from other workspaces" : scope === "local" ? " in this workspace" : " · this workspace and home"}
              </p>
            </div>
            {onNewChat && (
              <button
                type="button"
                onClick={onNewChat}
                className="flex h-8 items-center gap-1.5 rounded-control bg-hover-2 px-2.5 text-[12.5px] font-medium text-ink transition-[background-color,transform] duration-150 hover:bg-line-strong active:scale-[0.98]"
              >
                <IconEditBig size={14} />
                New chat
              </button>
            )}
          </div>

          <div className="flex h-9 items-center gap-2 rounded-[10px] bg-field px-2.5 text-ink-3 shadow-hairline focus-within:text-ink-2">
            <IconMagnifyingGlass size={15} />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search title, model, or workspace"
              aria-label="Search conversations"
              className="min-w-0 flex-1 bg-transparent text-[13.5px] font-medium text-ink outline-none placeholder:text-ink-3"
            />
          </div>

          <div className="flex flex-wrap gap-1.5">
            {SCOPES.map((item) => (
              <button
                key={item.key}
                type="button"
                aria-pressed={scope === item.key}
                onClick={() => setScope(item.key)}
                className={`h-7 rounded-full px-2.5 text-[12px] font-medium transition-colors duration-100 ${
                  scope === item.key ? "bg-hover-2 text-ink" : "text-ink-3 hover:bg-hover hover:text-ink"
                }`}
              >
                {item.label}
              </button>
            ))}
          </div>
        </div>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto flex w-full max-w-[720px] flex-col gap-6 px-5 py-5 sm:px-8">
          {error && <p className="text-[13px] text-orange">{error}</p>}
          {empty && (
            <div className="flex flex-col items-center justify-center gap-1 rounded-[14px] bg-inset px-6 py-16 text-center">
              <span className="text-[14px] font-medium text-ink">
                {query.trim() || scope !== "all" ? "No conversations match" : "No saved conversations yet"}
              </span>
              <span className="text-[12.5px] text-ink-3">
                {query.trim() || scope !== "all"
                  ? "Try another search or show all sessions."
                  : "A turn autosaves here. New chat starts a fresh one."}
              </span>
            </div>
          )}
          {groups.map((section) => (
            <section key={section.group}>
              <h2 className="mb-2 px-1 text-[11.5px] font-medium tracking-wide text-ink-3">{section.group}</h2>
              <ul className="flex flex-col gap-1">
                {section.items.map((row) => {
                  const active = row.name === activeId;
                  return (
                    <li key={row.name}>
                      <button
                        type="button"
                        onClick={() => onPick(row.name)}
                        className={`flex w-full items-start gap-3 rounded-[12px] px-3 py-2.5 text-left transition-[background-color,transform] duration-150 active:scale-[0.995] ${
                          active ? "bg-hover-2" : "hover:bg-hover"
                        }`}
                      >
                        <span className="mt-1.5 size-1.5 shrink-0 rounded-full" style={{ background: active ? "var(--accent)" : "var(--ink-3)" }} />
                        <span className="min-w-0 flex-1">
                          <span className={`block truncate text-[14.5px] font-medium ${active ? "text-ink" : "text-ink"}`}>
                            {row.title ?? row.name}
                          </span>
                          <span className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[12px] text-ink-3">
                            {row.model && <span className="font-mono text-[11.5px]">{row.model}</span>}
                            {row.local === false && <span>{row.origin ?? "another workspace"}</span>}
                            {row.local !== false && <span>This workspace</span>}
                          </span>
                        </span>
                        <span className="shrink-0 pt-0.5 text-[12px] tabular-nums text-ink-3">{relativeTime(row.updatedMs)}</span>
                      </button>
                    </li>
                  );
                })}
              </ul>
            </section>
          ))}
          <div ref={sentinelRef} className="h-4" />
          {loadingMore && <p className="pb-4 text-center text-[12.5px] text-ink-3">Loading more…</p>}
          {!loading && !cursor && rows.length > 0 && (
            <p className="pb-6 text-center text-[12px] text-ink-3">
              {rows.length === total ? "That's all of them." : `Showing ${rows.length} of ${total.toLocaleString()}`}
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
