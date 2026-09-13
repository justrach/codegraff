"use client";
import { useEffect, useState } from "react";
import { AssistantBody } from "@/components/site/ChatBubbles";
import Markdown from "@/components/primitives/Markdown";
import { emptyTurn, type AssistantTurn } from "@/lib/acp";

export default function CodeFixture() {
  const [turn, setTurn] = useState<AssistantTurn>(() => emptyTurn());
  const [ready, setReady] = useState(false);
  const [asDocument, setAsDocument] = useState(false);
  useEffect(() => {
    const receive = (event: Event) => {
      const { text, status, stopReason, asDocument } = (event as CustomEvent).detail;
      setAsDocument(!!asDocument);
      setTurn({ ...emptyTurn(), text, status, stopReason });
    };
    window.addEventListener("fixture-code", receive);
    setReady(true);
    return () => window.removeEventListener("fixture-code", receive);
  }, []);
  return <main data-code-fixture data-code-fixture-ready={ready} className="h-screen overflow-auto bg-page px-6 py-8 text-ink">
    <div className="mx-auto max-w-[720px]">{asDocument ? <Markdown asDocument text={turn.text} /> : <AssistantBody turn={turn} following={false} />}</div>
  </main>;
}
