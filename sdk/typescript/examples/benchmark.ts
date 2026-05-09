/**
 * Defensible side-by-side benchmark: `@codegraff/sdk` vs `@cursor/sdk`.
 *
 * Improves on `compare.ts` in three ways:
 *   1. Creates each agent ONCE up front (amortises cold start).
 *   2. Runs a 5-prompt suite of varied complexity on each.
 *   3. Reports time-to-first-event (TTFE) and time-to-first-content (TTFC)
 *      separately from total turn time, so SDK overhead is decomposed from
 *      model think time.
 *
 * For codegraff TTFE counts the synthetic `ConversationStarted` event
 * (always near-zero); TTFC counts the first real model output
 * (TaskMessage / TaskReasoning / ToolCallStart). For cursor TTFE = TTFC
 * since the SDK does not emit a synthetic kickoff event.
 *
 * Run:
 *   CURSOR_API_KEY=<key> npm run benchmark
 *   # or, if `cursor-agent login` has stored creds, just:
 *   npm run benchmark
 *
 *   GRAFF_CWD=/some/path npm run benchmark   # different workspace
 */

import path from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

import { Agent, type SDKMessage } from "@cursor/sdk";

import { Graff, type AgentEvent } from "../lib.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = process.env.GRAFF_CWD ?? path.resolve(__dirname, "../../..");

interface Prompt {
  id: string;
  text: string;
  expectsTools: boolean;
}

const PROMPTS: Prompt[] = [
  {
    id: "p1-trivial",
    text: "Reply with just the word PONG. No commentary, no punctuation.",
    expectsTools: false,
  },
  {
    id: "p2-listing",
    text:
      "List every .rs file directly inside sdk/typescript/src — one filename " +
      "per line, no path, no commentary.",
    expectsTools: true,
  },
  {
    id: "p3-read",
    text:
      "Read sdk/typescript/lib.d.ts and reply with the number of variants in " +
      "the AgentEvent discriminated-union type. Just the integer.",
    expectsTools: true,
  },
  {
    id: "p4-search",
    text:
      "Find the file that defines the `Graff` class (with `static init`). " +
      "Reply with just the relative path.",
    expectsTools: true,
  },
  {
    id: "p5-count",
    text:
      "How many TypeScript files (.ts) live anywhere under sdk/typescript/ " +
      "excluding node_modules? Reply with just the integer.",
    expectsTools: true,
  },
];

interface TurnResult {
  ok: boolean;
  ttfeMs: number; // first event of any kind
  ttfcMs: number; // first content event (model output)
  totalMs: number;
  toolCalls: number;
  finalText: string;
  error?: string;
}

interface SuiteResult {
  label: string;
  coldStartMs: number;
  turns: Map<string, TurnResult>;
}

function nowMs(): number {
  return performance.now();
}

