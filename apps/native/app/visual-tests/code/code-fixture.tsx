"use client";
import { useEffect, useState } from "react";
import { AssistantBody } from "@/components/site/ChatBubbles";
import { emptyTurn, type AssistantTurn } from "@/lib/acp";

export default function CodeFixture() {
  const [turn, setTurn] = useState<AssistantTurn>(() => emptyTurn());
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const receive = (event: Event) => {
      const { text, status, stopReason } = (event as CustomEvent).detail;
      setTurn({ ...emptyTurn(), text, status, stopReason });
    };
    window.addEventListener("fixture-code", receive);
    setReady(true);
    return () => window.removeEventListener("fixture-code", receive);
  }, []);
  return <main data-code-fixture data-code-fixture-ready={ready} className="h-screen overflow-auto bg-page px-6 py-8 text-ink">
    <div className="mx-auto max-w-[720px]"><AssistantBody turn={turn} following={false} /></div>
  </main>;
}
