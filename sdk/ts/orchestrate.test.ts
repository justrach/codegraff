// Tests for orchestrate.ts (#276 P0-2). Everything here runs against a
// FakeRunner — no live `graff` process, no API keys, no network — since the
// thing under test is the orchestration logic (concurrency/barriers/
// budget/journal), not the transport (HarnessRunner, which needs a real
// binary and is exercised structurally by the pure-helper tests instead).

import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  agent,
  backgroundResultRunning,
  Budget,
  DEFAULT_CONCURRENCY,
  parallel,
  parseBackgroundId,
  pipeline,
  Run,
  subagentToolInput,
  type AgentResult,
  type AgentRunner,
  type AgentUsage,
  type Stage,
  type SubagentSpec,
} from "./orchestrate.ts";

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function usage(contextTokens = 0): AgentUsage {
  return { durationMs: 1, toolCalls: 1, contextTokens, cacheReadTokens: 0 };
}

function ok(text: string, contextTokens = 0): AgentResult {
  return { ok: true, text, usage: usage(contextTokens), cached: false };
}

/** Deterministic, in-process stand-in for HarnessRunner. */
class FakeRunner implements AgentRunner {
  calls: SubagentSpec[] = [];
  constructor(private impl: (spec: SubagentSpec, callIndex: number) => Promise<AgentResult> | AgentResult) {}
  async run(spec: SubagentSpec): Promise<AgentResult> {
    const n = this.calls.length;
    this.calls.push(spec);
    return this.impl(spec, n);
  }
}

function tmpJournalDir(): string {
  return mkdtempSync(join(tmpdir(), "graff-journal-"));
}

// ── parallel(): explicit barrier, null-on-failure ───────────────────────

describe("parallel()", () => {
  test("explicit barrier — resolves only once the slowest thunk settles", async () => {
    let fastDone = false;
    let slowDone = false;
    const thunks = [
      async () => {
        await sleep(5);
        fastDone = true;
        return "fast";
      },
      async () => {
        await sleep(45);
        slowDone = true;
        return "slow";
      },
    ];
    const pending = parallel(thunks);
    await sleep(20);
    expect(fastDone).toBe(true);
    expect(slowDone).toBe(false); // still in flight -- parallel() has not returned
    const results = await pending;
    expect(slowDone).toBe(true);
    expect(results).toEqual(["fast", "slow"]);
  });

  test("a failed thunk resolves null, never rejects the batch", async () => {
    const results = await parallel([
      async () => "ok-1",
      async () => {
        throw new Error("boom");
      },
      async () => "ok-3",
    ]);
    expect(results).toEqual(["ok-1", null, "ok-3"]);
  });

  test("respects the concurrency cap", async () => {
    let active = 0;
    let maxActive = 0;
    const thunks = Array.from({ length: 6 }, () => async () => {
      active++;
      maxActive = Math.max(maxActive, active);
      await sleep(10);
      active--;
      return true;
    });
    await parallel(thunks, { concurrency: 2 });
    expect(maxActive).toBeLessThanOrEqual(2);
  });

  test("default concurrency matches the core's background-agent cap (8)", () => {
    expect(DEFAULT_CONCURRENCY).toBe(8);
  });
});

// ── pipeline(): per-item flow, no cross-stage barrier ────────────────────

describe("pipeline()", () => {
  test("no-barrier proof: a slow item does not block another item's later stages", async () => {
    const order: string[] = [];
    const stage1: Stage<string> = async (_prev, item) => {
      await sleep(item === "slow" ? 60 : 5);
      order.push(`${item}:stage1`);
      return item;
    };
    const stage2: Stage<string> = async (_prev, item) => {
      order.push(`${item}:stage2`);
      return item;
    };
    const results = await pipeline(["slow", "fast"], stage1, stage2);
    expect(results).toEqual(["slow", "fast"]);
    // "fast"'s whole chain finishes before "slow" even clears stage 1 --
    // proof there is no barrier between items at a stage boundary.
    expect(order.indexOf("fast:stage2")).toBeLessThan(order.indexOf("slow:stage1"));
  });

  test("stage callbacks receive (prevResult, originalItem, index)", async () => {
    const seen: Array<[unknown, string, number]> = [];
    const stage1: Stage<string> = async (prev, item, index) => {
      seen.push([prev, item, index]);
      return item.toUpperCase();
    };
    const stage2: Stage<string> = async (prev, item, index) => {
      seen.push([prev, item, index]);
      return `${prev}!`;
    };
    const results = await pipeline(["a", "b"], stage1, stage2);
    expect(results).toEqual(["A!", "B!"]);
    expect(seen).toEqual([
      [undefined, "a", 0],
      [undefined, "b", 1],
      ["A", "a", 0],
      ["B", "b", 1],
    ]);
  });

  test("a failing stage resolves that item null without aborting the others", async () => {
    const results = await pipeline(["a", "b"], async (_prev, item) => {
      if (item === "a") throw new Error("bad a");
      return item.toUpperCase();
    });
    expect(results).toEqual([null, "B"]);
  });
});

// ── Budget ────────────────────────────────────────────────────────────────

