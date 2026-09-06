"use client";

import { parseComposerToken as parseToken, guiSkillRows } from "@/lib/gui-skills";
import { Icon, GLYPHS, SOURCES, DEMO_COMMANDS, MODELS, FILES, DICTATION, AUTO_STEPS } from "./prompt-demo";
import ModelPicker from "./ModelPicker";
import layout from "./PromptBar.module.css";
import ModelEffortButtons from "./ModelEffortButtons";
import type { ModelChoice } from "@/lib/acp-client";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import ComposerMenu from "./ComposerMenu";
import { useComposerSweep } from "./useComposerSweep";
import { useComposerSize } from "./useComposerSize";
import type { AcpCommand } from "@/lib/acp";
import {
  filesFrom,
  releaseAttachments,
  uploadAttachment,
  withAttachmentMarkers,
  type Attachment,
} from "@/lib/attachments";
import { entryAt, historyKeyIntent, stepHistory } from "@/lib/prompt-history";

/* ─────────────────────────────────────────────────────────
 * PROMPT BAR
 * A composer with real controls: attach, @ data sources,
 * / commands, a model picker, dictation, and send.
 * Type @ or / to open the menus; ↑↓ + Enter to pick.
 * Variants: Rounded (card radius) · Pill (full radius).
 * ───────────────────────────────────────────────────────── */

export type PromptModel = ModelChoice;

