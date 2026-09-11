"use client";
import { useState } from "react";
import { AssistantBody } from "@/components/site/ChatBubbles";
import { emptyTurn, finishAcpTurn, type AssistantTurn } from "@/lib/acp";
import { applyAppearance, type Appearance } from "@/lib/appearance";
export const cases = ["starting", "thinking", "writing", "running", "waiting", "done", "stopped", "error", "partial-error", "missing-result"] as const;
function fixture(name: typeof cases[number]): AssistantTurn {
  const now = Date.now();
  const turn: AssistantTurn = { ...emptyTurn(), startedAt: now - (name === "done" ? 559000 : 40000), lastUpdateAt: now, connected: name !== "starting", text: "Preparing a theme preview with readable text and a distinct accent.", status: "streaming", tools: [] };
  if (name === "starting" || name === "thinking") { turn.text = ""; turn.status = "thinking"; turn.activityKind = "agent_thought_chunk"; }
  if (name === "writing") turn.activityKind = "agent_message_chunk";
  if (["running", "waiting", "missing-result", "error"].includes(name)) turn.tools = [{ id: "fixture-tool", name: "Check palette", icon: "run", chip: "palette.json", status: name === "waiting" ? "ok" : "running", detail: [{ text: "Scripted tool output" }], atChars: 0, startedAt: now - 5000 }];
  if (name === "waiting") turn.lastUpdateAt = now - 25000;
  if (name === "partial-error" || name === "done" || name === "stopped") {
    turn.text = "The preview is ready. The updated layout and keyboard shortcut checks passed.";
    turn.tools = [
      { id: "write", name: "Update layout", chip: "layout.tsx", icon: "write", status: "ok", detail: [{ text: "Layout updated." }], atChars: 0 },
      { id: "test", name: "Check shortcuts", chip: "2 checks", icon: "run", status: "ok", detail: [{ text: "Shortcut checks passed." }], atChars: 0 },
    ];
    if (name === "partial-error") {
      turn.tools.push({ id: "last", name: "Inspect preview", chip: "preview", icon: "run", status: "running", detail: [], atChars: turn.text.length });
      return finishAcpTurn({ ...turn, status: "error", error: "The connection to Graff ended before the turn finished." });
    }
  }
  if (name === "error") return finishAcpTurn({ ...turn, status: "error", error: "The connection ended before the turn completed." });
  if (name === "stopped") return finishAcpTurn({ ...turn, stopReason: "cancelled" });
  return name === "done" || name === "missing-result" ? finishAcpTurn(turn) : turn;
}
export default function TurnFixture() {
  const [name, setName] = useState<typeof cases[number]>("starting");
  const [turn, setTurn] = useState(() => fixture("starting"));
  return <main className="flex h-screen flex-col bg-page text-ink" data-visual-fixture>
    <nav aria-label="Fixture scenarios" className="flex flex-wrap gap-2 border-b border-line p-3">
      {cases.map(value => <button key={value} data-case={value} onClick={() => { setName(value); setTurn(fixture(value)); }} className="rounded bg-field px-2 py-1 text-xs">{value}</button>)}
      {(["light", "dark", "codegraff"] as Appearance[]).map(theme => <button key={theme} data-theme-choice={theme} onClick={() => applyAppearance(theme)} className="rounded bg-field px-2 py-1 text-xs">{theme}</button>)}
    </nav>
    <div className="min-h-0 flex-1 overflow-auto px-6 py-8"><div className="mx-auto max-w-[720px]" data-fixture-transcript><AssistantBody key={name} turn={turn} following={false} /></div></div>
    <div data-fixture-composer className="mx-auto mb-5 w-[calc(100%-48px)] max-w-[720px] rounded-xl border border-line bg-surface p-4 text-sm text-ink-3">{turn.status === "streaming" || turn.status === "thinking" ? "Queue a follow-up…" : "Follow up"}</div>
  </main>;
}
