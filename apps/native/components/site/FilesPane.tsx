"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Markdown from "@/components/primitives/Markdown";
import {
  formatSize,
  fsOpen,
  fsRawUrl,
  fsReveal,
  fsStat,
  gitChanges,
  gitFileDiff,
  IMAGE_RE,
  type FsDir,
  type FsFile,
  type GitChanges,
} from "@/lib/fs-client";
import { IconCrossSmall, IconFolder } from "@/lib/icons";

/* ─────────────────────────────────────────────────────────
 * FILES PANE
 * The workspace the agent is working in, made walkable:
 * breadcrumbs, folder listing, and a file viewer (markdown
 * rendered, code in mono) with Open / Reveal passthroughs.
 * ───────────────────────────────────────────────────────── */

const FileGlyph = ({ size = 13 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
    <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
    <path d="M14 2v6h6" />
  </svg>
);

function ActionButton({ label, active = false, onClick }: { label: string; active?: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`flex h-6 items-center rounded-[6px] px-1.5 text-[11.5px] font-medium transition-colors duration-100 hover:bg-hover hover:text-ink ${
        active ? "bg-hover text-ink" : "text-ink-3"
      }`}
    >
      {label}
    </button>
  );
}

const TYPE_LABELS: Record<string, string> = {
  zig: "Zig", ts: "TypeScript", tsx: "TypeScript", js: "JavaScript", jsx: "JavaScript",
  json: "JSON", css: "CSS", html: "HTML", sh: "Shell", zsh: "Shell", py: "Python",
  rs: "Rust", go: "Go", swift: "Swift", yml: "YAML", yaml: "YAML", toml: "TOML",
  txt: "Plain text", lock: "Lockfile", mjs: "JavaScript",
};

/** Code-fence chrome for a whole file: type · lines · size header with
 * Copy and a wrap toggle, and a sticky line-number gutter. */
