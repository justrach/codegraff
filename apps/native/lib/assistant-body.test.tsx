import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AssistantBody } from "../components/site/ChatBubbles";
import { emptyTurn } from "./graff-events";

test("completed turns do not retain a synthetic waiting disclosure", () => {
  const turn = { ...emptyTurn(), status: "done" as const, thoughtMs: 8000, text: "Check finished." };
  const html = renderToStaticMarkup(<AssistantBody turn={turn} following={false} />);
  expect(html).toContain("Check finished.");
  expect(html).not.toContain("Waiting on the model");
  expect(html).not.toContain("Thought for");
});

test("ask_user renders the approval card instead of a spinner", () => {
  const turn = {
    ...emptyTurn(),
    status: "ask" as const,
    ask: { callId: "q1", question: "Which mix?", options: ["Pistachio", "Mint"] },
  };
  const html = renderToStaticMarkup(<AssistantBody turn={turn} following={false} />);
  expect(html).toContain("Which mix?");
  expect(html).toContain("Pistachio");
  expect(html).toContain("data-ask-card");
});

test("actual reasoning is retained when a turn completes", () => {
  const turn = { ...emptyTurn(), status: "done" as const, reasoning: "Inspect the relevant file.", thoughtMs: 8000 };
  const html = renderToStaticMarkup(<AssistantBody turn={turn} following={false} />);
  expect(html).toContain("Inspect the relevant file.");
  expect(html).toContain("Thought for 8s");
});
