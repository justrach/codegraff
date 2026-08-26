import { afterEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { Harness, runAgent } from "./harness.ts";

const binary = join(import.meta.dir, "test-fixtures", "fake-graff.mjs");
const live: Harness[] = [];
const harness = () => {
  const value = new Harness({ binary, env: { ...process.env, GRAFF_NO_TELEMETRY: "1" } });
  live.push(value);
  return value;
};

const deadline = <T>(promise: Promise<T>, ms = 2_000): Promise<T> => Promise.race([
  promise,
  new Promise<T>((_, reject) => setTimeout(() => reject(new Error("test timed out")), ms)),
]);

afterEach(async () => {
  await Promise.all(live.splice(0).map((value) => value.close()));
});

describe("Harness transport", () => {
  test("serializes overlapping turns and controls without event theft", async () => {
    const h = harness();
    const first = h.ask("one");
    const model = h.setModel("codex", "gpt-test");
    const effort = h.setEffort("high");
    const compact = h.compact();
    const second = h.ask("two");

    expect(await deadline(first)).toBe("user:one");
    await deadline(Promise.all([model, effort, compact]));
    expect(await deadline(second)).toBe("user:two");
  });

  test("a failed control does not poison the operation queue", async () => {
    const h = harness();
    await expect(h.setModel("codex", "bad")).rejects.toThrow("bad model");
    expect(await deadline(h.ask("after-error"))).toBe("user:after-error");
  });

  test("returns structured turn usage while ask remains string-compatible", async () => {
    const h = harness();
    const result = await h.askResult("usage");
    expect(result).toEqual({
      text: "user:usage",
      contextTokens: 42,
      costUsd: 0.012,
      inputTokens: 10,
      uncachedInputTokens: 4,
      cacheReadTokens: 6,
      outputTokens: 3,
      apiCalls: 2,
      subscriptionCalls: 1,
      unpricedCalls: 0,
      complete: true,
      metadataComplete: true,
    });
    expect(await h.ask("plain")).toBe("user:plain");
  });

  test("serializes native URL and base64 image parts", async () => {
    const h = harness();
    const result = await h.ask({
      prompt: "images",
      images: [
        { type: "image_url", url: "https://images.test/code.png" },
        { type: "image_base64", mediaType: "image/png", data: "aGVsbG8=" },
      ],
    });
    expect(JSON.parse(result)).toEqual([
      { type: "image_url", url: "https://images.test/code.png" },
      { type: "image_base64", media_type: "image/png", data: "aGVsbG8=" },
    ]);
  });

  test("one-shot runAgent preserves native image parts", async () => {
    let result = "";
    for await (const event of runAgent({
      binary,
      env: { ...process.env, GRAFF_NO_TELEMETRY: "1" },
      prompt: "images",
      images: [{ type: "image_url", url: "https://images.test/one-shot.png" }],
    })) {
      if (event.type === "turn") result = event.text;
    }
    expect(JSON.parse(result)).toEqual([
      { type: "image_url", url: "https://images.test/one-shot.png" },
    ]);
  });

  test("answer bypasses the operation lock during ask_user", async () => {
    const h = harness();
    let final = "";
    for await (const event of h.chat("ask")) {
      if (event.type === "ask_user") h.answer({ text: "yes", callId: event.call_id });
      if (event.type === "turn") final = event.text;
    }
    expect(final).toBe("answered:yes");
  });

  test("AbortSignal cancels an active turn and leaves the session usable", async () => {
    const h = harness();
    const controller = new AbortController();
    const pending = h.ask({ prompt: "slow", signal: controller.signal });
    setTimeout(() => controller.abort(), 20);
    await expect(deadline(pending)).rejects.toThrow("turn cancelled");
    expect(await deadline(h.ask("after"))).toBe("user:after");
  });

  test("child death rejects instead of hanging and does not poison other instances", async () => {
    const dead = harness();
    await expect(deadline(dead.ask("die"))).rejects.toThrow("exited mid-turn");
    const healthy = harness();
    expect(await deadline(healthy.ask("healthy"))).toBe("user:healthy");
  });
});
