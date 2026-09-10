"use client";

import { useEffect, useState } from "react";
import TaskRows, { type TaskItem } from "@/components/primitives/TaskRows";

export default function TaskRowsFixture() {
  const [items, setItems] = useState<TaskItem[]>([]);
  const [variant, setVariant] = useState("Capsules");
  const [revision, setRevision] = useState(0);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const receive = (event: Event) => {
      const next = (event as CustomEvent<{ items: TaskItem[]; variant: string; revision: number }>).detail;
      setItems(next.items);
      setVariant(next.variant);
      setRevision(next.revision);
    };
    window.addEventListener("fixture-tasks", receive);
    setReady(true);
    return () => window.removeEventListener("fixture-tasks", receive);
  }, []);
  return <main data-tasks-fixture data-ready={ready} data-revision={revision}
    className="min-h-screen overflow-x-hidden bg-page px-6 py-8 text-ink">
    <h1 className="mb-4">Task row interaction fixture</h1>
    <button data-focus-start type="button">Before task rows</button>
    <section data-task-rows className="my-4"><TaskRows variant={variant} items={items} /></section>
    <button data-focus-end type="button">After task rows</button>
  </main>;
}
