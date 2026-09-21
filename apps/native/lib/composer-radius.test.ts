import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

test("composer and user bubbles use design tokens, not a short-text pill", () => {
  const composer = readFileSync(path.join(import.meta.dir, "../components/primitives/PromptBar.tsx"), "utf8");
  const bubbles = readFileSync(path.join(import.meta.dir, "../components/site/ChatBubbles.tsx"), "utf8");
  expect(composer).toContain("rounded-composer");
  expect(composer).not.toContain('pill ? (attachments.length > 0 || wide ? "rounded-composer" : "rounded-full")');
  expect(bubbles).toContain("data-message-bubble");
  expect(bubbles).toContain("rounded-card");
});
