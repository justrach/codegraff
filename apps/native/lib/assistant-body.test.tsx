import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AssistantBody } from "../components/site/ChatBubbles";
import { SeenTextContext } from "../components/site/useSmoothStream";
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

const count = (html: string, needle: string) => html.split(needle).length - 1;

test("an errored turn tells the failure once, with the provider's words as muted detail", () => {
  const turn = { ...emptyTurn(), status: "error" as const, startedAt: 1000, endedAt: 13000, error: "xai api error: Internal error during token parsing" };
  const html = renderToStaticMarkup(<AssistantBody turn={turn} following={false} onRetry={() => {}} />);
  expect(count(html, "Response interrupted")).toBe(1);
  expect(count(html, "data-turn-error")).toBe(1);
  expect(count(html, "role=\"alert\"")).toBe(1);
  expect(html).toContain("xai failed mid-response");
  expect(html).toContain("Internal error during token parsing");
  expect(html).toContain("After 12s.");
  expect(html).toContain("data-retry-turn");
  expect(html).not.toMatch(/data-retry-turn[^>]*\sdisabled=/);
});

test("Retry only exists on an errored turn, and waits while another turn is live", () => {
  const done = { ...emptyTurn(), status: "done" as const, text: "Fine." };
  expect(renderToStaticMarkup(<AssistantBody turn={done} following={false} onRetry={() => {}} />)).not.toContain("data-retry-turn");
  const failed = { ...emptyTurn(), status: "error" as const, error: "Disconnected" };
  expect(renderToStaticMarkup(<AssistantBody turn={failed} following={false} />)).not.toContain("data-retry-turn");
  const busy = renderToStaticMarkup(<AssistantBody turn={failed} following={false} onRetry={() => {}} retryDisabled />);
  expect(busy).toContain("data-retry-turn");
  expect(busy).toMatch(/data-retry-turn[^>]*\sdisabled=/);
});

test("remounted live text starts at the prefix already seen in that chat", () => {
  const turn = { ...emptyTurn(), status: "streaming" as const, text: "Already seen.\nA new line arrived." };
  const seen = new Map([["42:0", "Already seen."]]);
  const render = (prefix: Map<string, string>) => renderToStaticMarkup(
    <SeenTextContext.Provider value={prefix}><AssistantBody turn={turn} messageId={42} following={false} /></SeenTextContext.Provider>,
  );
  const resumed = render(seen);
  expect(resumed).toContain("Already seen.");
  expect(resumed).not.toContain("A new line arrived.");
  seen.set("42:0", turn.text);
  expect(render(seen)).toContain("A new line arrived.");
  expect(render(new Map())).not.toContain("Already seen.");
});
