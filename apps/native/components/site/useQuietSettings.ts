"use client";
import { useRef } from "react";
import { fetchModels, prompt, type ChatHandle } from "@/lib/acp-client";

export function useQuietSettings(options: {
  requireSession(id: number): Promise<string>;
  handleOf(id: number): ChatHandle;
  running: Set<number>;
  apply(catalog: Awaited<ReturnType<typeof fetchModels>>): void;
}) {
  const pending = useRef(new Map<number, Promise<void>>());
  return {
    wait: (id: number) => pending.current.get(id)?.catch(() => {}),
    change(id: number, command: string): Promise<void> {
      if (!/^\/(effort (low|medium|high|xhigh|max|ultra)|fast (on|off))$/.test(command)) return Promise.reject(Error("Unsupported setting"));
      if (options.running.has(id)) return Promise.reject(Error("Wait for the current response to finish."));
      const task = (async () => {
        await pending.current.get(id)?.catch(() => {});
        const session = await options.requireSession(id);
        // Graff handles these commands before the model loop and session history.
        // Consume the confirmation without creating a conversation turn.
        for await (const _ of prompt(options.handleOf(id), session, command)) { /* drain */ }
        const catalog = await fetchModels(options.handleOf(id));
        const selected = catalog.models.find(model => model.key === catalog.current);
        const [setting, value] = command.slice(1).split(" ");
        if (setting === "effort" ? selected?.effort !== value : selected?.fast !== (value === "on")) throw Error("Graff did not apply this setting. Try again.");
        options.apply(catalog);
      })();
      pending.current.set(id, task);
      void task.finally(() => { if (pending.current.get(id) === task) pending.current.delete(id); }).catch(() => {});
      return task;
    },
  };
}
