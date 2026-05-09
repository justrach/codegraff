/**
 * Side-by-side comparison demo: `@codegraff/sdk` vs `@cursor/sdk`.
 *
 * Both agents are pointed at this codegraff checkout and given the same
 * prompt. Each runs in parallel; we capture per-agent wall-clock duration,
 * tool-call count, and final assistant text, then print a comparison table.
 *
 * Auth:
 *   - codegraff inherits the local `graff` config (provider/model already
 *     selected via `graff provider login`).
 *   - cursor uses `CURSOR_API_KEY` if set, otherwise falls back to the
 *     credentials stored by `cursor-agent login`. If neither is available
 *     the cursor side surfaces a clear error in the comparison row.
 *
 * Run:
 *   npm run compare
 *
 *   GRAFF_CWD=/some/path npm run compare      # point at a different workspace
 */

import path from "node:path";
import { fileURLToPath } from "node:url";

import { Agent, type SDKMessage } from "@cursor/sdk";

import { Graff, type AgentEvent } from "../lib.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
// examples/ → sdk/typescript/ → sdk/ → repo root
const REPO_ROOT = process.env.GRAFF_CWD ?? path.resolve(__dirname, "../../..");

const PROMPT =
  "Read sdk/typescript/lib.d.ts and list every variant of the `AgentEvent` " +
  "discriminated-union type. Reply with ONE variant name per line, no " +
  "commentary, no code fence.";

interface RunSummary {
  label: string;
  ok: boolean;
  durationMs: number;
  toolCalls: number;
  finalText: string;
  error?: string;
}

async function runCodegraff(): Promise<RunSummary> {
  const t0 = Date.now();
  let toolCalls = 0;
  let finalText = "";
  try {
    const graff = await Graff.init(REPO_ROOT);
    for await (const ev of graff.chat({ prompt: PROMPT })) {
      if (ev.type === "ToolCallStart") toolCalls++;
      if (ev.type === "TaskMessage" && ev.content.kind === "Markdown") {
        finalText += ev.content.text;
      }
    }
    return { label: "codegraff", ok: true, durationMs: Date.now() - t0, toolCalls, finalText };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { label: "codegraff", ok: false, durationMs: Date.now() - t0, toolCalls, finalText, error: msg };
  }
}

async function runCursor(): Promise<RunSummary> {
  const t0 = Date.now();
  let toolCalls = 0;
  let finalText = "";
  try {
    // Per @cursor/sdk types: `apiKey` is optional. When unset, the SDK uses
    // whatever credentials `cursor-agent login` stored. We forward an env-var
    // override if present so CI / scripted use can authenticate explicitly.
    const agent = await Agent.create({
      apiKey: process.env.CURSOR_API_KEY,
      model: { id: "gpt-5.5" },
      local: { cwd: REPO_ROOT },
    });
    const run = await agent.send(PROMPT);

    for await (const msg of run.stream() as AsyncIterable<SDKMessage>) {
      if (msg.type === "tool_call" && msg.status === "running") {
        toolCalls++;
      }
      if (msg.type === "assistant") {
        for (const block of msg.message.content) {
          if (block.type === "text") finalText += block.text;
        }
      }
    }

    await agent.close?.();
    return { label: "cursor", ok: true, durationMs: Date.now() - t0, toolCalls, finalText };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { label: "cursor", ok: false, durationMs: Date.now() - t0, toolCalls, finalText, error: msg };
  }
}

function pad(s: string, w: number): string {
  return s.length >= w ? s.slice(0, w) : s + " ".repeat(w - s.length);
}

function printTable(rows: RunSummary[]): void {
  const colW = 38;
  const sep = "+" + "-".repeat(15) + "+" + rows.map(() => "-".repeat(colW)).join("+") + "+";
  console.log("");
  console.log(sep);
  process.stdout.write("| " + pad("metric", 13) + " ");
  for (const r of rows) process.stdout.write("| " + pad(r.label.toUpperCase(), colW - 2) + " ");
  console.log("|");
  console.log(sep);
  const fields: Array<[string, (r: RunSummary) => string]> = [
    ["status", (r) => (r.ok ? "✓ ok" : "✗ " + (r.error?.split("\n")[0] ?? "failed").slice(0, colW - 6))],
    ["duration", (r) => `${(r.durationMs / 1000).toFixed(1)}s`],
    ["tool calls", (r) => String(r.toolCalls)],
    ["answer chars", (r) => String(r.finalText.length)],
    ["preview", (r) => r.finalText.replace(/\s+/g, " ").trim().slice(0, colW - 5)],
  ];
  for (const [name, fn] of fields) {
    process.stdout.write("| " + pad(name, 13) + " ");
    for (const r of rows) process.stdout.write("| " + pad(fn(r), colW - 2) + " ");
    console.log("|");
  }
  console.log(sep);
}

function printAnswers(rows: RunSummary[]): void {
  for (const r of rows) {
    console.log(`\n=== ${r.label.toUpperCase()} final answer ===`);
    if (r.ok) {
      console.log(r.finalText.trim() || "(empty)");
    } else {
      console.log(`(error: ${r.error})`);
    }
  }
}

async function main(): Promise<void> {
  console.log(`Prompt:\n  ${PROMPT}\n`);
  console.log(`Workspace: ${REPO_ROOT}`);
  console.log(`Running codegraff + cursor in parallel...`);

  const results = await Promise.all([runCodegraff(), runCursor()]);

  printTable(results);
  printAnswers(results);
}

main().catch((err) => {
  console.error("\nFATAL:", err?.stack ?? err);
  process.exit(1);
});
