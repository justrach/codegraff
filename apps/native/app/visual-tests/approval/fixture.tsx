"use client";

import { useRef, useState } from "react";
import ApprovalCard from "@/components/primitives/ApprovalCard";
import { AssistantBody } from "@/components/site/ChatBubbles";
import { emptyTurn, type AssistantTurn } from "@/lib/acp";

function askTurn(): AssistantTurn {
  return {
    ...emptyTurn(),
    status: "ask",
    ask: {
      callId: "approval-fixture",
      question: "Which flavor should we ship?",
      options: ["Pistachio", "Mint", "Vanilla"],
    },
  };
}

const multiQuestions = [
  { q: "Which market should launch first?", type: "radio" as const, options: ["Retail", "Online"] },
  { q: "Which colors should be included?", type: "check" as const, options: ["Red", "Blue", "Green"] },
];

export default function ApprovalFixture() {
  const [singleKey, setSingleKey] = useState(0);
  const [singleSubmissions, setSingleSubmissions] = useState<string[]>([]);
  const [singleCancellations, setSingleCancellations] = useState(0);
  const [multiKey, setMultiKey] = useState(0);
  const [multiSubmissions, setMultiSubmissions] = useState<string[][]>([]);
  const [ackKey, setAckKey] = useState(0);
  const ackFails = useRef(1);
  const [ackSubmissions, setAckSubmissions] = useState(0);

  return (
    <main className="min-h-screen bg-page p-8 text-ink">
      <div className="mx-auto grid max-w-[900px] gap-10 md:grid-cols-2">
        <section aria-label="Single-question approval" className="space-y-4">
          <div className="flex items-center justify-between gap-3">
            <h1 className="text-lg font-semibold">Single-question ask</h1>
            <button
              type="button"
              onClick={() => {
                setSingleKey((key) => key + 1);
                setSingleSubmissions([]);
                setSingleCancellations(0);
              }}
              className="rounded bg-field px-3 py-1.5 text-xs"
            >
              Reset single approval
            </button>
          </div>
          <AssistantBody
            key={singleKey}
            turn={askTurn()}
            following={false}
            onAnswer={(text, cancelled) => {
              if (cancelled) setSingleCancellations((count) => count + 1);
              else setSingleSubmissions((answers) => [...answers, text]);
            }}
          />
          <output aria-label="Single submissions" className="block font-mono text-xs">
            {JSON.stringify(singleSubmissions)}
          </output>
          <output aria-label="Single cancellations" className="block font-mono text-xs">
            {singleCancellations}
          </output>
        </section>

        <section aria-label="Multi-question approval" className="space-y-4">
          <div className="flex items-center justify-between gap-3">
            <h1 className="text-lg font-semibold">Multi-question approval</h1>
            <button
              type="button"
              onClick={() => {
                setMultiKey((key) => key + 1);
                setMultiSubmissions([]);
              }}
              className="rounded bg-field px-3 py-1.5 text-xs"
            >
              Reset multi approval
            </button>
          </div>
          <ApprovalCard
            key={multiKey}
            questions={multiQuestions}
            resettable={false}
            onSubmitted={(answers) => setMultiSubmissions((all) => [...all, answers ?? []])}
          />
          <output aria-label="Multi submissions" className="block font-mono text-xs">
            {JSON.stringify(multiSubmissions)}
          </output>
        </section>

        <section aria-label="Acknowledged approval" className="space-y-4 md:col-span-2">
          <div className="flex items-center justify-between gap-3">
            <h1 className="text-lg font-semibold">Acknowledged send</h1>
            <button
              type="button"
              onClick={() => {
                setAckKey((key) => key + 1);
                ackFails.current = 1;
                setAckSubmissions(0);
              }}
              className="rounded bg-field px-3 py-1.5 text-xs"
            >
              Reset acknowledgement
            </button>
          </div>
          <ApprovalCard
            key={ackKey}
            resettable={false}
            questions={[{ q: "Ship pistachio?", type: "radio", options: ["Yes", "No"] }]}
            onSubmitted={async (answers) => {
              await new Promise((resolve) => setTimeout(resolve, 80));
              if (ackFails.current > 0) {
                ackFails.current -= 1;
                throw new Error("notify failed");
              }
              setAckSubmissions((count) => count + 1);
              void answers;
            }}
          />
          <output aria-label="Acknowledged submissions" className="block font-mono text-xs">
            {ackSubmissions}
          </output>
        </section>
      </div>
    </main>
  );
}
