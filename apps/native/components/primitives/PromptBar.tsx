"use client";

import ModelEffortButtons from "./ModelEffortButtons";
import type { ModelChoice } from "@/lib/acp-client";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createShader, playSweep, accentChain, ACCENTS } from "glimm";
import type { AcpCommand } from "@/lib/acp";
import {
  filesFrom,
  releaseAttachments,
  uploadAttachment,
  withAttachmentMarkers,
  type Attachment,
} from "@/lib/attachments";
import { entryAt, historyKeyIntent, stepHistory } from "@/lib/prompt-history";

/* The built-in "prism" palette is only cyan→indigo→magenta, so a sweep
 * reads as blue/purple. Build a true full-spectrum rainbow instead. */
const RAINBOW = accentChain([
  ACCENTS.red,
  ACCENTS.orange,
  ACCENTS.yellow,
  ACCENTS.green,
  ACCENTS.cyan,
  ACCENTS.blue,
  ACCENTS.purple,
]);

/* ─────────────────────────────────────────────────────────
 * PROMPT BAR
 * A composer with real controls: attach, @ data sources,
 * / commands, a model picker, dictation, and send.
 * Type @ or / to open the menus; ↑↓ + Enter to pick.
 * Variants: Rounded (card radius) · Pill (full radius).
 * ───────────────────────────────────────────────────────── */

