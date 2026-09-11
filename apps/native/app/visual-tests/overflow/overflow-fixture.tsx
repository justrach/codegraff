"use client";

import { useCallback, useMemo, useState } from "react";
import ChatTranscript from "@/components/site/ChatTranscript";
import { emptyTurn, type AssistantTurn } from "@/lib/acp";
import type { Msg } from "@/components/site/harness-types";

const noop = () => {};
const widths = [260, 360, 720] as const;
const cases = ["all", "url", "prose", "inline-path", "nested", "table", "fence", "stream", "error", "recap", "reasoning", "user"] as const;
type Case = typeof cases[number];
const token = "UnbrokenDiagnosticPayload".repeat(32);
const path = `fixtures/${"deeply-nested-module/".repeat(18)}${"long-component-name-".repeat(12)}fixture.tsx:128-256`;
const url = `https://example.com/artifacts/overflow-fixture/builds/${"release-candidate-".repeat(20)}report?filter=${"diagnostic%2F".repeat(35)}&view=expanded#final-result`;
const codeLine = `const diagnostic = "${token}"; // FENCE_END`;
const openFence = `## CASE: stream\n\nAn incomplete fence grows in explicit steps.\n\n\`\`\`typescript\nconst streamed = "`;
const table = [
  "## CASE: table",
  "",
  `| ${Array.from({ length: 8 }, (_, i) => `Header_${i}_${"WideHeader".repeat(8)}`).join(" | ")} |`,
  `| ${Array.from({ length: 8 }, () => "---").join(" | ")} |`,
  ...Array.from({ length: 5 }, (_, row) => `| ${Array.from({ length: 8 }, (_, col) => `Cell_${row}_${col}_${"UnbrokenCell".repeat(12)}_END`).join(" | ")} |`),
].join("\n");

function makeTurn(name: Exclude<Case, "all" | "user">, step: number): AssistantTurn {
  const turn: AssistantTurn = { ...emptyTurn(), status: "done", thoughtMs: 0 };
  switch (name) {
    case "url":
      turn.text = `## CASE: url\n\nBare URL: ${url}\n\n[${url}](${url})\n\nwww.example.com/${token}\n\nURL_END`;
      break;
    case "prose":
      turn.text = `## CASE: prose\n\n${token}\n\nPROSE_END`;
      break;
    case "inline-path":
      turn.text = `## CASE: inline-path\n\nOpen \`${path}\` and inspect the entire path.\n\nAlso non-path inline code: \`${token}\`.\n\nPATH_END`;
      break;
    case "nested":
      turn.text = `## CASE: nested\n\n1. Outer ordered item\n   - Inner bullet ${token}\n     - Deep link [${url}](${url})\n\n> A quoted diagnostic\n>\n> - Nested quoted item \`${path}\`\n>   - ${token}\n\nNESTED_END`;
      break;
    case "table": turn.text = table; break;
    case "fence":
      turn.text = `## CASE: fence\n\n\`\`\`typescript\n${codeLine}\n${Array.from({ length: 12 }, (_, i) => `// line ${i}: ${token}`).join("\n")}\n// LAST_CODE_LINE\n\`\`\`\n\nFENCE_AFTER`;
      break;
    case "stream":
      turn.status = step === 3 ? "done" : "streaming";
      turn.text = openFence + (step >= 1 ? token.slice(0, 220) : "") + (step >= 2 ? token.slice(220) : "") + (step >= 3 ? '";\n// STREAM_CODE_END\n```\n\nSTREAM_FINISHED' : "");
      break;
    case "error":
      turn.status = "error";
      turn.text = "## CASE: error\n\nThe following alert must remain fully readable.";
      turn.error = `ERROR_START: Unable to process ${path}: ${token} ERROR_END`;
      break;
    case "recap":
      turn.text = "## CASE: recap\n\nThe recap bypasses the Markdown renderer.";
      turn.recap = `RECAP_START ${token} ${url} RECAP_END`;
      break;
    case "reasoning":
      turn.status = "thinking";
      turn.activityKind = "agent_thought_chunk";
      turn.reasoning = `REASONING_START Inspect ${path}\n${token}\n${url} REASONING_END`;
      turn.text = "## CASE: reasoning\n\nExpanded reasoning must wrap rather than silently clip.";
      break;
  }
  return turn;
}

