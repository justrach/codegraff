// SDK orchestration layer (#276 P0-2) — hand-written, NOT auto-generated
// (contrast harness.ts/remote.ts's "Do not edit" header: this file is the
// place new SDK surface belongs). Realizes docs/hyperagents.md §3's framing
// ("the loop itself belongs in SDK code... not in the harness") for the
// third primitive that section names but never wired up: agent()/parallel()/
// pipeline() as first-class TS functions instead of one JSON blob the root
// LLM has to decide, on its own judgement, to emit as a `subagent`/
// `workflow` tool call.
//
// ── How agent() gets determinism out of an LLM loop ─────────────────────
// Each `agent()` call spawns its own short-lived `harness --json` process
// (idiomatic to this SDK's existing style — see runAgent in harness.ts) with
// its system prompt replaced by DISPATCH_SYSTEM_PROMPT: a rigid instruction
// to call exactly one named tool with an exact, SDK-supplied JSON input and
// nothing else. The SDK — not the model's judgement — fully determines the
// tool name and its input (including the isolation/run_in_background fields
// added by #276 P0-1/P0-3), so the only thing left to the model is executing
// one mechanical, fully-specified instruction; the result is read straight
// off that tool call's own `tool_result` event (never off the dispatcher's
// restated final answer), and background completions ride the same
// mechanism as a second scripted turn against `agent_output` on the same
// process (background jobs are process-local Zig state — see subagent.zig's
// g_agent_jobs — so spawn and poll must share one Harness). This is honest,
// LLM-instruction-following determinism, not hard protocol-level
// determinism; the orchestration *control flow* around it (concurrency,
// barriers, budget admission, journal replay) is what's actually
// deterministic, and that's the layer #276 P0-2 asks for.
//
// ── Journal format (JSONL, one record per LIVE agent() call) ────────────
//   {"key":"a3","promptHash":"<sha256:16hex>","optsHash":"<sha256:16hex>",
//    "ok":true,"text":"...","usage":{"durationMs":..,"toolCalls":..,
//    "contextTokens":..,"cacheReadTokens":..},"ts":1700000000000}
//
// `key` is "a<N>": the Nth call made against a given Run's `agent()` /
// `Run.agent()`, N assigned by a synchronous counter at invocation time (not
// completion time), so two runs of the same deterministic script assign the
// same keys to the same logical calls regardless of real completion timing
// — this holds exactly for sequential (`await`ed one at a time) calls, and
// for calls made inside a single `parallel()`/`pipeline()` batch sized at or
// under the concurrency cap (the common case: all admitted synchronously, in
// array order, before any of them can complete — see `limitedMap`). Larger
// queued batches can admit item N+1 in completion order once the window is
// full, which is a documented, deliberate scope boundary: resume replay is
// exact for the tested/common shapes above and best-effort beyond them.
//
// Resume ("prefix replay"): `new Run({resumeFrom: <path to a prior
// journal.jsonl>})` loads it into a key -> record map. Each live call first
// checks that map by its own key: while nothing has diverged yet, a hit
// whose promptHash+optsHash both match replays the cached {ok, text, usage}
// with no runner call at all (never spawns a process, never re-charges the
// budget); the FIRST miss or hash mismatch flips a one-way `diverged` latch
// on the Run, and every call from that point on — even one that would, by
// coincidence, still match — runs live and gets appended fresh. That's the
// literal "prefix, then live from the first divergence" semantics: a warm
// re-run of an unchanged script touches the runner zero times; changing call
// k re-runs k and everything after it, byte-for-byte replaying 0..k-1.