async function runCodegraff(): Promise<SuiteResult> {
  const turns = new Map<string, TurnResult>();
  const t0 = nowMs();
  const graff = await Graff.init(REPO_ROOT);
  const coldStartMs = nowMs() - t0;

  for (const prompt of PROMPTS) {
    const ts = nowMs();
    let ttfe = -1;
    let ttfc = -1;
    let toolCalls = 0;
    let finalText = "";
    try {
      for await (const ev of graff.chat({ prompt: prompt.text })) {
        const elapsed = nowMs() - ts;
        if (ttfe < 0) ttfe = elapsed;
        if (
          ttfc < 0 &&
          ev.type !== "ConversationStarted" &&
          ev.type !== "TaskComplete"
        ) {
          ttfc = elapsed;
        }
        if (ev.type === "ToolCallStart") toolCalls++;
        if (ev.type === "TaskMessage" && ev.content.kind === "Markdown") {
          finalText += ev.content.text;
        }
      }
      turns.set(prompt.id, {
        ok: true,
        ttfeMs: Math.max(ttfe, 0),
        ttfcMs: Math.max(ttfc, 0),
        totalMs: nowMs() - ts,
        toolCalls,
        finalText,
      });
    } catch (err) {
      turns.set(prompt.id, {
        ok: false,
        ttfeMs: Math.max(ttfe, 0),
        ttfcMs: Math.max(ttfc, 0),
        totalMs: nowMs() - ts,
        toolCalls,
        finalText,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  return { label: "codegraff", coldStartMs, turns };
}

async function runCursor(): Promise<SuiteResult> {
  const turns = new Map<string, TurnResult>();
  const t0 = nowMs();
  let agent: Awaited<ReturnType<typeof Agent.create>>;
  try {
    agent = await Agent.create({
      apiKey: process.env.CURSOR_API_KEY,
      model: { id: "gpt-5.5" },
      local: { cwd: REPO_ROOT },
    });
  } catch (err) {
    const coldStartMs = nowMs() - t0;
    const msg = err instanceof Error ? err.message : String(err);
    for (const p of PROMPTS) {
      turns.set(p.id, {
        ok: false,
        ttfeMs: 0,
        ttfcMs: 0,
        totalMs: 0,
        toolCalls: 0,
        finalText: "",
        error: `init failed: ${msg.split("\n")[0]}`,
      });
    }
    return { label: "cursor", coldStartMs, turns };
  }
  const coldStartMs = nowMs() - t0;

  for (const prompt of PROMPTS) {
    const ts = nowMs();
    let ttfe = -1;
    let toolCalls = 0;
    let finalText = "";
    try {
      const run = await agent.send(prompt.text);
      for await (const msg of run.stream() as AsyncIterable<SDKMessage>) {
        const elapsed = nowMs() - ts;
        if (ttfe < 0) ttfe = elapsed;
        if (msg.type === "tool_call" && msg.status === "running") {
          toolCalls++;
        }
        if (msg.type === "assistant") {
          for (const block of msg.message.content) {
            if (block.type === "text") finalText += block.text;
          }
        }
      }
      turns.set(prompt.id, {
        ok: true,
        ttfeMs: Math.max(ttfe, 0),
        ttfcMs: Math.max(ttfe, 0), // cursor: no synthetic kickoff event
        totalMs: nowMs() - ts,
        toolCalls,
        finalText,
      });
    } catch (err) {
      turns.set(prompt.id, {
        ok: false,
        ttfeMs: Math.max(ttfe, 0),
        ttfcMs: Math.max(ttfe, 0),
        totalMs: nowMs() - ts,
        toolCalls,
        finalText,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  await agent.close?.();
  return { label: "cursor", coldStartMs, turns };
}

function fmtMs(ms: number): string {
  if (ms < 1000) return `${ms.toFixed(0)}ms`;
  return `${(ms / 1000).toFixed(2)}s`;
}

function pad(s: string, w: number, right = false): string {
  if (s.length >= w) return s.slice(0, w);
  const fill = " ".repeat(w - s.length);
  return right ? fill + s : s + fill;
}

function avg(ns: number[]): number {
  if (ns.length === 0) return 0;
  return ns.reduce((a, b) => a + b, 0) / ns.length;
}

function summary(label: string, suite: SuiteResult): void {
  console.log(`\n=== ${label.toUpperCase()} ===`);
  console.log(`cold start (init): ${fmtMs(suite.coldStartMs)}`);
  console.log("");
  console.log(
    pad("prompt", 14) +
      pad("status", 8) +
      pad("ttfe", 10, true) +
      pad("ttfc", 10, true) +
      pad("total", 10, true) +
      pad("tools", 7, true) +
      "  preview",
  );
  console.log("-".repeat(80));
  const oks: TurnResult[] = [];
  for (const p of PROMPTS) {
    const t = suite.turns.get(p.id);
    if (!t) continue;
    if (t.ok) oks.push(t);
    const status = t.ok ? "ok" : "FAIL";
    const preview = (t.finalText || t.error || "").replace(/\s+/g, " ").trim().slice(0, 40);
    console.log(
      pad(p.id, 14) +
        pad(status, 8) +
        pad(t.ok ? fmtMs(t.ttfeMs) : "—", 10, true) +
        pad(t.ok ? fmtMs(t.ttfcMs) : "—", 10, true) +
        pad(fmtMs(t.totalMs), 10, true) +
        pad(String(t.toolCalls), 7, true) +
        "  " +
        preview,
    );
  }
  console.log("-".repeat(80));
  if (oks.length > 0) {
    console.log(
      `means (n=${oks.length}): ttfe=${fmtMs(avg(oks.map((t) => t.ttfeMs)))} ` +
        `ttfc=${fmtMs(avg(oks.map((t) => t.ttfcMs)))} ` +
        `total=${fmtMs(avg(oks.map((t) => t.totalMs)))} ` +
        `tools/turn=${avg(oks.map((t) => t.toolCalls)).toFixed(1)}`,
    );
    const sumTotal = oks.reduce((a, t) => a + t.totalMs, 0);
    console.log(`wall-clock for ${oks.length} prompts: ${fmtMs(sumTotal)}`);
  }
}

function comparison(a: SuiteResult, b: SuiteResult): void {
  console.log(`\n=== HEAD-TO-HEAD ===`);
  console.log(
    pad("prompt", 14) +
      pad(`${a.label} ttfc`, 14, true) +
      pad(`${b.label} ttfc`, 14, true) +
      pad("ratio", 10, true) +
      pad(`${a.label} total`, 14, true) +
      pad(`${b.label} total`, 14, true) +
      pad("ratio", 10, true),
  );
  console.log("-".repeat(90));
  for (const p of PROMPTS) {
    const ta = a.turns.get(p.id);
    const tb = b.turns.get(p.id);
    if (!ta?.ok || !tb?.ok) {
      console.log(pad(p.id, 14) + "  (skipped — at least one side failed)");
      continue;
    }
    const ttfcRatio = tb.ttfcMs > 0 ? (tb.ttfcMs / Math.max(ta.ttfcMs, 1)).toFixed(1) + "x" : "—";
    const totalRatio =
      tb.totalMs > 0 ? (tb.totalMs / Math.max(ta.totalMs, 1)).toFixed(1) + "x" : "—";
    console.log(
      pad(p.id, 14) +
        pad(fmtMs(ta.ttfcMs), 14, true) +
        pad(fmtMs(tb.ttfcMs), 14, true) +
        pad(ttfcRatio, 10, true) +
        pad(fmtMs(ta.totalMs), 14, true) +
        pad(fmtMs(tb.totalMs), 14, true) +
        pad(totalRatio, 10, true),
    );
  }
  console.log("-".repeat(90));
  console.log(
    `cold-start tax: ${a.label}=${fmtMs(a.coldStartMs)}  ` +
      `${b.label}=${fmtMs(b.coldStartMs)}  ` +
      `(${b.label} pays ${
        a.coldStartMs > 0 ? (b.coldStartMs / a.coldStartMs).toFixed(1) + "x" : "?"
      } of ${a.label})`,
  );
}

async function main(): Promise<void> {
  console.log(`Workspace: ${REPO_ROOT}`);
  console.log(`Suite: ${PROMPTS.length} prompts, both agents init'd ONCE.`);
  console.log(`Running codegraff first (in-process), then cursor (cloud-orchestrated).\n`);

  console.log("--- codegraff (init + 5 prompts) ---");
  const codegraff = await runCodegraff();

  console.log("--- cursor (init + 5 prompts) ---");
  const cursor = await runCursor();

  summary("codegraff", codegraff);
  summary("cursor", cursor);
  comparison(codegraff, cursor);

  console.log("\nNote: ratios are descriptive, not statistically rigorous (n=1 per prompt).");
  console.log("Run with `npm run benchmark` repeatedly to characterise variance.");
}

main().catch((err) => {
  console.error("\nFATAL:", err?.stack ?? err);
  process.exit(1);
});