function messagesFor(selected: Case, step: number): Msg[] {
  const chosen = selected === "all" ? cases.filter(name => name !== "all") : [selected];
  return chosen.map((name, index): Msg => name === "user"
    ? { id: index + 1, role: "user", text: `CASE: user\n${token}\n${url}\n${path}\nUSER_END` }
    : { id: index + 1, role: "assistant", turn: makeTurn(name as Exclude<Case, "all" | "user">, step) });
}

function Pane({ id, width, selected, step, following }: {
  id: string; width: number; selected: Case; step: number; following: boolean;
}) {
  const messages = useMemo(() => messagesFor(selected, step), [selected, step]);
  const [opened, setOpened] = useState(false);
  const register = useCallback((element: HTMLDivElement | null) => {
    if (element) element.dataset.overflowScroller = id;
  }, [id]);
  return <section data-overflow-pane={id} data-pane-width={width}
    className="flex min-h-0 min-w-0 shrink-0 flex-col border border-line bg-surface"
    style={{ width, height: 640 }}>
    <header className="shrink-0 border-b border-line p-2 text-xs">{id}: {width}px</header>
    <ChatTranscript key={selected} messages={messages} register={register} following={following}
      onOpenPath={() => setOpened(true)} onReview={noop} />
    <footer className="shrink-0 border-t border-line p-2">
      <textarea data-overflow-composer={id} aria-label={`${id} composer`}
        className="block w-full min-w-0 resize-none rounded bg-field p-2 text-xs" rows={2}
        placeholder="Still reachable after vertical scrolling" />
      <output data-overflow-path-opened={id} className="text-xs">{opened ? "Path clicked" : "No path clicked"}</output>
    </footer>
  </section>;
}

/** No fixture-level clipping or wrapping: production components must contain their own content.
 * Use a >= 1500px viewport for two 720px panes; narrower viewports deliberately
 * reveal the fixture board's fixed geometry, not a transcript regression.
 * Stream updates are manual (0=open, 1=partial, 2=long, 3=closed), never timers.
 */
export default function OverflowFixture() {
  const [width, setWidth] = useState<number>(360);
  const [selected, setSelected] = useState<Case>("all");
  const [step, setStep] = useState(0);
  const [split, setSplit] = useState(true);
  const [following, setFollowing] = useState(false);
  return <main data-graff-main data-overflow-fixture data-overflow-case={selected}
    data-stream-step={step} className="min-h-screen bg-page p-3 text-ink">
    <nav aria-label="Overflow fixture controls" className="mb-3 flex flex-wrap gap-2">
      {widths.map(value => <button key={value} type="button" data-overflow-width={value}
        aria-pressed={width === value} onClick={() => setWidth(value)} className="rounded bg-field px-2 py-1">{value}px</button>)}
      {cases.map(value => <button key={value} type="button" data-overflow-select={value}
        aria-pressed={selected === value} onClick={() => { setSelected(value); setStep(0); }}
        className="rounded bg-field px-2 py-1">{value}</button>)}
      <button type="button" data-overflow-split aria-pressed={split} onClick={() => setSplit(!split)}>Two panes</button>
      <button type="button" data-overflow-follow aria-pressed={following} onClick={() => setFollowing(!following)}>Follow tail</button>
      {[0, 1, 2, 3].map(value => <button key={value} type="button" data-overflow-stream={value}
        aria-pressed={step === value} onClick={() => setStep(value)}>Stream {value}</button>)}
    </nav>
    <div data-overflow-board className="flex items-start gap-3">
      <Pane id="left" width={width} selected={selected} step={step} following={following} />
      {split && <Pane id="right" width={width} selected={selected} step={step} following={following} />}
    </div>
  </main>;
}
