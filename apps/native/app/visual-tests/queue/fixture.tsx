"use client";
import { useRef, useState } from "react";
import PromptQueue from "@/components/site/PromptQueue";
import { usePromptQueue } from "@/components/site/usePromptQueue";

const image = "@[/tmp/graff-native-attachments/queued-image.png]";
export default function Fixture() {
  const queue = usePromptQueue();
  const running = useRef(true);
  const [busy, setBusy] = useState(true);
  const [open, setOpen] = useState(true);
  const [sent, setSent] = useState<string[]>([]);
  const start = () => {
    queue.setQueue(1, [{ id: 1, text: "First follow-up" }, { id: 2, text: `Look at this\n${image}` }]);
    running.current = true; setBusy(true); setOpen(true); setSent([]);
  };
  const resume = () => {
    if (running.current) return;
    const next = queue.take(1);
    if (next) { running.current = true; setBusy(true); setSent(current => [...current, next.text]); }
  };
  return <main className="mx-auto max-w-[720px] p-6">
    <button type="button" onClick={start}>Start fixture</button>
    <button type="button" onClick={() => { running.current = false; setBusy(false); resume(); }}>Finish turn</button>
    <button type="button" onClick={() => setOpen(value => !value)}>{open ? "Hide chat" : "Return to chat"}</button>
    <button type="button" onClick={() => { queue.setQueue(1, []); running.current = false; setBusy(false); setOpen(false); }}>Close chat</button>
    {open && <PromptQueue items={queue.queues[1] ?? []} busy={busy} error="Could not interrupt the current turn"
      onSteer={() => {}}
      onBeginEdit={item => queue.beginEdit(1, item)}
      onChangeEdit={(item, draft) => queue.changeEdit(1, item, draft)}
      onCancelEdit={item => { queue.cancelEdit(1, item); resume(); }}
      onEdit={(item, text) => { queue.edit(1, item, text); resume(); }}
      onRemove={item => { queue.remove(1, item); resume(); }} />}
    <output aria-label="Sent messages">{JSON.stringify(sent)}</output>
    <output aria-label="Queue state">{JSON.stringify(queue.queues)}</output>
  </main>;
}