describe("Budget", () => {
  test("spent()/remaining()/total arithmetic", () => {
    const b = new Budget({ maxCalls: 3, maxTokens: 1000 });
    expect(b.total).toEqual({ calls: 3, tokens: 1000 });
    expect(b.remaining()).toEqual({ calls: 3, tokens: 1000 });

    b.charge(usage(400));
    expect(b.spent()).toEqual({ calls: 1, tokens: 400 });
    expect(b.remaining()).toEqual({ calls: 2, tokens: 600 });
    expect(b.exhausted()).toBe(false);

    b.charge(usage(700));
    expect(b.spent()).toEqual({ calls: 2, tokens: 1100 });
    expect(b.remaining()).toEqual({ calls: 1, tokens: 0 });
    expect(b.exhausted()).toBe(true); // tokens hit 0 even though a call remains
  });

  test("unset ceilings are unlimited", () => {
    const b = new Budget();
    expect(b.total).toEqual({ calls: Infinity, tokens: Infinity });
    b.charge(usage(1_000_000));
    expect(b.exhausted()).toBe(false);
    expect(b.remaining()).toEqual({ calls: Infinity, tokens: Infinity });
  });
});

// ── Run: budget admission ─────────────────────────────────────────────────

describe("Run budget admission", () => {
  test("exhausted budget stops admitting new agent() calls instead of erroring mid-fan-out", async () => {
    const dir = tmpJournalDir();
    try {
      const runner = new FakeRunner(() => ok("done", 10));
      const run = new Run({ dir, budget: { maxCalls: 2 }, runner });

      const r1 = await run.agent("task 1");
      const r2 = await run.agent("task 2");
      const r3 = await run.agent("task 3");

      expect(r1.ok).toBe(true);
      expect(r2.ok).toBe(true);
      expect(r3.ok).toBe(false);
      expect(r3.text).toMatch(/budget exhausted/i);
      expect(runner.calls.length).toBe(2); // the 3rd call never reached the runner
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("parallel admissions reserve the call budget before runners await", async () => {
    const dir = tmpJournalDir();
    try {
      const runner = new FakeRunner(async () => {
        await sleep(20);
        return ok("done", 10);
      });
      const run = new Run({ dir, budget: { maxCalls: 2 }, runner, concurrency: 3 });
      const results = await run.runParallel([
        () => run.agent("task 1"),
        () => run.agent("task 2"),
        () => run.agent("task 3"),
      ]);
      expect(runner.calls.length).toBe(2);
      expect(results.filter((r) => r && r.ok).length).toBe(2);
      expect(results.filter((r) => r && !r.ok)[0]?.text).toMatch(/budget exhausted/i);
      expect(run.budget.spent()).toEqual({ calls: 2, tokens: 20 });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a runner that throws releases its reservation instead of draining the calls budget", async () => {
    const dir = tmpJournalDir();
    try {
      let fail = true;
      const runner = new FakeRunner(() => {
        if (fail) throw new Error("transport down");
        return ok("recovered", 10);
      });
      const run = new Run({ dir, budget: { maxCalls: 1 }, runner });

      await expect(run.agent("attempt")).rejects.toThrow("transport down");
      // The failed call never ran: nothing spent, and the slot is back — a
      // healthy retry with the same maxCalls:1 ceiling is still admitted.
      expect(run.budget.spent()).toEqual({ calls: 0, tokens: 0 });

      fail = false;
      const retry = await run.agent("attempt");
      expect(retry.ok).toBe(true);
      expect(retry.text).toBe("recovered");
      expect(run.budget.spent()).toEqual({ calls: 1, tokens: 10 });

      // A thrown call is NOT journaled (one record per LIVE call — file
      // header), so a later resume re-runs from the failed key. The single
      // record is the retry at key a1; a0 was consumed by the failed attempt.
      const lines = readFileSync(run.journalPath, "utf8").trim().split("\n");
      expect(lines.length).toBe(1);
      expect(JSON.parse(lines[0]).key).toBe("a1");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("budget-exhaustion results do not share one mutable usage object", async () => {
    const dir = tmpJournalDir();
    try {
      const run = new Run({ dir, budget: { maxCalls: 0 }, runner: new FakeRunner(() => ok("never runs")) });
      const r1 = await run.agent("x");
      const r2 = await run.agent("y");
      expect(r1.ok).toBe(false);
      expect(r2.ok).toBe(false);
      expect(r1.usage).not.toBe(r2.usage);
      r1.usage.contextTokens = 999;
      expect(r2.usage.contextTokens).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// ── Run: journal write/replay + prefix resume ────────────────────────────

describe("Run journal + resume", () => {
  test("a warm, unchanged re-run replays every call from the journal (runner untouched)", async () => {
    const dir = tmpJournalDir();
    try {
      const runner1 = new FakeRunner((spec, n) => ok(`result-${n}:${spec.prompt}`, 5));
      const run1 = new Run({ dir: join(dir, "run1"), runner: runner1 });
      const results1 = [await run1.agent("task A"), await run1.agent("task B"), await run1.agent("task C")];
      expect(runner1.calls.length).toBe(3);
      expect(results1.every((r) => !r.cached)).toBe(true);

      const runner2 = new FakeRunner(() => {
        throw new Error("must not be called on a fully-cached replay");
      });
      const run2 = new Run({ dir: join(dir, "run2"), resumeFrom: run1.journalPath, runner: runner2 });
      const results2 = [await run2.agent("task A"), await run2.agent("task B"), await run2.agent("task C")];

      expect(results2.map((r) => r.text)).toEqual(results1.map((r) => r.text));
      expect(results2.every((r) => r.cached)).toBe(true);
      expect(runner2.calls.length).toBe(0);
      expect(run2.budget.spent()).toEqual({ calls: 0, tokens: 0 }); // replays never charge the budget
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("resume-prefix: a changed call reruns live, and everything after it does too", async () => {
    const dir = tmpJournalDir();
    try {
      const runner1 = new FakeRunner((spec, n) => ok(`v1-${n}:${spec.prompt}`, 5));
      const run1 = new Run({ dir: join(dir, "run1"), runner: runner1 });
      await run1.agent("task A");
      await run1.agent("task B");
      await run1.agent("task C");

      const runner2 = new FakeRunner((spec, n) => ok(`v2-${n}:${spec.prompt}`, 5));
      const run2 = new Run({ dir: join(dir, "run2"), resumeFrom: run1.journalPath, runner: runner2 });
      const rA = await run2.agent("task A"); // identical to run1 -> replayed
      const rB = await run2.agent("task B (changed)"); // diverges here -> live
      const rC = await run2.agent("task C"); // identical to run1, but AFTER the
      // divergence point -> still forced live (true prefix semantics, not
      // plain memoization: a later unchanged call doesn't get a free pass).

      expect(rA.cached).toBe(true);
      expect(rB.cached).toBe(false);
      expect(rC.cached).toBe(false);
      expect(runner2.calls.length).toBe(2); // B and C; A was never re-run
      expect(runner2.calls.map((s) => s.prompt)).toEqual(["task B (changed)", "task C"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("resumeFrom pointing at a nonexistent journal behaves like a fresh live run", async () => {
    const dir = tmpJournalDir();
    try {
      const runner = new FakeRunner((spec) => ok(spec.prompt));
      const run = new Run({ dir, resumeFrom: join(dir, "does-not-exist.jsonl"), runner });
      const r = await run.agent("hello");
      expect(r.cached).toBe(false);
      expect(runner.calls.length).toBe(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// ── agent(): opts passthrough (#276 P0-1/P0-3 surface) ───────────────────

describe("agent() opts passthrough", () => {
  test("isolation, isolationFallback, background, agent persona, and systemPrompt reach the spec", async () => {
    const runner = new FakeRunner((spec) => ok(spec.prompt));
    await agent("do the thing", {
      runner,
      agent: "researcher",
      isolation: "worktree",
      isolationFallback: true,
      background: true,
      systemPrompt: "custom persona text",
    });
    const spec = runner.calls[0];
    expect(spec.agent).toBe("researcher");
    expect(spec.isolation).toBe("worktree");
    expect(spec.isolationFallback).toBe(true);
    expect(spec.background).toBe(true);
    expect(spec.systemPrompt).toBe("custom persona text");
  });

  test("a bare agent() call (no {run}) is not journaled or budgeted", async () => {
    const runner = new FakeRunner((spec) => ok(spec.prompt));
    const r = await agent("one-off", { runner });
    expect(r.cached).toBe(false);
    expect(runner.calls.length).toBe(1);
  });
});

// ── Pure wire-format helpers (exercised without a live process) ─────────

describe("wire-format helpers", () => {
  test("subagentToolInput maps to the exact snake_case subagent tool schema", () => {
    const input = subagentToolInput({
      description: "fix it",
      prompt: "fix the bug",
      agent: "implementer",
      systemPrompt: "be terse",
      isolation: "worktree",
      isolationFallback: true,
      background: true,
    });
    expect(input).toEqual({
      description: "fix it",
      prompt: "fix the bug",
      agent: "implementer",
      system_prompt: "be terse",
      isolation: "worktree",
      isolation_fallback: true,
      run_in_background: true,
    });
  });

  test("subagentToolInput omits optional fields entirely when unset", () => {
    const input = subagentToolInput({ prompt: "just do it" });
    expect(input).toEqual({ description: "just do it", prompt: "just do it" });
  });

  test("parseBackgroundId parses spawnSubBackground's ack text", () => {
    expect(parseBackgroundId("[agent 7 started: fix the bug]\nIt runs in the background across turns...")).toBe(7);
    expect(parseBackgroundId("[agent 42 started: label]")).toBe(42);
    expect(parseBackgroundId("not an ack at all")).toBeNull();
  });

  test("background status distinguishes a pending poll from a terminal result", () => {
    expect(backgroundResultRunning("[agent 7: running]", 7)).toBe(true);
    expect(backgroundResultRunning("[agent 7: completed in 10ms]\n\ndone", 7)).toBe(false);
    expect(backgroundResultRunning("[agent 8: running]", 7)).toBe(false);
  });
});