import { createHash, randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { Harness, promptFingerprint, type Event, type HarnessOptions } from "./harness.ts";

// ── Shared task shape ───────────────────────────────────────────────────

/** Fields the underlying `subagent` tool call accepts (schema.zig
 *  `subagent_spec`) — src/fleet.zig's persona conventions apply to `agent`
 *  (builtins: reviewer, researcher, implementer, skeptic, or a
 *  `.harness/agents/<name>` override). */
export interface SubagentSpec {
  /** Short label for logs, 3-5 words. Defaults to a prompt prefix. */
  description?: string;
  /** Complete, self-contained task description for the child. */
  prompt: string;
  /** Named persona the child runs with. */
  agent?: string;
  /** Replace the child's system prompt outright (overrides `agent`). */
  systemPrompt?: string;
  /** #276 P0-1 passthrough: `"worktree"` gives this call its own scratch
   *  git worktree instead of the shared working tree. */
  isolation?: "shared_cwd" | "worktree";
  /** If isolation:"worktree" fails to set up, run in the shared cwd instead
   *  of failing the call. Default false, matching the tool's own default. */
  isolationFallback?: boolean;
  /** #276 P0-3 passthrough: run this subagent in the background on the
   *  dispatching process, then poll it via `agent_output` on the same
   *  process. Default false (synchronous). */
  background?: boolean;
  /** SDK-side deadline for a background subagent to reach a terminal result.
   *  The harness process is closed (and force-killed after its grace period)
   *  when this expires. Default 120 seconds. */
  backgroundTimeoutMs?: number;
}

export interface AgentOptions extends Omit<SubagentSpec, "prompt"> {
  /** Pins the dispatching harness process's model (and therefore the
   *  child's, which inherits the parent's provider verbatim — see
   *  subagent.zig's runSub: `.provider = ctx.provider`). */
  model?: string;
  /** Passthrough to the spawned Harness. `yolo` defaults to true: these are
   *  non-interactive, fully scripted dispatches with nothing to confirm. */
  harness?: Pick<HarnessOptions, "binary" | "cwd" | "env" | "yolo" | "maxToolCalls" | "maxModelCalls" | "dedupeToolCalls" | "args">;
  /** Injectable transport. Defaults to a shared `HarnessRunner`; tests
   *  substitute a fake so orchestration logic never needs a live binary. */
  runner?: AgentRunner;
  /** Attach this call to a `Run`'s budget/journal/concurrency instead of
   *  running as a bare, unjournaled one-off. */
  run?: Run;
}

export interface AgentUsage {
  durationMs: number;
  toolCalls: number;
  contextTokens: number;
  cacheReadTokens: number;
}

export interface AgentResult {
  ok: boolean;
  text: string;
  usage: AgentUsage;
  /** true when replayed from a Run's journal instead of run live. */
  cached: boolean;
}

const zeroUsage: AgentUsage = { durationMs: 0, toolCalls: 0, contextTokens: 0, cacheReadTokens: 0 };

/** Injectable transport for `agent()` — the one seam that actually talks to
 *  a `graff` process. Swap it in tests; production code never needs to. */
export interface AgentRunner {
  run(spec: SubagentSpec, opts: { model?: string; harness?: AgentOptions["harness"] }): Promise<AgentResult>;
}

// ── The real transport ──────────────────────────────────────────────────

const DISPATCH_SYSTEM_PROMPT =
  "You are a mechanical tool dispatcher, not a conversational assistant. " +
  'On the turn you receive, call the exact tool named in it with the exact ' +
  "JSON input given — verbatim, unmodified — and nothing else: no commentary, " +
  "no other tool first, no attempt_completion. Exactly one tool call.";

function dispatchPrompt(toolName: string, input: Record<string, unknown>): string {
  return `Call the "${toolName}" tool exactly once with this exact JSON as its input (do not modify it): ${JSON.stringify(input)}`;
}

/** Builds the exact JSON `subagent` tool input for a spec (schema.zig
 *  `subagent_spec` field names) — exported so the wire mapping is directly
 *  unit-testable without a live process. */
export function subagentToolInput(spec: SubagentSpec): Record<string, unknown> {
  const input: Record<string, unknown> = {
    description: spec.description ?? spec.prompt.slice(0, 60),
    prompt: spec.prompt,
  };
  if (spec.agent) input.agent = spec.agent;
  if (spec.systemPrompt) input.system_prompt = spec.systemPrompt;
  if (spec.isolation) input.isolation = spec.isolation;
  if (spec.isolationFallback) input.isolation_fallback = true;
  if (spec.background) input.run_in_background = true;
  return input;
}

/** Parses the id out of spawnSubBackground's ack text (subagent.zig:531-535,
 *  `"[agent {d} started: {s}]\n..."`). Exported so tests can pin the format
 *  without needing a live process. */
export function parseBackgroundId(ackText: string): number | null {
  const m = /^\[agent (\d+) started:/.exec(ackText);
  return m ? Number(m[1]) : null;
}

function usageFromEvent(ev: Extract<Event, { type: "agent_usage" }>): AgentUsage {
  return {
    durationMs: ev.duration_ms,
    toolCalls: ev.tool_calls,
    contextTokens: ev.context_tokens,
    cacheReadTokens: ev.cache_read_tokens,
  };
}

/** Real `AgentRunner`: spawns a `graff --json` process per call and scripts
 *  it into exactly one `subagent` tool call (see the file header). */
export class HarnessRunner implements AgentRunner {
  async run(spec: SubagentSpec, opts: { model?: string; harness?: AgentOptions["harness"] } = {}): Promise<AgentResult> {
    const h = new Harness({
      ...opts.harness,
      model: opts.model,
      yolo: opts.harness?.yolo ?? true,
      systemPrompt: DISPATCH_SYSTEM_PROMPT,
    });
    try {
      const first = await this.drive(h, dispatchPrompt("subagent", subagentToolInput(spec)), "subagent");
      if (!spec.background) {
        return first.result ?? { ok: false, text: "agent(): dispatcher never called the subagent tool", usage: first.usage, cached: false };
      }
      const id = first.result ? parseBackgroundId(first.result.text) : null;
      if (id === null) {
        return { ok: false, text: first.result?.text ?? "agent(): could not read a background agent id", usage: first.usage, cached: false };
      }
      const timeoutMs = Math.max(0, spec.backgroundTimeoutMs ?? 120_000);
      const deadline = Date.now() + timeoutMs;
      do {
        const waitMs = Math.min(30_000, Math.max(0, deadline - Date.now()));
        const poll = await this.drive(h, dispatchPrompt("agent_output", { id, wait_ms: waitMs }), "agent_output");
        if (!poll.result) return { ok: false, text: `agent(): agent_output never returned for id ${id}`, usage: poll.usage, cached: false };
        if (!backgroundResultRunning(poll.result.text, id)) return poll.result;
      } while (Date.now() < deadline);
      return {
        ok: false,
        text: `agent(): background agent ${id} exceeded its ${timeoutMs}ms deadline`,
        usage: first.usage,
        cached: false,
      };
    } finally {
      h.close();
    }
  }

  /** Drive one scripted turn, stopping as soon as the target tool's
   *  tool_result — and whatever agent_usage event preceded it — have been
   *  seen. Never waits for the dispatcher's own turn/attempt_completion. */
  private async drive(h: Harness, prompt: string, toolName: string): Promise<{ result: AgentResult | null; usage: AgentUsage }> {
    let usage = { ...zeroUsage };
    let result: AgentResult | null = null;
    for await (const ev of h.chat(prompt)) {
      if (ev.type === "agent_usage") usage = usageFromEvent(ev);
      if (ev.type === "tool_result" && ev.name === toolName) {
        result = { ok: !ev.is_error, text: ev.text, usage, cached: false };
        break;
      }
      if (ev.type === "error") throw new Error(ev.message);
    }
    return { result, usage };
  }
}

export const defaultRunner: AgentRunner = new HarnessRunner();

export function backgroundResultRunning(text: string, id: number): boolean {
  return text.trimStart().startsWith(`[agent ${id}: running]`);
}

// ── Budget: budget.spent()/remaining()/total, fed by real AgentUsage ────

export interface BudgetTotals {
  calls: number;
  tokens: number;
}

export interface BudgetOptions {
  maxCalls?: number;
  maxTokens?: number;
}

/** Token-aware budget. Calls-based budgeting (`total.calls`) is the
 *  existing RunBudget concept, counted SDK-side since the SDK itself
 *  decides when each subagent call happens; token budgeting is additive,
 *  fed by real `AgentUsage.contextTokens` off the `agent_usage` completion
 *  event (#276 P0-2's one Zig-side change — see subagent.zig). */
export class Budget {
  readonly total: BudgetTotals;
  private _calls = 0;
  private _tokens = 0;

  constructor(opts: BudgetOptions = {}) {
    this.total = { calls: opts.maxCalls ?? Infinity, tokens: opts.maxTokens ?? Infinity };
  }

  spent(): BudgetTotals {
    return { calls: this._calls, tokens: this._tokens };
  }

  remaining(): BudgetTotals {
    return {
      calls: this.total.calls === Infinity ? Infinity : Math.max(0, this.total.calls - this._calls),
      tokens: this.total.tokens === Infinity ? Infinity : Math.max(0, this.total.tokens - this._tokens),
    };
  }

  /** True once either ceiling is used up — callers stop admitting new work
   *  rather than erroring mid-fan-out. */
  exhausted(): boolean {
    const r = this.remaining();
    return r.calls <= 0 || r.tokens <= 0;
  }

  /** Record one live agent() call. Internal bookkeeping — agent()/Run.agent
   *  call reserveCall()/chargeReserved() instead; nothing outside a Run
   *  should call any of the three. */
  charge(usage: AgentUsage): void {
    this._calls += 1;
    this._tokens += usage.contextTokens;
  }

  /** Atomically reserve one SDK call before asynchronous runner work starts.
   *  JavaScript executes this synchronously, so parallel fan-out cannot race
   *  several calls through the same remaining slot. */
  reserveCall(): boolean {
    if (this.exhausted()) return false;
    this._calls += 1;
    return true;
  }

  /** Complete a previously reserved call with its measured token usage. */
  chargeReserved(usage: AgentUsage): void {
    this._tokens += usage.contextTokens;
  }

  /** Undo a reservation whose runner never produced a result (transport
   *  error): the call never happened, so it must not count in spent() or
   *  drain the calls ceiling. Tokens are untouched — none were charged. */
  releaseCall(): void {
    this._calls -= 1;
  }
}

// ── Concurrency ──────────────────────────────────────────────────────────

/** Matches run_budget.zig's `default_max_concurrency` / subagent.zig's
 *  `max_concurrent_background_agents` (both 8) — the SDK-side fan-out cap is
 *  sized the same as the core's, composing with it instead of racing past it
 *  with a flood of independent processes. */
export const DEFAULT_CONCURRENCY = 8;

/** Concurrency-limited map. Admission is a fixed worker pool pulling from a
 *  shared cursor: for `items.length <= limit`, every item's worker claims
 *  its index synchronously up front (before any `fn` call can suspend), so
 *  admission order == array order regardless of how long each `fn` actually
 *  takes — the property both the no-barrier pipeline proof and journal-key
 *  determinism above rely on. */
async function limitedMap<T, R>(items: readonly T[], limit: number, fn: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const workerCount = Math.max(1, Math.min(limit, items.length || 1));
  const workers = Array.from({ length: workerCount }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return results;
}

// ── parallel(): explicit barrier, null-on-failure ───────────────────────

export interface ParallelOptions {
  concurrency?: number;
}

/** Fan out `thunks`, wait for all of them (the barrier — maps to
 *  workflow.zig's phases mode), and never reject the batch: a thunk that
 *  throws resolves as `null` at its index instead. Compose multiple
 *  `parallel()` calls sequentially for a barrier BETWEEN phases. */
export async function parallel<T>(thunks: Array<() => Promise<T>>, opts: ParallelOptions = {}): Promise<Array<T | null>> {
  const limit = opts.concurrency ?? DEFAULT_CONCURRENCY;
  return limitedMap(thunks, limit, async (thunk) => {
    try {
      return await thunk();
    } catch {
      return null;
    }
  });
}

// ── pipeline(): per-item flow, no cross-stage barrier ───────────────────

/** One pipeline stage: receives the previous stage's result for THIS item
 *  (undefined for the first stage), the original item, and its index. */
export type Stage<T> = (prev: unknown, item: T, index: number) => Promise<unknown>;

/** Map each item through `stages` independently — maps to workflow.zig's
 *  pipeline mode (no barrier): item A can reach stage 3 while item B is
 *  still on stage 1. A stage throwing fails only that item (resolves
 *  `null`), mirroring parallel()'s null-on-failure convention. */
export async function pipeline<T>(items: T[], ...stages: Array<Stage<T>>): Promise<Array<unknown | null>> {
  return limitedMap(items, DEFAULT_CONCURRENCY, async (item, index) => {
    let prev: unknown = undefined;
    try {
      for (const stage of stages) prev = await stage(prev, item, index);
      return prev;
    } catch {
      return null;
    }
  });
}

// ── agent(): the one primitive that talks to a real process ─────────────

/** Run one subagent task. With no `opts.run` this is a bare, unjournaled,
 *  unbudgeted one-off (still spawns via `opts.runner ?? defaultRunner`).
 *  Pass `opts.run` to participate in a `Run`'s budget/journal/replay. */
export async function agent(prompt: string, opts: AgentOptions = {}): Promise<AgentResult> {
  const spec = toSpec(prompt, opts);
  if (opts.run) return opts.run.dispatch(spec, opts);
  const runner = opts.runner ?? defaultRunner;
  return runner.run(spec, { model: opts.model, harness: opts.harness });
}

function toSpec(prompt: string, opts: AgentOptions): SubagentSpec {
  return {
    prompt,
    description: opts.description,
    agent: opts.agent,
    systemPrompt: opts.systemPrompt,
    isolation: opts.isolation,
    isolationFallback: opts.isolationFallback,
    background: opts.background,
    backgroundTimeoutMs: opts.backgroundTimeoutMs,
  };
}

function stableStringify(obj: Record<string, unknown>): string {
  const keys = Object.keys(obj)
    .filter((k) => obj[k] !== undefined)
    .sort();
  return "{" + keys.map((k) => JSON.stringify(k) + ":" + JSON.stringify(obj[k])).join(",") + "}";
}

/** Everything about a call that changes what actually runs — excludes
 *  transport plumbing (runner/harness/run) which isn't part of the task. */
function hashOpts(spec: SubagentSpec, model: string | undefined): string {
  const relevant = {
    agent: spec.agent,
    systemPrompt: spec.systemPrompt,
    isolation: spec.isolation,
    isolationFallback: spec.isolationFallback,
    background: spec.background,
    backgroundTimeoutMs: spec.backgroundTimeoutMs,
    model,
  };
  return createHash("sha256").update(stableStringify(relevant)).digest("hex").slice(0, 16);
}

// ── Run: budget + JSONL journal + prefix resume ─────────────────────────

interface JournalRecord {
  key: string;
  promptHash: string;
  optsHash: string;
  ok: boolean;
  text: string;
  usage: AgentUsage;
  ts: number;
}

export interface RunOptions {
  /** Directory the journal is written under. Default: a fresh directory
   *  under `.graff/journal/<run-id>/` off `process.cwd()`. */
  dir?: string;
  /** Path to a previous run's `journal.jsonl` to prefix-replay from. */
  resumeFrom?: string;
  budget?: BudgetOptions;
  concurrency?: number;
  runner?: AgentRunner;
}

/** An orchestration run: owns a `Budget`, a JSONL journal, and the
 *  prefix-resume cursor described in the file header. Create one per
 *  logical script invocation and pass it as `{run}` to every `agent()`
 *  call that should be budgeted/journaled/resumable. */
export class Run {
  readonly id: string;
  readonly dir: string;
  readonly journalPath: string;
  readonly budget: Budget;
  readonly runner: AgentRunner;
  readonly concurrency: number;

  private nextSeq = 0;
  private diverged = false;
  private readonly oldByKey = new Map<string, JournalRecord>();

  constructor(opts: RunOptions = {}) {
    this.id = `${Date.now().toString(36)}-${randomBytes(4).toString("hex")}`;
    this.dir = opts.dir ?? join(process.cwd(), ".graff", "journal", this.id);
    this.journalPath = join(this.dir, "journal.jsonl");
    this.budget = new Budget(opts.budget);
    this.runner = opts.runner ?? defaultRunner;
    this.concurrency = opts.concurrency ?? DEFAULT_CONCURRENCY;
    if (opts.resumeFrom) this.loadJournal(opts.resumeFrom);
    mkdirSync(this.dir, { recursive: true });
  }

  private loadJournal(path: string): void {
    if (!existsSync(path)) return;
    for (const line of readFileSync(path, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        const rec = JSON.parse(line) as JournalRecord;
        this.oldByKey.set(rec.key, rec);
      } catch {
        // A corrupt line loses that one cached call, not the whole resume.
      }
    }
  }

  private appendJournal(rec: JournalRecord): void {
    appendFileSync(this.journalPath, JSON.stringify(rec) + "\n");
  }

  /** Journaled, budgeted `agent()` call bound to this Run. */
  agent(prompt: string, opts: AgentOptions = {}): Promise<AgentResult> {
    return this.dispatch(toSpec(prompt, opts), opts);
  }

  /** Fan out on this Run's own concurrency default. Budget/journal
   *  awareness comes from the thunks calling `run.agent()`/`agent(p,{run})`
   *  themselves — see the file header for why parallel()/pipeline() stay
   *  generic rather than reaching into opaque thunks. */
  runParallel<T>(thunks: Array<() => Promise<T>>): Promise<Array<T | null>> {
    return parallel(thunks, { concurrency: this.concurrency });
  }

  runPipeline<T>(items: T[], ...stages: Array<Stage<T>>): Promise<Array<unknown | null>> {
    return pipeline(items, ...stages);
  }

  /** @internal shared by the free `agent(prompt, {run})` form. */
  async dispatch(spec: SubagentSpec, opts: Pick<AgentOptions, "model" | "harness" | "runner">): Promise<AgentResult> {
    const key = "a" + this.nextSeq++;
    const promptHash = promptFingerprint(spec.prompt);
    const optsHash = hashOpts(spec, opts.model);

    if (!this.diverged) {
      const old = this.oldByKey.get(key);
      if (old && old.promptHash === promptHash && old.optsHash === optsHash) {
        return { ok: old.ok, text: old.text, usage: old.usage, cached: true };
      }
      this.diverged = true;
    }

    if (!this.budget.reserveCall()) {
      return { ok: false, text: "agent(): budget exhausted, call not admitted", usage: { ...zeroUsage }, cached: false };
    }

    const runner = opts.runner ?? this.runner;
    let result: AgentResult;
    try {
      result = await runner.run(spec, { model: opts.model, harness: opts.harness });
    } catch (err) {
      // Transport failure: the call never ran. Release its reservation so a
      // flaky runner can't drain the calls budget (making later calls fail
      // with a misleading "budget exhausted"), and leave the journal
      // untouched — resume re-runs from this key. Rethrow so callers and
      // parallel()/pipeline() keep their reject/null-on-failure contract.
      this.budget.releaseCall();
      throw err;
    }
    this.budget.chargeReserved(result.usage);
    this.appendJournal({ key, promptHash, optsHash, ok: result.ok, text: result.text, usage: result.usage, ts: Date.now() });
    return result;
  }
}
