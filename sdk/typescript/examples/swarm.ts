/**
 * DevSwarm-style swarm orchestration via @codegraff/sdk.
 *
 * Implements the orchestrator → workers → synthesizer pattern from
 * justrach/devswarm as a single-file SDK example. Three stages:
 *
 *   1. Orchestrator decomposes the task into N independent subtasks.
 *   2. N workers run those subtasks in parallel, each in its own Graff.
 *   3. Synthesizer merges the worker outputs into one cohesive response.
 *
 * Thin slice of codegraff issue #55 ([DSP-1]). Deliberately out of scope:
 * role+mode routing, worktree isolation, preset task chains, role-specific
 * model tiers (Opus orchestrator / Sonnet workers / Haiku monitor),
 * NO_ISSUES_FOUND review-fix termination. Those land in follow-up PRs
 * against the same issue.
 *
 * Run from sdk/typescript/:
 *   npm run swarm -- "your task here"
 *
 * Env:
 *   GRAFF_CWD     workspace the workers run inside (defaults to repo root)
 *   SWARM_N       worker count, clamped [1, 8] (default 3)
 *   SWARM_MODEL   model id passed through to every stage (optional)
 */

import path from "node:path";
import { fileURLToPath } from "node:url";

import { Graff, type AgentEvent } from "../lib.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
// examples/ → sdk/typescript/ → sdk/ → repo root
const REPO_ROOT = process.env.GRAFF_CWD ?? path.resolve(__dirname, "../../..");
const N_WORKERS = clampWorkers(process.env.SWARM_N);
const MODEL = process.env.SWARM_MODEL || undefined;

const DEFAULT_TASK =
  "List the .rs files under sdk/typescript/src and describe what each does in ONE sentence.";
const TASK = process.argv.slice(2).join(" ").trim() || DEFAULT_TASK;

function clampWorkers(raw: string | undefined): number {
  const parsed = Number(raw ?? 3);
  if (!Number.isFinite(parsed)) return 3;
  return Math.max(1, Math.min(8, Math.floor(parsed)));
}

function ts(): string {
  return new Date().toISOString().slice(11, 19);
}

interface DrainResult {
  text: string;
  toolCalls: number;
  interrupted: boolean;
}

// Drain a chat stream, accumulating final-Markdown text and counting tool
// calls. Logs lifecycle to stderr so the answer on stdout stays clean.
async function drain(label: string, stream: AsyncIterable<AgentEvent>): Promise<DrainResult> {
  let text = "";
  let toolCalls = 0;
  let interrupted = false;
  for await (const ev of stream) {
    switch (ev.type) {
      case "ConversationStarted":
        process.stderr.write(`[${ts()}] ${label} ⏵ conv=${ev.conversationId.slice(0, 8)}\n`);
        break;
      case "TaskMessage":
        if (ev.content.kind === "Markdown") text += ev.content.text;
        else if (ev.content.kind === "ToolInput")
          process.stderr.write(`[${ts()}] ${label} ▸ ${ev.content.title}\n`);
        break;
      case "ToolCallStart":
        toolCalls++;
        break;
      case "Interrupt":
        interrupted = true;
        process.stderr.write(`[${ts()}] ${label} ⚠ ${ev.reason.kind}\n`);
        break;
      case "TaskComplete":
        process.stderr.write(`[${ts()}] ${label} ✓\n`);
        break;
    }
  }
  return { text, toolCalls, interrupted };
}

// Extract a JSON array of strings from orchestrator output. Tolerates
// ```json fences and surrounding prose because models add them anyway.
export function extractJsonArray(raw: string): string[] {
  const fence = raw.match(/```(?:json)?\s*([\s\S]*?)```/);
  const candidate = (fence ? fence[1] : raw).trim();
  const start = candidate.indexOf("[");
  const end = candidate.lastIndexOf("]");
  if (start === -1 || end === -1 || end <= start) {
    throw new Error(`orchestrator did not return a JSON array:\n${raw.slice(0, 500)}`);
  }
  const parsed: unknown = JSON.parse(candidate.slice(start, end + 1));
  if (!Array.isArray(parsed) || !parsed.every((s) => typeof s === "string")) {
    throw new Error("orchestrator JSON was not an array of strings");
  }
  return parsed as string[];
}