export default function PromptBar({
  variant = "Rounded",
  demo = true,
  tall = false,
  placeholder,
  onSend, onSetting,
  models,
  commands,
  modelKey,
  onModelChange,
  disabled,
  busy = false,
  onStop,
  history,
  root,
}: {
  variant?: string;
  /** the self-running walkthrough; turn off when embedding in a real surface */
  demo?: boolean;
  /** hero sizing: a multi-line input with controls on their own row */
  tall?: boolean;
  placeholder?: string;
  onSend?: (text: string) => void; onSetting?: (text: string) => Promise<void>;
  models?: PromptModel[];
  /** The slash commands the agent advertised. Empty until it answers —
   * an empty menu beats inventing commands this build may not service. */
  commands?: AcpCommand[];
  modelKey?: string;
  onModelChange?: (key: string) => void;
  disabled?: boolean;
  /** A turn is running: the send arrow morphs into a stop square. */
  busy?: boolean;
  onStop?: () => void;
  /** Earlier prompts, oldest first. ArrowUp on the first line of the draft
   * walks back through them like a shell; ArrowDown walks forward again. */
  history?: readonly string[];
  /** The workspace this composer sends into. The @ picker searches it, and a
   * picked file is mentioned by its path relative to it. */
  root?: string;
}) {
  const pill = variant === "Pill";
  const catalog = models && models.length > 0 ? models : MODELS;
  const [draft, setDraft] = useState("");
  /* Recall cursor: -1 is the live draft. Whatever was being typed is kept
   * aside so ArrowDown past the newest entry hands it back untouched. */
  const [historyIndex, setHistoryIndex] = useState(-1);
  const stashRef = useRef("");
  const caretToEndRef = useRef(false);
  const [dismissed, setDismissed] = useState(false);
  const [plusOpen, setPlusOpen] = useState(false);
  const [modelOpen, setModelOpen] = useState(false);
  const [model, setModel] = useState<PromptModel>(
    () => catalog.find((m) => m.key === modelKey) ?? catalog[0] ?? MODELS[1],
  );
  /* Live surfaces load their catalog async (graff/models); once it lands, or
   * the owner re-points modelKey, the picked entry must follow — the initial
   * useState snapshot is stale by then. */
  useEffect(() => {
    if (!modelKey) return;
    const found = catalog.find((m) => m.key === modelKey);
    if (found && found !== model) setModel(found);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [modelKey, models]);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [uploads, setUploads] = useState(0);
  const [attachError, setAttachError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  /* Workspace files matching the current @ query — live surfaces only. */
  const [fileRows, setFileRows] = useState<{ key: string; name: string; desc: string }[]>([]);
  const [connected, setConnected] = useState(false);
  const [active, setActive] = useState(0);
  const [listening, setListening] = useState(false);
  const [auto, setAuto] = useState(demo);
  const [autoStep, setAutoStep] = useState(0);
  const [expanded, setExpanded] = useState(false);
  const wide = expanded || tall;
  const [engaged, setEngaged] = useState(false);
  const controlsRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const measureRef = useRef<HTMLSpanElement>(null);
  const modelRef = useRef<HTMLButtonElement>(null);
  const menuAnchor = useRef<HTMLDivElement>(null);
  const { glimmRef, celebrate } = useComposerSweep();

  /* hand control to the user: stop the demo loop, and when they aim at
   * the input itself, clear the demo's leftover draft for a clean start */
  const takeOver = (event: { target: EventTarget | null }) => {
    setAuto(false);
    if (auto && event.target === inputRef.current) setDraft("");
  };

  /* ACP names commands bare; the menu shows and inserts the typed form. */
  const slashRows = useMemo(() => {
    const live = commands ?? (demo ? DEMO_COMMANDS : []);
    return live.map((c) => ({ key: c.name, name: `/${c.name}`, desc: c.description }));
  }, [commands, demo]);

  const token = dismissed ? null : parseToken(draft);
  const menu: "at" | "slash" | "skill" | null = plusOpen ? "at" : token?.kind ?? null;
  const query = plusOpen ? "" : token?.query ?? "";

  /* The @ picker searches the workspace. Debounced, and every in-flight
   * search is abandoned when the query moves on, so a slow walk over a large
   * tree can never land on top of results for what is now typed. */
  useEffect(() => {
    if (demo || menu !== "at") return;
    if (!query) {
      setFileRows([]);
      return;
    }
    const abort = new AbortController();
    const timer = setTimeout(() => {
      const params = new URLSearchParams({ q: query });
      if (root) params.set("root", root);
      fetch(`/api/fs?${params}`, { signal: abort.signal })
        .then((res) => res.json())
        .then((json: { matches?: string[] }) => {
          setFileRows(
            (json.matches ?? []).map((rel) => ({
              key: `file:${rel}`,
              name: rel.slice(rel.lastIndexOf("/") + 1),
              desc: rel,
            })),
          );
        })
        .catch(() => {
          /* aborted, or the workspace went away — keep the rows we have */
        });
    }, 90);
    return () => {
      abort.abort();
      clearTimeout(timer);
    };
  }, [demo, menu, query, root]);

  /* The walkthrough glides through a fixed cast of sources. A live composer
   * offers the real attach action and whatever the workspace search found —
   * an invented data source is worse than an empty menu. */
  const atRows = demo
    ? SOURCES.filter((s) => s.name.toLowerCase().includes(query))
    : [...guiSkillRows(query), SOURCES[0], ...fileRows];

  const rows: { key: string; name: string; desc: string }[] =
    menu === "skill" ? guiSkillRows(query) : menu === "at"
      ? atRows
      : menu === "slash"
        ? slashRows.filter((c) => c.name.slice(1).startsWith(query))
        : [];

  useEffect(() => {
    setActive(0);
    setEngaged(false);
  }, [menu, query]);

  const selectModel = (next: PromptModel) => {
    setModel(next);
    setModelOpen(false);
    if (next.key !== model.key) onModelChange?.(next.key);
    if (next.key === "sprinkles-5") celebrate();
  };

  /* autoplay: apply the current step, then advance after its hold */
  useEffect(() => {
    if (!auto) return;
    const step = AUTO_STEPS[autoStep % AUTO_STEPS.length];
    setDraft(step.draft);
    if (step.active !== undefined) setActive(step.active);
    if (step.connect !== undefined) setConnected(step.connect);
    if (step.modelOpen !== undefined) setModelOpen(step.modelOpen);
    if (step.model) {
      const next = MODELS.find((m) => m.key === step.model);
      if (next) selectModel(next);
    }
    const t = setTimeout(() => setAutoStep((s) => s + 1), step.hold);
    return () => clearTimeout(t);
  }, [auto, autoStep]);

  /* The simulated transcript is confined to the component demo. */
  useEffect(() => {
    if (!demo || !listening) return;
    const t = setTimeout(() => {
      setDraft((current) => (current ? `${current.trimEnd()} ${DICTATION}` : DICTATION));
      setListening(false);
      inputRef.current?.focus();
    }, 2200);
    return () => clearTimeout(t);
  }, [demo, listening]);

  useComposerSize({ inputRef, controlsRef, measureRef, modelRef, draft, expanded, setExpanded });

  /* A recalled prompt lands with the caret at its end, ready to edit or send. */
  useLayoutEffect(() => {
    if (!caretToEndRef.current) return;
    caretToEndRef.current = false;
    inputRef.current?.setSelectionRange(draft.length, draft.length);
  }, [draft]);

  /* clicking anywhere outside the composer closes the open menus */
  useEffect(() => {
    if (!plusOpen) return;
    const close = (event: PointerEvent) => {
      if (!(event.target as Element).closest("[data-promptbar]")) {
        setPlusOpen(false);
      }
    };
    document.addEventListener("pointerdown", close);
    return () => document.removeEventListener("pointerdown", close);
  }, [plusOpen]);

  const closeMenus = () => {
    setPlusOpen(false);
    setModelOpen(false);
  };

  const pick = (row: { key: string; name: string; desc: string }) => {
    const before = token ? draft.slice(0, token.start) : draft;
    if (row.key === "attach") {
      if (demo) {
        const name = FILES[attachments.length % FILES.length];
        setAttachments((current) => [...current, { id: `${name}-${current.length}`, name, path: name }]);
      } else {
        fileInputRef.current?.click();
      }
      setDraft(before);
    } else if (row.key.startsWith("gui-skill:")) {
      setDraft(`${before}$${row.key.slice(10)} `);
    } else if (row.key.startsWith("file:")) {
      /* The harness reads `@[path]` out of the prompt text: an image becomes
       * a native vision block, anything else stays a path it opens itself. */
      setDraft(`${before}@[${row.desc}] `);
    } else if (menu === "at") {
      setDraft(`${before}@${row.name} `);
    } else {
      setDraft(`${before}${row.name} `);
    }
    setPlusOpen(false);
    setDismissed(false);
    inputRef.current?.focus();
  };

  const attachFiles = async (files: File[]) => {
    if (demo || files.length === 0) return;
    setAttachError(null); setUploads(count => count + files.length);
    for (const file of files) {
      try {
        const attachment = await uploadAttachment(file);
        setAttachments((current) => [...current, attachment]);
      } catch (err) {
        setAttachError(err instanceof Error ? err.message : String(err));
      } finally { setUploads(count => count - 1); }
    }
    inputRef.current?.focus();
  };

  const removeAttachment = (id: string) => {
    setAttachments((current) => {
      releaseAttachments(current.filter((a) => a.id === id));
      return current.filter((a) => a.id !== id);
    });
  };

  const canSend = !disabled && uploads === 0 && (draft.trim().length > 0 || attachments.length > 0);
  const showStop = busy && !canSend;
  const send = () => {
    if (!canSend) return;
    if (/^\/(effort|reasoning)$/.test(draft.trim()) && model.effortLevels?.length) { modelRef.current?.dispatchEvent(new Event("graff-effort-open")); setDraft(""); return; }
    onSend?.(withAttachmentMarkers(draft.trim(), attachments));
    releaseAttachments(attachments);
    setDraft("");
    setAttachments([]);
    setAttachError(null);
    setHistoryIndex(-1);
    stashRef.current = "";
    closeMenus();
  };

  /* Shell-style recall. Only from the draft's first line (up) or last line
   * (down) — in the middle of a multi-line draft the arrows keep moving the
   * caret — and never while the @ / model menus own the arrow keys. */
  const recall = (event: React.KeyboardEvent<HTMLTextAreaElement>): boolean => {
    if (menu || modelOpen || !history || history.length === 0) return false;
    const caret = event.currentTarget.selectionStart ?? draft.length;
    const intent = historyKeyIntent(draft, caret, event.key);
    if (!intent || (intent === "down" && historyIndex < 0)) return false;
    event.preventDefault();
    const next = stepHistory(history.length, historyIndex, intent);
    if (next === historyIndex) return true;
    if (historyIndex < 0) stashRef.current = draft;
    setHistoryIndex(next);
    setDraft(next < 0 ? stashRef.current : (entryAt(history, next) ?? ""));
    caretToEndRef.current = true;
    return true;
  };

  return (
    <div
      data-promptbar
      className={`${layout.composer} ${demo ? "flex min-h-[384px] w-full max-w-105 flex-col justify-end pb-8" : "w-full"}`}
      onPointerDownCapture={takeOver}
      onKeyDownCapture={takeOver}
    >
      {/* composer is the anchor — menus grow up from its top edge */}
      <div ref={menuAnchor} className="relative">
      {/* ── @ / slash menu ─────────────────────────────── */}
      {menu && <ComposerMenu anchor={menuAnchor} menu={menu} rows={rows} query={query}
        active={active} engaged={engaged} setActive={setActive} setEngaged={setEngaged}
        connected={connected} setConnected={setConnected} demo={demo} onPick={pick} />}


      {modelOpen && <ModelPicker models={catalog} selected={model} anchor={modelRef} onClose={() => setModelOpen(false)}
        onSelect={next => { selectModel(next); inputRef.current?.focus({ preventScroll: true }); }} />}

      {/* ── composer ───────────────────────────────────── */}
      <div
        onDragOver={(event) => {
          /* Claim the drop only for files. Without preventDefault here the
           * browser navigates away to the dropped file instead. */
          if (demo || !event.dataTransfer.types.includes("Files")) return;
          event.preventDefault();
          setDragging(true);
        }}
        onDragLeave={(event) => {
          if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
          setDragging(false);
        }}
        onDrop={(event) => {
          const files = filesFrom(event.dataTransfer);
          if (demo || files.length === 0) return;
          event.preventDefault();
          setDragging(false);
          void attachFiles(files);
        }}
        className={`relative isolate flex flex-col overflow-hidden border bg-surface shadow-card transition-[border-color,border-radius] duration-150 focus-within:border-line-strong ${
          dragging ? "border-accent-ink" : "border-line"
        } ${
          tall ? "gap-2.5 p-3.5" : "gap-1.5 p-1.5"
        } ${
          pill ? (attachments.length > 0 || wide ? "rounded-[24px]" : "rounded-full") : tall ? "rounded-[22px]" : "rounded-[14px]"
        }`}
      >
        <input
          ref={fileInputRef}
          type="file"
          multiple
          hidden
          onChange={(event) => {
            void attachFiles(Array.from(event.target.files ?? []));
            // Same file twice in a row is a real thing to want; without this
            // the second pick fires no change event at all.
            event.target.value = "";
          }}
        />
        {/* rainbow glimm sweep — plays across the interior on model change.
            explicit w/h: a <canvas> is a replaced element and won't stretch
            to inset-0 alone, which feeds back into the shader's ResizeObserver. */}
        <canvas
          ref={glimmRef}
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 -z-10 h-full w-full"
          style={{ borderRadius: "inherit" }}
        />
        <span
          ref={measureRef}
          aria-hidden="true"
          className="pointer-events-none absolute invisible whitespace-pre text-[13px] leading-[18px]"
        >
          {draft}
        </span>

        {attachments.length > 0 && (
          <div className={`flex flex-wrap gap-1.5 pt-0.5 ${pill ? "px-1" : "px-0.5"}`}>
            {attachments.map((file) => (
              <span
                key={file.id}
                className={`flex h-6.5 items-center gap-1.5 bg-field py-1 pr-1 pl-1.5 text-[11.5px] text-ink-2 shadow-hairline ${
                  pill ? "rounded-full" : "rounded-chip"
                }`}
                style={{ animation: "pop-in 200ms cubic-bezier(0.23,1,0.32,1) both" }}
              >
                {file.preview ? (
                  /* eslint-disable-next-line @next/next/no-img-element */
                  <img src={file.preview} alt="" className="-my-1 size-6 rounded-[4px] object-cover" />
                ) : (
                  <Icon size={12}>{GLYPHS.file}</Icon>
                )}
                <span className="max-w-36 truncate">{file.name}</span>
                <button
                  type="button"
                  aria-label={`Remove ${file.name}`}
                  onClick={() => removeAttachment(file.id)}
                  className={`-my-1 flex size-6 items-center justify-center text-ink-3 transition-colors duration-100 hover:bg-line/70 hover:text-ink ${
                    pill ? "rounded-full" : "rounded-[5px]"
                  }`}
                >
                  <Icon size={10} strokeWidth={2.5}><path d="M18 6L6 18M6 6l12 12" /></Icon>
                </button>
              </span>
            ))}
          </div>
        )}

        {uploads > 0 && <p role="status" className="px-2 text-xs text-ink-3">Adding {uploads} {uploads === 1 ? "file" : "files"}…</p>}
        {attachError && (
          <div className={`text-[11.5px] text-red ${pill ? "px-2" : "px-1"}`} role="status">
            {attachError}
          </div>
        )}

        <div
          ref={controlsRef}
          className={`${layout.controls} grid items-end gap-x-1 gap-y-1.5 ${
            wide
              ? "grid-cols-[28px_minmax(0,1fr)_0px_28px_28px]"
              : "grid-cols-[28px_minmax(0,1fr)_auto_28px_28px]"
          }`}
        >
          <button
            type="button"
            aria-label="Add attachments and sources"
            aria-expanded={plusOpen}
            onClick={() => {
              setModelOpen(false);
              setPlusOpen((current) => !current);
              inputRef.current?.focus();
            }}
            className={`flex size-7 shrink-0 items-center justify-center justify-self-start text-ink-3 transition-[background-color,color,transform] duration-150 hover:bg-hover hover:text-ink active:scale-[0.94] ${
              pill ? "rounded-full" : "rounded-[8px]"
            } ${plusOpen ? "bg-hover text-ink" : ""} ${wide ? "col-start-1 row-start-2" : "col-start-1 row-start-1"}`}
          >
            <Icon size={16} strokeWidth={2}><path d="M12 5v14M5 12h14" /></Icon>
          </button>

          <textarea
            ref={inputRef}
            rows={1}
            value={draft}
            onChange={(event) => {
              setDraft(event.target.value);
              setDismissed(false);
              setPlusOpen(false);
            }}
            onPaste={(event) => {
              /* Claim the paste only when it carries files. A text paste has
               * to fall through untouched — that is Cmd-V doing its job. */
              const files = filesFrom(event.clipboardData);
              if (demo || files.length === 0) return;
              event.preventDefault();
              void attachFiles(files);
            }}
            onKeyDown={(event) => {
              if (menu && rows.length > 0) {
                if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                  event.preventDefault();
                  setEngaged(true);
                  setActive((current) => (current + (event.key === "ArrowDown" ? 1 : rows.length - 1)) % rows.length);
                  return;
                }
                if ((event.key === "Enter" && !event.shiftKey) || event.key === "Tab") {
                  event.preventDefault();
                  pick(rows[active]);
                  return;
                }
              }
              if (recall(event)) return;
              if (event.key === "Escape") {
                setDismissed(true);
                closeMenus();
                return;
              }
              if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                send();
              }
            }}
            placeholder={listening ? "Listening…" : placeholder ?? "Write a message…"}
            aria-label="Prompt"
            className={`${tall ? "min-h-[68px] px-2 py-2 text-[14px] leading-5" : "min-h-7 px-1 py-[5px] text-[13px] leading-[18px]"} min-w-0 w-full resize-none bg-transparent text-ink outline-none [overflow-wrap:anywhere] placeholder:text-ink-3 ${
              wide ? "col-span-full col-start-1 row-start-1" : "col-start-2 row-start-1"
            }`}
          />

          <ModelEffortButtons model={model} buttonRef={modelRef} modelOpen={modelOpen} wide={wide} pill={pill} busy={busy}
            onCommand={onSetting} openModel={() => { setPlusOpen(false); setModelOpen(current => !current); }} />

          {/* dictation */}
          <button
            type="button"
            aria-label={listening ? "Stop dictation" : "Start dictation"}
            aria-pressed={listening} disabled={!demo} title={demo ? "Demo dictation" : "Dictation is not available yet"}
            onClick={() => setListening((current) => !current)}
            className={`flex size-7 shrink-0 items-center justify-center disabled:opacity-30 disabled:cursor-not-allowed transition-[background-color,color,transform] duration-150 active:scale-[0.94] ${
              pill ? "rounded-full" : "rounded-[8px]"
            } ${listening ? "bg-accent-tint text-accent-ink" : "text-ink-3 hover:bg-hover hover:text-ink"} ${wide ? "col-start-4 row-start-2" : "col-start-4 row-start-1"}`}
          >
            {listening ? (
              <span className="flex h-3.5 items-center gap-[2.5px]">
                {[0, 1, 2].map((i) => (
                  <span
                    key={i}
                    className="w-[2.5px] rounded-full bg-current"
                    style={{ height: "100%", animation: `eq-bounce 900ms ease-in-out ${i * 150}ms infinite` }}
                  />
                ))}
              </span>
            ) : (
              <Icon size={15} strokeWidth={2}><g><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z" /><path d="M19 10v2a7 7 0 0 1-14 0v-2M12 19v3" /></g></Icon>
            )}
          </button>

          {/* send — tactile square (round in the pill variant); while a turn
              runs it morphs into the Codex-style stop control */}
          <button
            type="button"
            aria-label={showStop ? "Stop" : "Send"}
            disabled={showStop ? !onStop : !canSend}
            onClick={showStop ? onStop : send}
            className={`flex size-7 shrink-0 items-center justify-center disabled:opacity-30 disabled:cursor-not-allowed transition-[background-color,color,transform] duration-200 enabled:active:scale-[0.94] ${
              pill ? "rounded-full" : "rounded-[8px]"
            } ${wide ? "col-start-5 row-start-2" : "col-start-5 row-start-1"}`}
            style={{
              background: showStop || canSend ? "var(--ink)" : "var(--line-strong)",
              color: showStop || canSend ? "var(--surface)" : "var(--ink-2)",
            }}
          >
            {showStop ? (
              <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                <rect x="5" y="5" width="14" height="14" rx="2.5" />
              </svg>
            ) : (
              <Icon size={16} strokeWidth={2.4}><path d="M12 19V5M5 12l7-7 7 7" /></Icon>
            )}
          </button>
        </div>
      </div>
      </div>
    </div>
  );
}
