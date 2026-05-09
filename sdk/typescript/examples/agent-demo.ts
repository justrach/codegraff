/**
 * Multi-turn agent demo for `@codegraff/sdk`.
 *
 * Drives the local codegraff agent through a series of related prompts
 * against this repo, exercising:
 *
 *   - Streaming `AgentEvent`s from the native N-API addon.
 *   - Real tool execution (read / search / etc.) inside the agent — the SDK
 *     auto-fires `Notify` so tools run without a TUI to confirm.
 *   - Conversation memory carried across `.send()` calls.
 *   - The `Graff` long-lived instance + `session()` factory from Phase 3.
 *
 * Run from the SDK root:
 *
 *   npm run demo
 *
 * The demo points at this repo's checkout by default. Override with
 *
 *   GRAFF_CWD=/some/other/workspace npm run demo
 */

import path from "node:path";
import { fileURLToPath } from "node:url";

import { Graff, type AgentEvent } from "../lib.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
// examples/ → sdk/typescript/ → sdk/ → repo root
const REPO_ROOT = process.env.GRAFF_CWD ?? path.resolve(__dirname, "../../..");

const TURNS: readonly string[] = [
  "List the .rs files under sdk/typescript/src and describe each in ONE sentence. Be concise.",
  "Based on what you just saw (don't open any new files), which file would I edit to add a new SDK method that returns workspace info? Reply with just the filename and one short reason.",
  "Now confirm by reading that file and quoting the existing method whose structure I should mimic.",
];

function ts(): string {
  return new Date().toISOString().slice(11, 19);
}

function renderEvent(ev: AgentEvent, turnIdx: number): void {
  const tag = `[turn ${turnIdx + 1} ${ts()}]`;
  switch (ev.type) {
    case "ConversationStarted":
      process.stderr.write(`${tag} ⏵ conversationId=${ev.conversationId.slice(0, 8)}…\n`);
      break;
    case "TaskMessage":
      if (ev.content.kind === "Markdown") {
        // Stream the visible answer to stdout so it can be piped/captured.
        process.stdout.write(ev.content.text);
      } else if (ev.content.kind === "ToolInput") {
        process.stderr.write(`${tag} ▸ ${ev.content.title}\n`);
      }
      break;
    case "TaskReasoning":
      // Collapse silent reasoning to a single dot per chunk so the demo
      // doesn't flood the terminal but you can still see progress.
      process.stderr.write(".");
      break;
    case "ToolCallStart": {
      const args = JSON.stringify(ev.tool_call.arguments);
      const argPreview = args.length > 80 ? args.slice(0, 77) + "..." : args;
      process.stderr.write(`${tag} → ${ev.tool_call.name}(${argPreview})\n`);
      break;
    }
    case "ToolCallEnd": {
      const ok = ev.result.output?.is_error ? "✗" : "✓";
      process.stderr.write(`${tag} ${ok} ${ev.result.name}\n`);
      break;
    }
    case "RetryAttempt":
      process.stderr.write(`${tag} ⟳ retry: ${ev.cause} (after ${ev.duration_ms}ms)\n`);
      break;
    case "Interrupt":
      process.stderr.write(`${tag} ⚠ interrupt: ${ev.reason.kind}\n`);
      break;
    case "TaskComplete":
      process.stderr.write(`\n${tag} ✓ turn complete\n`);
      break;
  }
}

async function main(): Promise<void> {
  const graff = await Graff.init(REPO_ROOT);
  const active = (await graff.getActiveAgent()) ?? "(default)";
  process.stderr.write(
    `@codegraff/sdk ${graff.version()} — cwd=${REPO_ROOT} agent=${active}\n`,
  );

  const session = graff.session();

  for (let i = 0; i < TURNS.length; i++) {
    const prompt = TURNS[i]!;
    process.stderr.write(`\n[turn ${i + 1}] >>> ${prompt}\n---\n`);
    for await (const ev of session.send(prompt)) {
      renderEvent(ev, i);
    }
  }

  process.stderr.write(`\nfinal conversationId: ${session.conversationId}\n`);
  await session.close();
}

main().catch((err) => {
  process.stderr.write(`\nFATAL: ${err?.stack ?? err}\n`);
  process.exit(1);
});