function Icon({ children, size = 15, strokeWidth = 1.8 }: { children: React.ReactNode; size?: number; strokeWidth?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

const GLYPHS: Record<string, React.ReactNode> = {
  clip: <path d="m21.4 11.05-9.19 9.19a6 6 0 0 1-8.49-8.49l8.57-8.57A4 4 0 1 1 18 8.84l-8.59 8.57a2 2 0 0 1-2.83-2.83l8.49-8.48" />,
  chart: <path d="M4 20V10M10 20V4M16 20v-7M22 20H2" />,
  layers: <g><path d="M12 2 2 7l10 5 10-5-10-5z" /><path d="M2 17l10 5 10-5M2 12l10 5 10-5" /></g>,
  globe: <g><circle cx="12" cy="12" r="10" /><path d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" /></g>,
  file: <g><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><path d="M14 2v6h6" /></g>,
};

/* real product marks, inline so the file stays self-contained */
const BRANDS: Record<string, React.ReactNode> = {
  figma: (
    <svg width="11" height="16" viewBox="0 0 38 57" aria-hidden="true">
      <path d="M9.5 57A9.5 9.5 0 0 0 19 47.5V38H9.5a9.5 9.5 0 0 0 0 19z" fill="#0ACF83" />
      <path d="M0 28.5A9.5 9.5 0 0 1 9.5 19H19v19H9.5A9.5 9.5 0 0 1 0 28.5z" fill="#A259FF" />
      <path d="M0 9.5A9.5 9.5 0 0 1 9.5 0H19v19H9.5A9.5 9.5 0 0 1 0 9.5z" fill="#F24E1E" />
      <path d="M19 0h9.5a9.5 9.5 0 1 1 0 19H19V0z" fill="#FF7262" />
      <path d="M38 28.5a9.5 9.5 0 1 1-19 0 9.5 9.5 0 0 1 19 0z" fill="#1ABCFE" />
    </svg>
  ),
  slack: (
    <svg width="15" height="15" viewBox="0 0 127 127" aria-hidden="true">
      <path d="M27.2 80c0 7.3-5.9 13.2-13.2 13.2C6.7 93.2.8 87.3.8 80c0-7.3 5.9-13.2 13.2-13.2h13.2V80zm6.6 0c0-7.3 5.9-13.2 13.2-13.2 7.3 0 13.2 5.9 13.2 13.2v33c0 7.3-5.9 13.2-13.2 13.2-7.3 0-13.2-5.9-13.2-13.2V80z" fill="#E01E5A" />
      <path d="M47 27.2c-7.3 0-13.2-5.9-13.2-13.2C33.8 6.7 39.7.8 47 .8c7.3 0 13.2 5.9 13.2 13.2v13.2H47zm0 6.7c7.3 0 13.2 5.9 13.2 13.2 0 7.3-5.9 13.2-13.2 13.2H13.9C6.6 60.3.7 54.4.7 47.1c0-7.3 5.9-13.2 13.2-13.2H47z" fill="#36C5F0" />
      <path d="M99.9 47.1c0-7.3 5.9-13.2 13.2-13.2 7.3 0 13.2 5.9 13.2 13.2 0 7.3-5.9 13.2-13.2 13.2H99.9V47.1zm-6.6 0c0 7.3-5.9 13.2-13.2 13.2-7.3 0-13.2-5.9-13.2-13.2V13.9C66.9 6.6 72.8.7 80.1.7c7.3 0 13.2 5.9 13.2 13.2v33.2z" fill="#2EB67D" />
      <path d="M80.1 99.8c7.3 0 13.2 5.9 13.2 13.2 0 7.3-5.9 13.2-13.2 13.2-7.3 0-13.2-5.9-13.2-13.2V99.8h13.2zm0-6.6c-7.3 0-13.2-5.9-13.2-13.2 0-7.3 5.9-13.2 13.2-13.2h33.1c7.3 0 13.2 5.9 13.2 13.2 0 7.3-5.9 13.2-13.2 13.2H80.1z" fill="#ECB22E" />
    </svg>
  ),
  gmail: (
    <svg width="15" height="12" viewBox="0 0 256 193" aria-hidden="true">
      <path d="M58.182 192.05V93.14L27.507 65.077 0 49.504v125.091c0 9.658 7.825 17.455 17.455 17.455h40.727Z" fill="#4285F4" />
      <path d="M197.818 192.05h40.727c9.659 0 17.455-7.826 17.455-17.455V49.505l-31.156 17.837-27.026 25.798v98.91Z" fill="#34A853" />
      <path d="m58.182 93.14-4.174-38.647 4.174-36.989L128 69.868l69.818-52.364 4.669 34.992-4.669 40.644L128 145.504 58.182 93.14Z" fill="#EA4335" />
      <path d="M197.818 17.504V93.14L256 49.504V26.231c0-21.585-24.64-33.89-41.89-20.945l-16.292 12.218Z" fill="#FBBC04" />
      <path d="m0 49.504 26.759 20.07L58.182 93.14V17.504L41.89 5.286C24.61-7.66 0 4.646 0 26.23v23.273Z" fill="#C5221F" />
    </svg>
  ),
};

type Source = {
  key: string;
  name: string;
  desc: string;
  glyph?: string;
  brand?: string;
  attach?: boolean;
  connect?: boolean;
};

const SOURCES: Source[] = [
  { key: "attach", name: "Add photos & files", desc: "Upload from your computer", glyph: "clip", attach: true },
  { key: "scoop", name: "Scoop Data", desc: "Sales & churn metrics", glyph: "chart" },
  { key: "flavors", name: "Flavor records", desc: "26 makers, tags, links", glyph: "layers" },
  { key: "web", name: "Web search", desc: "Real-time news and info", glyph: "globe" },
  { key: "figma", name: "Figma", desc: "Design-to-code workflows", brand: "figma" },
  { key: "slack", name: "Slack", desc: "Read and manage Slack", brand: "slack" },
  { key: "gmail", name: "Gmail", desc: "Read and manage Gmail", brand: "gmail", connect: true },
];

/* The self-running walkthrough types "/" and glides through rows, so it
 * needs something to show. A live surface is handed the agent's real set and
 * never falls back to these — an invented command must not reach a console
 * where someone could run it. */
const DEMO_COMMANDS: AcpCommand[] = [
  { name: "compare", description: "Flavor vs. last summer" },
  { name: "churn-plan", description: "Draft a churn schedule" },
  { name: "restock", description: "Build a reorder list" },
  { name: "draft-email", description: "Write a supplier email" },
  { name: "summarize", description: "Digest the thread so far" },
];

const MODELS = [
  { key: "sprinkles-5", name: "Sprinkles 5", tag: "Flagship" },
  { key: "vanilla-1", name: "Vanilla 1", tag: "Basic" },
  { key: "freezer-burn", name: "Freezer Burn 0.4", tag: "Stale" },
];

const FILES = ["flavor-chart.png", "summer-menu.pdf", "pos-export.csv"];
const DICTATION = "Compare pistachio weekends to last summer";

/* self-running demo: walk the @ menu, then the / menu, and repeat.
 * Any pointer or key interaction hands control to the user. */
const AUTO_STEPS: {
  draft: string;
  active?: number;
  connect?: boolean;
  modelOpen?: boolean;
  model?: string;
  hold: number;
}[] = [
  { draft: "", connect: false, model: "vanilla-1", hold: 1100 },
  { draft: "@", active: 0, hold: 900 },
  { draft: "@", active: 1, hold: 620 },
  { draft: "@", active: 4, hold: 620 },
  { draft: "@", active: 6, hold: 700 },
  { draft: "@", active: 6, connect: true, hold: 1000 },
  { draft: "", hold: 700 },
  { draft: "/", active: 0, hold: 900 },
  { draft: "/", active: 1, hold: 620 },
  { draft: "/", active: 3, hold: 1000 },
  { draft: "", hold: 800 },
  // open the model picker and upgrade to the flagship → rainbow sweep
  { draft: "", modelOpen: true, hold: 1200 },
  { draft: "", model: "sprinkles-5", hold: 2400 },
  { draft: "", hold: 900 },
];

/* The last @word or /word being typed, if any. An @ query may carry path
 * separators and dots, because narrowing by directory is how anyone finds a
 * file in a large tree; a slash command never contains either. */
function parseToken(draft: string): { kind: "at" | "slash"; query: string; start: number } | null {
  const match = /(^|\s)(?:@([\w./-]*)|\/([\w-]*))$/.exec(draft);
  if (!match) return null;
  const at = match[2] !== undefined;
  return {
    kind: at ? "at" : "slash",
    query: (at ? match[2] : match[3]).toLowerCase(),
    start: match.index + match[1].length,
  };
}

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
  const [rowBox, setRowBox] = useState<{ top: number; height: number } | null>(null);
  const [engaged, setEngaged] = useState(false);
  const [modelBox, setModelBox] = useState<{ top: number; height: number } | null>(null);
  const [modelHovered, setModelHovered] = useState<number | null>(null);
  const [modelQuery, setModelQuery] = useState("");
  const [modelMenuLeft, setModelMenuLeft] = useState(0);
  const [modelMenuBottom, setModelMenuBottom] = useState(0);
  const [modelMenuMaxH, setModelMenuMaxH] = useState(560);
  const composerAnchorRef = useRef<HTMLDivElement>(null);
  const controlsRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const measureRef = useRef<HTMLSpanElement>(null);
  const modelRef = useRef<HTMLButtonElement>(null);
  const rowRefs = useRef<(HTMLButtonElement | null)[]>([]);
  const modelRowRefs = useRef<(HTMLButtonElement | null)[]>([]);
  const glimmRef = useRef<HTMLCanvasElement>(null);
  const shaderRef = useRef<ReturnType<typeof createShader> | null>(null);
  const sweepingRef = useRef(false);

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
  const menu: "at" | "slash" | null = plusOpen ? "at" : token?.kind ?? null;
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
    : [SOURCES[0], ...fileRows];

  const rows: { key: string; name: string; desc: string }[] =
    menu === "at"
      ? atRows
      : menu === "slash"
        ? slashRows.filter((c) => c.name.slice(1).startsWith(query))
        : [];

  useEffect(() => {
    setActive(0);
    setEngaged(false);
  }, [menu, query]);

  /* a single highlight glides to the active row instead of each row
   * toggling its own background — matches the gliding pill in the nav */
  useLayoutEffect(() => {
    const target = rowRefs.current[active];
    if (target) setRowBox({ top: target.offsetTop, height: target.offsetHeight });
  }, [menu, query, active, connected, rows.length]);

  /* same gliding highlight in the model menu — floats to the hovered
   * row, falling back to the currently-selected model */
  const modelFilter = modelQuery.trim().toLowerCase();
  const shownModels = modelFilter
    ? catalog.filter(
        (m) => m.name.toLowerCase().includes(modelFilter) || (m.tag ?? "").toLowerCase().includes(modelFilter),
      )
    : catalog;
  const modelIndex = shownModels.findIndex((m) => m.key === model.key);
  useLayoutEffect(() => {
    if (!modelOpen) return;
    const target = modelRowRefs.current[modelHovered ?? modelIndex];
    if (target) {
      setModelBox({ top: target.offsetTop, height: target.offsetHeight });
      /* 40+ authenticated models: opening far from the current selection
       * hid it off-screen — bring it into view, but never fight the mouse */
      if (modelHovered === null) target.scrollIntoView({ block: "nearest" });
    }
  }, [modelOpen, modelHovered, modelIndex, modelFilter]);

  /* The menu is outside the clipped composer, so align it to the model
   * trigger by measurement instead of pinning it to the far-right edge. */
  useLayoutEffect(() => {
    if (!modelOpen || !composerAnchorRef.current || !modelRef.current) return;
    const anchorRect = composerAnchorRef.current.getBoundingClientRect();
    const triggerRect = modelRef.current.getBoundingClientRect();
    setModelMenuLeft(Math.max(0, Math.min(triggerRect.left - anchorRect.left, anchorRect.width - 176)));
    setModelMenuBottom(anchorRect.bottom - triggerRect.top + 8);
    // The menu grows upward from the trigger; without this cap a 40-model
    // list runs past the viewport top and clips its own filter input.
    setModelMenuMaxH(Math.max(220, Math.min(560, triggerRect.top - 20)));
  }, [modelOpen, wide, model.name]);

  useEffect(() => {
    if (!modelOpen) {
      setModelHovered(null);
      setModelQuery("");
    }
  }, [modelOpen]);

  /* Build the shader with a pinned hue phase. createShader seeds its
   * internal hueShift from Math.random(), which made the sweep a different
   * colour on every reload — pin it so the rainbow is identical each time. */
  const makeShader = () => {
    const canvas = glimmRef.current;
    if (!canvas) return null;
    const random = Math.random;
    Math.random = () => 0;
    try {
      return createShader({
        canvas,
        palette: RAINBOW,
        direction: "ltr",
        bandTight: 10,
        swellAmount: 0.85,
      });
    } finally {
      Math.random = random;
    }
  };

  /* Glimm shader lives inside the composer, invisible at rest. Selecting
   * the flagship model fires a one-shot rainbow sweep across the interior. */
  useEffect(() => {
    shaderRef.current = makeShader();
    return () => {
      shaderRef.current?.destroy();
      shaderRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const celebrate = () => {
    if (sweepingRef.current) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    // Recreate the shader per sweep so uTime restarts at 0 — the hue phase
    // (which drifts with time) is then identical on every trigger.
    shaderRef.current?.destroy();
    const shader = makeShader();
    shaderRef.current = shader;
    if (!shader) return;
    sweepingRef.current = true;
    const sweep = playSweep(shader, {
      palette: RAINBOW,
      direction: "ltr",
      sweepMs: 570,
      outroMs: 80,
      peakAlpha: 1.3,
      bandTight: 10,
      brightness: 1.4,
      swellAmount: 1,
      waveSpeed: 1.8,
      easing: "easeOutExpo",
    });
    sweep.done.finally(() => {
      sweepingRef.current = false;
    });
  };

  const selectModel = (next: PromptModel) => {
    setModel(next);
    setModelOpen(false);
    onModelChange?.(next.key);
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

  /* dictation resolves after a beat, like a real transcript landing */
  useEffect(() => {
    if (!listening) return;
    const t = setTimeout(() => {
      setDraft((current) => (current ? `${current.trimEnd()} ${DICTATION}` : DICTATION));
      setListening(false);
      inputRef.current?.focus();
    }, 2200);
    return () => clearTimeout(t);
  }, [listening]);

  /* Move wrapped text above the controls, then grow to a compact maximum. */
  useLayoutEffect(() => {
    const input = inputRef.current;
    const controls = controlsRef.current;
    const measure = measureRef.current;
    const modelButton = modelRef.current;
    if (!input || !controls || !measure || !modelButton) return;

    const fixedControlsWidth = 28 * 3 + modelButton.offsetWidth;
    const inlineGaps = 4 * 4;
    const inlineInputWidth = controls.clientWidth - fixedControlsWidth - inlineGaps;
    const needsFullWidth = draft.includes("\n") || measure.offsetWidth + 8 > inlineInputWidth;
    if (needsFullWidth !== expanded) {
      setExpanded(needsFullWidth);
    }

    const minHeight = 28;
    const maxHeight = 100;
    input.style.height = "0px";
    const contentHeight = input.scrollHeight;
    input.style.height = `${Math.min(Math.max(contentHeight, minHeight), maxHeight)}px`;
    input.style.overflowY = contentHeight > maxHeight ? "auto" : "hidden";
  }, [draft, expanded]);

  /* A recalled prompt lands with the caret at its end, ready to edit or send. */
  useLayoutEffect(() => {
    if (!caretToEndRef.current) return;
    caretToEndRef.current = false;
    inputRef.current?.setSelectionRange(draft.length, draft.length);
  }, [draft]);

  /* clicking anywhere outside the composer closes the open menus */
  useEffect(() => {
    if (!modelOpen && !plusOpen) return;
    const close = (event: PointerEvent) => {
      if (!(event.target as Element).closest("[data-promptbar]")) {
        setModelOpen(false);
        setPlusOpen(false);
      }
    };
    document.addEventListener("pointerdown", close);
    return () => document.removeEventListener("pointerdown", close);
  }, [modelOpen, plusOpen]);

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

  /* Bytes from a paste, a drop or the file picker. Uploaded one at a time so
   * one refusal cannot take the others down with it. */
  const attachFiles = async (files: File[]) => {
    if (demo || files.length === 0) return;
    setAttachError(null);
    for (const file of files) {
      try {
        const attachment = await uploadAttachment(file);
        setAttachments((current) => [...current, attachment]);
      } catch (err) {
        setAttachError(err instanceof Error ? err.message : String(err));
      }
    }
    inputRef.current?.focus();
  };

  const removeAttachment = (id: string) => {
    setAttachments((current) => {
      releaseAttachments(current.filter((a) => a.id === id));
      return current.filter((a) => a.id !== id);
    });
  };

  const canSend = !disabled && (draft.trim().length > 0 || attachments.length > 0);
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
      className={demo ? "flex min-h-[384px] w-full max-w-105 flex-col justify-end pb-8" : "w-full"}
      onPointerDownCapture={takeOver}
      onKeyDownCapture={takeOver}
    >
      {/* composer is the anchor — menus grow up from its top edge */}
      <div ref={composerAnchorRef} className="relative">
      {/* ── @ / slash menu ─────────────────────────────── */}
      {menu && (
        <div
          onMouseLeave={() => setEngaged(false)}
          className="absolute inset-x-0 bottom-full z-10 mb-2 rounded-[10px] bg-surface p-1 shadow-raised"
          style={{ animation: "pop-in 180ms cubic-bezier(0.23,1,0.32,1) both", transformOrigin: "bottom center" }}
        >
          {/* single gliding highlight — appears once a row is hovered */}
          <span
            aria-hidden
            className="pointer-events-none absolute inset-x-1 rounded-[6px] bg-hover"
            style={{
              top: rowBox?.top ?? 0,
              height: rowBox?.height ?? 0,
              opacity: rowBox && engaged && rows.length > 0 ? 1 : 0,
              transition:
                "top 220ms cubic-bezier(0.23,1,0.32,1), height 220ms cubic-bezier(0.23,1,0.32,1), opacity 150ms ease",
            }}
          />
          {rows.map((row, i) => {
            const source = menu === "at" ? SOURCES.find((s) => s.key === row.key) : undefined;
            const mark = source ? (
              source.brand ? BRANDS[source.brand] : <Icon size={15}>{GLYPHS[source.glyph ?? "clip"]}</Icon>
            ) : row.key.startsWith("file:") ? (
              <Icon size={15}>{GLYPHS.file}</Icon>
            ) : null;
            return (
              <button
                key={row.key}
                type="button"
                ref={(el) => {
                  rowRefs.current[i] = el;
                }}
                onMouseDown={(event) => event.preventDefault()}
                onMouseEnter={() => {
                  setActive(i);
                  setEngaged(true);
                }}
                onClick={() => pick(row)}
                className="relative z-10 flex h-9 w-full items-center gap-2.5 rounded-[6px] px-2 text-left"
              >
                {mark && (
                  <span className="flex size-5.5 shrink-0 items-center justify-center text-ink-2">{mark}</span>
                )}
                <span className="shrink-0 text-[12.5px] font-medium text-ink">
                  {row.name}
                </span>
                <span className="min-w-0 flex-1 truncate text-[12px] text-ink-3">{row.desc}</span>
                {source?.connect && (
                  <span
                    role="button"
                    tabIndex={-1}
                    onClick={(event) => {
                      event.stopPropagation();
                      setConnected((current) => !current);
                    }}
                    className={`shrink-0 text-[12px] font-medium transition-colors duration-100 ${
                      connected ? "text-green" : "text-accent-ink hover:underline"
                    }`}
                  >
                    {connected ? "Connected" : "Connect"}
                  </span>
                )}
              </button>
            );
          })}
          {rows.length === 0 && (
            <div className="flex h-9 items-center px-2 text-[12px] text-ink-3">
              No matches for “{query}”
            </div>
          )}
          <div className="mt-1 border-t border-line px-2 pt-1.5 pb-1 text-[11px] text-ink-3">
            {menu !== "at"
              ? "Type to search commands"
              : demo
                ? "Type to search sources & files"
                : "Type to search this workspace — or paste, drop and attach files"}
          </div>
        </div>
      )}

      {/* ── model menu ─────────────────────────────────── */}
      {modelOpen && (
        <div
          className="absolute z-10 flex w-64 flex-col rounded-[10px] bg-surface p-1 shadow-raised"
          style={{ left: modelMenuLeft, bottom: modelMenuBottom, maxHeight: modelMenuMaxH, animation: "pop-in 180ms cubic-bezier(0.23,1,0.32,1) both", transformOrigin: "bottom left" }}
        >
          {/* a real install lists 40+ authenticated seats — filter beats scrolling */}
          {catalog.length > 8 && (
            <input
              autoFocus
              value={modelQuery}
              onChange={(event) => {
                setModelQuery(event.target.value);
                setModelHovered(null);
              }}
              onKeyDown={(event) => {
                if (event.key === "Escape") {
                  setModelOpen(false);
                  inputRef.current?.focus();
                }
                if (event.key === "Enter" && shownModels.length > 0) {
                  selectModel(shownModels[0]);
                  inputRef.current?.focus();
                }
              }}
              placeholder="Filter models…"
              aria-label="Filter models"
              className="mb-1 h-7 shrink-0 rounded-[6px] bg-field px-2 text-[12px] text-ink shadow-hairline outline-none placeholder:text-ink-3"
            />
          )}
          <div
            onMouseLeave={() => setModelHovered(null)}
            className="relative min-h-0 flex-1 overflow-y-auto"
          >
            {/* single gliding highlight — floats to the hovered / selected row */}
            <span
              aria-hidden
              className="pointer-events-none absolute inset-x-0 rounded-[6px] bg-hover"
              style={{
                top: modelBox?.top ?? 0,
                height: modelBox?.height ?? 0,
                opacity: modelBox && modelHovered !== null ? 1 : 0,
                transition:
                  "top 220ms cubic-bezier(0.23,1,0.32,1), height 220ms cubic-bezier(0.23,1,0.32,1), opacity 150ms ease",
              }}
            />
            {shownModels.map((m, i) => (
              <button
                key={m.key}
                type="button"
                ref={(el) => {
                  modelRowRefs.current[i] = el;
                }}
                onMouseDown={(event) => event.preventDefault()}
                onMouseEnter={() => setModelHovered(i)}
                onClick={() => {
                  selectModel(m);
                  inputRef.current?.focus();
                }}
                className="relative z-10 flex h-7.5 w-full items-center gap-2 rounded-[6px] px-2 text-left"
              >
                <span className="min-w-0 flex-1 truncate text-[12.5px] font-medium text-ink">{m.name}</span>
                <span className="shrink-0 text-[11px] text-ink-3">{m.tag}</span>
                <span className={`shrink-0 text-ink ${m.key === model.key ? "" : "invisible"}`}>
                  <Icon size={13} strokeWidth={2.5}><path d="M20 6L9 17l-5-5" /></Icon>
                </span>
              </button>
            ))}
            {shownModels.length === 0 && (
              <div className="px-2 py-2 text-[12px] text-ink-3">No models match “{modelQuery.trim()}”</div>
            )}
          </div>
        </div>
      )}

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
        {/* The @ menu's attach row and the + button both open this. */}
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

        {attachError && (
          <div className={`text-[11.5px] text-red ${pill ? "px-2" : "px-1"}`} role="status">
            {attachError}
          </div>
        )}

        <div
          ref={controlsRef}
          className={`grid items-end gap-x-1 gap-y-1.5 ${
            wide
              ? "grid-cols-[28px_auto_minmax(0,1fr)_28px_28px]"
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
            aria-pressed={listening}
            onClick={() => setListening((current) => !current)}
            className={`flex size-7 shrink-0 items-center justify-center transition-[background-color,color,transform] duration-150 active:scale-[0.94] ${
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
            className={`flex size-7 shrink-0 items-center justify-center transition-[background-color,color,transform] duration-200 enabled:active:scale-[0.94] ${
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