function TextViewer({ file }: { file: FsFile }) {
  const [wrap, setWrap] = useState(false);
  const [copied, setCopied] = useState(false);
  const copy = useCallback(() => {
    navigator.clipboard.writeText(file.text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }, [file.text]);
  const lines = file.text.split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  const ext = file.path.split(".").pop()?.toLowerCase() ?? "";
  const kind = TYPE_LABELS[ext] ?? (ext ? ext.toUpperCase() : "Plain text");

  return (
    <div className="overflow-hidden rounded-[10px] bg-inset shadow-hairline">
      <div className="flex h-7 items-center justify-between gap-2 border-b border-line px-2.5">
        <span className="min-w-0 truncate font-mono text-[11px] text-ink-3">
          {kind} · {lines.length.toLocaleString()} {lines.length === 1 ? "line" : "lines"} · {formatSize(file.size)}
        </span>
        <span className="flex shrink-0 items-center">
          <ActionButton label="Wrap" active={wrap} onClick={() => setWrap((w) => !w)} />
          <ActionButton label={copied ? "Copied" : "Copy"} onClick={copy} />
        </span>
      </div>
      <div className="flex overflow-x-auto">
        {!wrap && (
          <pre className="sticky left-0 shrink-0 border-r border-line bg-inset py-2.5 pr-2 pl-2.5 text-right font-mono text-[11.5px] leading-[1.65] text-ink-3/60 select-none">
            {lines.map((_, i) => i + 1).join("\n")}
          </pre>
        )}
        <pre
          className={`min-w-0 flex-1 px-3 py-2.5 font-mono text-[11.5px] leading-[1.65] text-ink-2 ${
            wrap ? "whitespace-pre-wrap break-all" : "whitespace-pre"
          }`}
        >
          {file.text}
        </pre>
      </div>
      {file.truncated && (
        <p className="border-t border-line px-2.5 py-1.5 text-[11px] text-ink-3">
          Showing the first 256 KB of {formatSize(file.size)}.
        </p>
      )}
    </div>
  );
}

/** Unified diff, Codex-review colored: adds green, dels red, hunks muted. */
function DiffView({ text }: { text: string }) {
  const lines = text.split("\n");
  return (
    <div className="px-3 py-3">
      <div className="overflow-x-auto rounded-[10px] bg-inset py-2 shadow-hairline">
        {lines.map((line, i) => {
          if (line.startsWith("diff --git") || line.startsWith("index ") || line.startsWith("new file") || line.startsWith("+++") || line.startsWith("---"))
            return null;
          const tone = line.startsWith("@@")
            ? "bg-hover text-ink-3"
            : line.startsWith("+")
              ? "text-green"
              : line.startsWith("-")
                ? "text-red"
                : "text-ink-2";
          return (
            <div key={i} className={`px-3 font-mono text-[11.5px] leading-[1.6] whitespace-pre ${tone}`}>
              {line || " "}
            </div>
          );
        })}
        {!text.trim() && <p className="px-3 text-[12px] text-ink-3">No diff (binary or unchanged).</p>}
      </div>
    </div>
  );
}

export default function FilesPane({
  root,
  requested,
  onClose,
}: {
  /** The workspace to walk (the active tab's cwd); absent, the server default. */
  root?: string;
  /** A path the harness wants shown (e.g. a clicked tool chip), or the
   * changes review when `changes` is set. */
  requested?: { path: string; n: number; changes?: boolean } | null;
  onClose: () => void;
}) {
  const navigation = useRef(0);
  const [dir, setDir] = useState<FsDir | null>(null);
  const [file, setFile] = useState<FsFile | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [view, setView] = useState<"files" | "changes">("files");
  const [changes, setChanges] = useState<GitChanges | null>(null);
  const [diff, setDiff] = useState<{ path: string; text: string } | null>(null);

  const loadChanges = useCallback(async () => {
    try {
      setChanges(await gitChanges(root));
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [root]);

  const openChangesView = useCallback(() => {
    setView("changes");
    setDiff(null);
    void loadChanges();
  }, [loadChanges]);

  const show = useCallback(async (path: string, keepView = false) => {
    const request = ++navigation.current;
    try {
      const res = await fsStat(path, root);
      if (request !== navigation.current) return;
      setError(null);
      if (!keepView) {
        setView("files");
        setDiff(null);
      }
      if (res.dir) {
        setDir(res);
        setFile(null);
      } else {
        setFile(res);
      }
    } catch (err) {
      if (request === navigation.current) setError(err instanceof Error ? err.message : String(err));
    }
  }, [root]);

  useEffect(() => {
    // Preload the root listing without stealing the view — a Review click
    // can land before this resolves, and changes must win that race. A
    // workspace switch re-runs this (new `show`) and lands on its root.
    setFile(null);
    void show("", true);
    return () => { navigation.current++; };
  }, [show]);

  useEffect(() => {
    if (!requested) return;
    if (requested.changes) openChangesView();
    else void show(requested.path);
  }, [requested, show, openChangesView]);

  const openFileDiff = useCallback(async (path: string) => {
    try {
      setDiff({ path, text: await gitFileDiff(path, root) });
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [root]);

  const here = file ? file.path : (dir?.path ?? "");
  const crumbs = here ? here.split("/") : [];
  const rootName = dir?.root.split("/").pop() ?? file?.root.split("/").pop() ?? "workspace";
  const isMarkdown = file && /\.(md|mdx|markdown)$/i.test(file.path);
  const isImage = file && IMAGE_RE.test(file.path);

  return (
    <aside
      className="flex w-[400px] max-w-[55%] shrink-0 flex-col overflow-hidden rounded-[14px] border border-line bg-page"
      style={{ animation: "fade-in 300ms ease both" }}
    >
      {/* header: workspace root + close */}
      <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-3">
        <span className="flex size-5 items-center justify-center text-ink-2">
          <IconFolder size={16} />
        </span>
        <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-ink" title={dir?.root ?? file?.root}>
          {rootName}
        </span>
        <button
          type="button"
          aria-pressed={view === "changes"}
          onClick={() => (view === "changes" ? (setView("files"), setDiff(null)) : openChangesView())}
          className={`flex h-6 items-center gap-1 rounded-[6px] px-1.5 text-[11.5px] font-medium transition-colors duration-100 hover:bg-hover hover:text-ink ${
            view === "changes" ? "bg-hover text-ink" : "text-ink-3"
          }`}
        >
          Changes
          {changes && changes.files.length > 0 && (
            <span className="rounded-full bg-field px-1 font-mono text-[10px] text-ink-2 tabular-nums shadow-hairline">
              {changes.files.length}
            </span>
          )}
        </button>
        <ActionButton label="Reveal" onClick={() => void fsReveal(here, root)} />
        {view === "files" && file && <ActionButton label="Open" onClick={() => void fsOpen(file.path, root)} />}
        <button
          type="button"
          aria-label="Close files"
          onClick={onClose}
          className="flex size-7 items-center justify-center rounded-[6px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
        >
          <IconCrossSmall size={16} />
        </button>
      </div>

      {/* breadcrumbs (files view) / review summary (changes view) */}
      {view === "changes" ? (
        <div className="flex h-9 shrink-0 items-center gap-2 border-b border-line px-3 text-[12px] whitespace-nowrap">
          {diff ? (
            <>
              <button
                type="button"
                onClick={() => setDiff(null)}
                className="rounded px-1 py-0.5 font-medium text-ink-3 transition-colors hover:bg-hover hover:text-ink"
              >
                ‹ Changes
              </button>
              <span className="min-w-0 truncate font-mono text-[11.5px] text-ink">{diff.path}</span>
            </>
          ) : (
            <>
              <span className="font-medium text-ink">Uncommitted changes</span>
              {changes && (
                <span className="font-mono text-[11px] tabular-nums">
                  <span className="text-green">+{changes.totalAdd}</span>{" "}
                  <span className="text-red">−{changes.totalDel}</span>
                </span>
              )}
              <button
                type="button"
                onClick={() => void loadChanges()}
                className="ml-auto rounded px-1 py-0.5 text-[11.5px] font-medium text-ink-3 transition-colors hover:bg-hover hover:text-ink"
              >
                Refresh
              </button>
            </>
          )}
        </div>
      ) : (
      <div className="flex h-9 shrink-0 items-center gap-1 overflow-x-auto border-b border-line px-3 text-[12px] whitespace-nowrap text-ink-3 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <button type="button" onClick={() => void show("")} className="rounded px-1 py-0.5 font-medium transition-colors hover:bg-hover hover:text-ink">
          {rootName}
        </button>
        {crumbs.map((seg, i) => (
          <span key={i} className="flex items-center gap-1">
            <span className="text-line-strong">/</span>
            <button
              type="button"
              onClick={() => void show(crumbs.slice(0, i + 1).join("/"))}
              className={`rounded px-1 py-0.5 transition-colors hover:bg-hover hover:text-ink ${i === crumbs.length - 1 ? "font-medium text-ink" : ""}`}
            >
              {seg}
            </button>
          </span>
        ))}
      </div>
      )}

      <div className="min-h-0 flex-1 overflow-y-auto">
        {error && <p className="px-4 py-3 text-[12.5px] text-red">{error}</p>}

        {/* changes review: per-file diff */}
        {!error && view === "changes" && diff && <DiffView key={diff.path} text={diff.text} />}

        {/* changes review: changed-file list */}
        {!error && view === "changes" && !diff && (
          <div className="flex flex-col px-2 py-1.5">
            {(changes?.files ?? []).map((entry) => (
              <button
                key={entry.path}
                type="button"
                onClick={() => void openFileDiff(entry.path)}
                className="flex h-8 items-center gap-2 rounded-[7px] px-2 text-left transition-colors duration-100 hover:bg-hover"
              >
                <span className="flex size-4 shrink-0 items-center justify-center text-ink-3">
                  <FileGlyph />
                </span>
                <span className="min-w-0 flex-1 truncate font-mono text-[12px] text-ink">{entry.path}</span>
                {entry.untracked && <span className="shrink-0 text-[10px] font-medium text-accent-ink">new</span>}
                <span className="shrink-0 font-mono text-[10.5px] tabular-nums">
                  <span className="text-green">+{entry.add}</span>{" "}
                  {entry.del > 0 && <span className="text-red">−{entry.del}</span>}
                </span>
              </button>
            ))}
            {changes && changes.files.length === 0 && (
              <p className="px-2 py-2 text-[12.5px] text-ink-3">Working tree is clean — nothing to review.</p>
            )}
          </div>
        )}

        {/* file viewer */}
        {!error && view === "files" && file && (
          <div className="px-3 py-3">
            {isImage ? (
              <figure>
                <img
                  src={fsRawUrl(file.path, root)}
                  alt={file.path}
                  className="max-w-full rounded-[10px] bg-inset shadow-hairline"
                  style={{ animation: "fade-in 250ms ease both" }}
                />
                <figcaption className="mt-2 text-[11.5px] text-ink-3">{formatSize(file.size)}</figcaption>
              </figure>
            ) : file.binary ? (
              <p className="text-[12.5px] text-ink-3">
                Binary file · {formatSize(file.size)} — use Open to view it.
              </p>
            ) : isMarkdown ? (
              <>
                <Markdown text={file.text} asDocument onOpenPath={(p) => void show(p)} />
                {file.truncated && (
                  <p className="mt-2 text-[11.5px] text-ink-3">Showing the first 256 KB of {formatSize(file.size)}.</p>
                )}
              </>
            ) : (
              <TextViewer key={file.path} file={file} />
            )}
          </div>
        )}

        {/* folder listing */}
        {!error && view === "files" && !file && dir && (
          <div className="flex flex-col px-2 py-1.5">
            {dir.path && (
              <button
                type="button"
                onClick={() => void show(dir.path.split("/").slice(0, -1).join("/"))}
                className="flex h-8 items-center gap-2 rounded-[7px] px-2 text-left text-[13px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
              >
                <span className="flex size-4 shrink-0 items-center justify-center">…</span>
                <span>Up one level</span>
              </button>
            )}
            {dir.entries.map((entry) => {
              const target = dir.path ? `${dir.path}/${entry.name}` : entry.name;
              return (
                <button
                  key={entry.name}
                  type="button"
                  onClick={() => void show(target)}
                  className="group flex h-8 items-center gap-2 rounded-[7px] px-2 text-left transition-colors duration-100 hover:bg-hover"
                >
                  <span className={`flex size-4 shrink-0 items-center justify-center ${entry.dir ? "text-accent-ink" : "text-ink-3"}`}>
                    {entry.dir ? <IconFolder size={14} /> : <FileGlyph />}
                  </span>
                  <span className="min-w-0 flex-1 truncate text-[13px] text-ink">{entry.name}</span>
                  {!entry.dir && (
                    <span className="shrink-0 font-mono text-[10.5px] text-ink-3 opacity-0 transition-opacity duration-100 group-hover:opacity-100">
                      {formatSize(entry.size)}
                    </span>
                  )}
                </button>
              );
            })}
            {dir.entries.length === 0 && <p className="px-2 py-2 text-[12.5px] text-ink-3">Empty folder</p>}
          </div>
        )}
      </div>
    </aside>
  );
}
