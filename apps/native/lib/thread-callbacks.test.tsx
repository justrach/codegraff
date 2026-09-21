import { expect, test } from "bun:test";
import { useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createThreadCallbackRegistry, useThreadCallbacks, type ThreadCallbacks, type ThreadHandlers } from "../components/site/useThreadCallbacks";
import { promptIndexes } from "../components/site/ChatTranscript";
import type { Msg } from "../components/site/harness-types";
import { emptyTurn } from "./graff-events";

const handlers = (log: string[], tag: string): ThreadHandlers => ({
  onOpenPath: (path, chatId) => log.push(`${tag} open ${chatId} ${path}`),
  onAnswer: (chatId, text, cancelled) => log.push(`${tag} answer ${chatId} ${text} ${cancelled ?? false}`),
  onEditPrompt: (chatId, n, text) => log.push(`${tag} edit ${chatId} ${n} ${text}`),
});

test("per-thread callbacks keep their identity across re-renders while running the latest handlers", () => {
  const seen: ThreadCallbacks[] = [];
  const log: string[] = [];
  function Probe() {
    const [pass, setPass] = useState(0);
    const callbacksOf = useThreadCallbacks(handlers(log, `pass${pass}`), [1, 2]);
    seen.push(callbacksOf(1));
    // A render-phase update re-runs this component with its hooks intact:
    // the same test double the harness re-render on every painted token.
    if (pass < 2) setPass(pass + 1);
    return <span>{pass}</span>;
  }
  expect(renderToStaticMarkup(<Probe />)).toBe("<span>2</span>");
  expect(seen).toHaveLength(3);
  expect(seen[1]).toBe(seen[0]);
  expect(seen[2].onOpenPath).toBe(seen[0].onOpenPath);
  expect(seen[2].onAnswer).toBe(seen[0].onAnswer);
  expect(seen[2].onEditPrompt).toBe(seen[0].onEditPrompt);
  // The function handed out on the first render reaches the handlers of the last one.
  seen[0].onOpenPath("src/a.ts");
  seen[0].onAnswer("yes");
  seen[0].onEditPrompt(3, "again");
  expect(log).toEqual(["pass2 open 1 src/a.ts", "pass2 answer 1 yes false", "pass2 edit 1 3 again"]);
});

test("the registry hands out one object per chat and forgets closed chats", () => {
  const log: string[] = [];
  const registry = createThreadCallbackRegistry(() => handlers(log, "now"));
  const first = registry.forThread(1), second = registry.forThread(2);
  expect(registry.forThread(1)).toBe(first);
  expect(first).not.toBe(second);
  second.onOpenPath("b.ts");
  expect(log).toEqual(["now open 2 b.ts"]);
  expect(registry.size).toBe(2);
  registry.prune([1]);
  expect(registry.size).toBe(1);
  expect(registry.forThread(1)).toBe(first);
  expect(registry.forThread(2)).not.toBe(second);
});

test("promptIndexes numbers prompts 1-based and attributes turns and notices to the prompt before them", () => {
  const messages: Msg[] = [
    { id: 1, role: "user", text: "first" },
    { id: 2, role: "assistant", turn: emptyTurn() },
    { id: 3, role: "user", origin: "notification", text: "peer mail" },
    { id: 4, role: "user", text: "second" },
    { id: 5, role: "assistant", turn: { ...emptyTurn(), status: "error" } },
  ];
  expect(promptIndexes(messages)).toEqual([1, 1, 1, 2, 2]);
  expect(promptIndexes([])).toEqual([]);
});
