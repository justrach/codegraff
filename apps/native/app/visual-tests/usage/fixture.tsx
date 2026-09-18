"use client";
import { useState } from "react";
import ChatTranscript from "@/components/site/ChatTranscript";
import { emptyTurn } from "@/lib/acp";
import type { Msg } from "@/components/site/harness-types";

// Synthetic usage: never put real session/account data in a public fixture.
const report = `session usage
  api calls: 12 (12 subscription, flat-rate)
  tokens: 12400 in (8000 cached) + 640 out
  cost: $0.0000 (API-key calls with a known price only)
codex plan
  plan: sample
  5h: 65% remaining (35% used), resets in a few hours
xai / grok
  xAI weekly plan remaining is not a public API`;
const original = "Could we make this output easier to read?\n\nKeep the useful numbers together, with the plan limits underneath. I'd like the message to keep its rounded shape while I edit it, too.";
export default function Fixture() {
  const [text, setText] = useState(original);
  const messages: Msg[] = [
    { id: 1, role: "user", text: "/usage" },
    { id: 2, role: "assistant", turn: { ...emptyTurn(), text: report, status: "done" } },
    { id: 3, role: "user", text },
  ];
  return <main className="mx-auto flex h-screen max-w-[760px] flex-col bg-surface text-ink">
    <ChatTranscript messages={messages} register={() => {}} following={false} onOpenPath={() => {}} onReview={() => {}}
      onEditPrompt={(_, next) => setText(next)} />
  </main>;
}