async function decompose(graff: Graff, task: string, n: number): Promise<string[]> {
  const prompt =
    `You are the ORCHESTRATOR in a multi-agent swarm. Break the task below into ` +
    `EXACTLY ${n} independent subtasks that can run in parallel without coordination. ` +
    `Each subtask must be self-contained: a worker reading only the subtask should ` +
    `know what to do. Return STRICTLY a JSON array of ${n} strings, no prose, no ` +
    `code fence.\n\nTASK:\n${task}`;
  const opts = MODEL ? { prompt, model: MODEL } : { prompt };
  const { text } = await drain("orchestrator", graff.chat(opts));
  return extractJsonArray(text);
}

interface WorkerOutput {
  workerId: number;
  subtask: string;
  result: string;
  toolCalls: number;
  durationMs: number;
}

async function runWorker(workerId: number, subtask: string): Promise<WorkerOutput> {
  const label = `worker[${workerId + 1}]`;
  const t0 = Date.now();
  // Each worker gets its own Graff so conversation state is fully isolated —
  // the cheap stand-in for the worktree isolation devswarm uses for swarm
  // workers (their ADR-001 / issue #213). Worker prompt does NOT include
  // the orchestrator preamble so we don't leak it into worker context
  // (lesson from devswarm #389).
  const graff = await Graff.init({ cwd: REPO_ROOT });
  const prompt =
    `You are worker ${workerId + 1} in a parallel swarm. Complete ONLY the ` +
    `subtask below and return a concise result. Do not speculate about other ` +
    `workers or the overall task.\n\nSUBTASK:\n${subtask}`;
  const opts = MODEL ? { prompt, model: MODEL } : { prompt };
  const { text, toolCalls } = await drain(label, graff.chat(opts));
  return {
    workerId,
    subtask,
    result: text,
    toolCalls,
    durationMs: Date.now() - t0,
  };
}

async function synthesize(graff: Graff, task: string, outputs: WorkerOutput[]): Promise<string> {
  const bundle = outputs
    .map(
      (o) =>
        `--- WORKER ${o.workerId + 1} ---\n` +
        `SUBTASK: ${o.subtask}\n` +
        `OUTPUT:\n${o.result.trim()}`,
    )
    .join("\n\n");
  const prompt =
    `You are the SYNTHESIZER in a multi-agent swarm. Combine the worker outputs ` +
    `below into ONE cohesive response answering the original task. Resolve ` +
    `disagreements explicitly. Do not invent facts not present in worker ` +
    `outputs.\n\nORIGINAL TASK:\n${task}\n\n${bundle}`;
  const opts = MODEL ? { prompt, model: MODEL } : { prompt };
  const { text } = await drain("synthesizer", graff.chat(opts));
  return text;
}

async function main(): Promise<void> {
  process.stderr.write(
    `swarm n=${N_WORKERS} cwd=${REPO_ROOT}${MODEL ? ` model=${MODEL}` : ""}\n`,
  );
  process.stderr.write(`TASK: ${TASK}\n---\n`);

  // Orchestrator and synthesizer share one Graff and run sequentially.
  // Workers each get their own Graff and run in parallel.
  const driver = await Graff.init({ cwd: REPO_ROOT });

  const t0 = Date.now();
  const subtasks = await decompose(driver, TASK, N_WORKERS);
  process.stderr.write(`\n[${ts()}] decomposed into ${subtasks.length} subtasks:\n`);
  subtasks.forEach((s, i) => {
    const preview = s.length > 140 ? s.slice(0, 137) + "..." : s;
    process.stderr.write(`  ${i + 1}. ${preview}\n`);
  });
  process.stderr.write(`\n`);

  const workerResults = await Promise.all(subtasks.map((s, i) => runWorker(i, s)));
  const totalToolCalls = workerResults.reduce((a, w) => a + w.toolCalls, 0);

  process.stderr.write(`\n[${ts()}] all ${subtasks.length} workers done. synthesizing...\n\n`);
  const finalText = await synthesize(driver, TASK, workerResults);

  const ms = Date.now() - t0;
  process.stderr.write(`\n=== final ===\n`);
  process.stdout.write(finalText.trim() + "\n");
  process.stderr.write(
    `\n[swarm] n=${subtasks.length} duration=${(ms / 1000).toFixed(1)}s ` +
      `tool_calls=${totalToolCalls}\n`,
  );
}

main().catch((err) => {
  process.stderr.write(`\nFATAL: ${err?.stack ?? err}\n`);
  process.exit(1);
});
