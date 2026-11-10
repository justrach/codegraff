import { afterEach, describe, expect, test } from "bun:test";
import {
  RemoteHarness,
  runAgentRemote,
  ServerlessHarness,
  InMemoryWorkspace,
  defineTool,
  createAgentSession,
  runAgentServerless,
  type Event,
} from "./remote.ts";

const originalFetch = globalThis.fetch;
const live: RemoteHarness[] = [];
const enc = new TextEncoder();
type InputEvent = Event extends infer T ? T extends { seq: number } ? Omit<T, "seq"> : never : never;
const line = (event: Event) => enc.encode(`${JSON.stringify(event)}\n`);

class FakeBridge {
  requests: string[] = [];
  bodies: Record<string, unknown>[] = [];
  readerCancels = 0;
  active?: ReadableStreamDefaultController<Uint8Array>;
  seq = 0;

  event(event: InputEvent): Event {
    return { seq: ++this.seq, ...event } as Event;
  }

  stream(events: InputEvent[], keepOpen = true): Response {
    const bridge = this;
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        for (const event of events) controller.enqueue(line(bridge.event(event)));
        if (!keepOpen) controller.close();
      },
      cancel() { bridge.readerCancels += 1; },
    }), { status: 200, headers: { "content-type": "application/x-ndjson" } });
  }

  fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    if (url.pathname === "/v1/sessions") {
      return Response.json({ session_id: "s1", resumed: false, last_seq: 0 });
    }
    if (init?.method === "DELETE") return Response.json({ ok: true });
    const type = String(body.type ?? "reattach");
    this.requests.push(type);
    this.bodies.push(body);
    if (type === "cancel") {
      this.active?.enqueue(line(this.event({ type: "error", message: "turn cancelled" })));
      this.active = undefined;
      return Response.json({ ok: true, type: "cancel" });
    }
    if (type === "answer") {
      this.active?.enqueue(line(this.event({
        type: "turn", text: `answered:${String(body.text)}`, context_tokens: 1,
        cost_usd: 0, input_tokens: 1, uncached_input_tokens: 1,
        cache_read_tokens: 0, output_tokens: 1, api_calls: 1,
        subscription_calls: 0, unpriced_calls: 0, complete: true,
        metadata_complete: true,
      })));
      this.active = undefined;
      return Response.json({ ok: true, type: "answer" });
    }
    if (type === "user" || type === "review") {
      const text = String(body.text);
      if (text === "slow" || text === "ask") {
        const bridge = this;
        return new Response(new ReadableStream<Uint8Array>({
          start(controller) {
            bridge.active = controller;
            controller.enqueue(line(bridge.event(text === "ask"
              ? { type: "ask_user", call_id: "r-ask", question: "continue?", input: {} }
              : { type: "started", provider: "fake", model: "fake" })));
          },
          cancel() { bridge.readerCancels += 1; },
        }), { status: 200 });
      }
      return this.stream([{
        type: "turn", text: `${type}:${text}`, context_tokens: 9,
        cost_usd: 0.1, input_tokens: 5, uncached_input_tokens: 2,
        usage_complete: false, missing_usage_calls: 1, unreported_failed_attempts: 2,
        cache_read_tokens: 3, output_tokens: 4, api_calls: 1,
        subscription_calls: 1, unpriced_calls: 0, complete: true,
        metadata_complete: true,
      }]);
    }
    if (type === "set_model") return String(body.model) === "bad"
      ? this.stream([{ type: "error", message: "bad model" }])
      : this.stream([{
        type: "model", ok: true, provider: String(body.provider), model: String(body.model), context: 100, note: "",
      }]);
    if (type === "set_effort") return this.stream([{
      type: "effort", ok: true, level: String(body.level), applies: true,
    }]);
    if (type === "compact") return this.stream([{ type: "compact", ok: true, chars: 3 }]);
    if (type === "reattach") return this.stream([{
      type: "turn", text: "replayed", context_tokens: 1, cost_usd: 0,
      input_tokens: 1, uncached_input_tokens: 1, cache_read_tokens: 0,
      output_tokens: 1, api_calls: 1, subscription_calls: 0,
      unpriced_calls: 0, complete: true, metadata_complete: true,
    }], false);
    throw new Error(`unexpected request ${type}`);
  };
}

const use = (bridge: FakeBridge) => {
  globalThis.fetch = bridge.fetch as typeof fetch;
  const h = new RemoteHarness({ url: "http://bridge.test" });
  live.push(h);
  return h;
};

const waitFor = async (predicate: () => boolean) => {
  for (let i = 0; i < 100 && !predicate(); i += 1) await Bun.sleep(5);
  if (!predicate()) throw new Error("condition timed out");
};

afterEach(async () => {
  for (const value of live.splice(0)) await value.close();
  globalThis.fetch = originalFetch;
});

describe("RemoteHarness transport", () => {
  test("serializes turns and controls and releases terminal response readers", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    const turn = h.askResult("one");
    const model = h.setModel("codex", "gpt-test");
    const effort = h.setEffort("xhigh");
    const compact = h.compact();
    const result = await turn;
    await Promise.all([model, effort, compact]);

    expect(result.text).toBe("user:one");
    expect(result.cacheReadTokens).toBe(3);
    expect(result.usageComplete).toBe(false);
    expect(result.missingUsageCalls).toBe(1);
    expect(result.unreportedFailedAttempts).toBe(2);
    expect(bridge.requests.slice(0, 4)).toEqual(["user", "set_model", "set_effort", "compact"]);
    expect(bridge.readerCancels).toBeGreaterThanOrEqual(4);
  });

  test("a failed control does not poison the operation queue", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    await expect(h.setModel("codex", "bad")).rejects.toThrow("bad model");
    expect(await h.ask("after-error")).toBe("user:after-error");
  });

  test("serializes URL and base64 images as native protocol parts", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    expect(await h.ask({
      prompt: "read the code",
      images: [
        { type: "image_url", url: "https://images.test/code.png" },
        { type: "image_base64", mediaType: "image/png", data: "aGVsbG8=" },
      ],
    })).toBe("user:read the code");
    expect(bridge.bodies.find((body) => body.type === "user")?.images).toEqual([
      { type: "image_url", url: "https://images.test/code.png" },
      { type: "image_base64", media_type: "image/png", data: "aGVsbG8=" },
    ]);
  });

  test("one-shot runAgentRemote preserves native image parts", async () => {
    const bridge = new FakeBridge();
    globalThis.fetch = bridge.fetch as typeof fetch;
    for await (const _event of runAgentRemote({
      url: "http://bridge.test",
      prompt: "read the code",
      images: [{ type: "image_url", url: "https://images.test/one-shot.png" }],
    })) {}
    expect(bridge.bodies.find((body) => body.type === "user")?.images).toEqual([
      { type: "image_url", url: "https://images.test/one-shot.png" },
    ]);
  });

  test("AbortSignal sends an out-of-band cancel and later turns still work", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    const controller = new AbortController();
    const pending = h.ask({ prompt: "slow", signal: controller.signal });
    await waitFor(() => bridge.requests.includes("user"));
    controller.abort();
    await expect(pending).rejects.toThrow("turn cancelled");
    expect(bridge.requests).toContain("cancel");
    expect(await h.ask("after")).toBe("user:after");
  });

  test("answer bypasses the active ask_user stream", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    let final = "";
    for await (const event of h.chat("ask")) {
      if (event.type === "ask_user") await h.answer({ text: "yes", callId: event.call_id });
      if (event.type === "turn") final = event.text;
    }
    expect(final).toBe("answered:yes");
  });

  test("reconnect replays from the requested sequence and updates lastSeq", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    const events = [];
    for await (const event of h.reconnect(7)) events.push(event);
    expect(events.at(-1)?.type).toBe("turn");
    expect(h.lastSeq).toBeGreaterThan(0);
    expect(bridge.requests).toContain("reattach");
  });

  test("constructor observes create rejection even when the caller never awaits it", async () => {
    let unhandled = 0;
    const listener = () => { unhandled += 1; };
    process.on("unhandledRejection", listener);
    globalThis.fetch = (async () => { throw new Error("create failed"); }) as unknown as typeof fetch;
    const h = new RemoteHarness({ url: "http://bridge.test" });
    live.push(h);
    await Bun.sleep(30);
    // Current @types/node overloads collapse off/removeListener to memoryPressure.
    (process as NodeJS.EventEmitter).removeListener("unhandledRejection", listener);
    expect(unhandled).toBe(0);
    await expect(h.sessionId).rejects.toThrow("create failed");
  });
});

describe("ServerlessHarness & InMemoryWorkspace", () => {
  test("InMemoryWorkspace supports read, write, edit, grep, diff, and snapshot", async () => {
    const ws = new InMemoryWorkspace({
      "src/math.ts": "export const add = (a: number, b: number) => a - b;\n",
      "README.md": "# Math\n",
    });
    const base = ws.snapshot();
    expect(await ws.listFiles("src")).toEqual(["src/math.ts"]);
    ws.writeFile("src/mul.ts", "export const mul = (a: number, b: number) => a * b;\n");
    ws.deleteFile("README.md");
    expect(ws.diff(base)).toEqual([
      { path: "README.md", status: "deleted" },
      { path: "src/mul.ts", status: "added" },
    ]);
  });

  test("executes coding tools and custom defineTool across multi-step turns", async () => {
    const { harness, workspace } = createAgentSession({
      workspace: {
        "src/calc.ts": "export function calc(x: number) {\n  return x - 1;\n}\n",
      },
      tools: [
        defineTool({
          name: "check_math",
          description: "Verify arithmetic",
          parameters: { type: "object", properties: { expr: { type: "string" } }, required: ["expr"] },
          execute: (input) => `verified:${String(input.expr)}`,
        }),
      ],
      streamFn: async (req) => {
        const last = req.messages.at(-1);
        if (last?.role === "user") {
          return {
            text: "Inspecting and fixing calc.ts",
            toolCalls: [
              { id: "c1", name: "read_file", input: { path: "src/calc.ts" } },
              {
                id: "c2",
                name: "edit_file",
                input: { path: "src/calc.ts", old_str: "return x - 1;", new_str: "return x + 1;" },
              },
              { id: "c3", name: "check_math", input: { expr: "1+1=2" } },
            ],
            inputTokens: 20,
            outputTokens: 10,
          };
        }
        return {
          text: "Fixed calc.ts and verified math.",
          inputTokens: 30,
          outputTokens: 12,
        };
      },
    });

    const res = await harness.askResult("Fix the bug in src/calc.ts");
    expect(res.text).toBe("Fixed calc.ts and verified math.");
    expect(res.apiCalls).toBe(2);
    expect(res.inputTokens).toBe(50);
    expect(await workspace.readFile("src/calc.ts")).toContain("return x + 1;");
  });

  test("supports beforeToolCall gating/rewriting, afterToolCall, steer, and followUp", async () => {
    const h = new ServerlessHarness({
      workspace: { "notes.txt": "hello\n" },
      beforeToolCall: ({ name, input }) => {
        if (name === "write_file" && String(input.path) === "secret.txt") {
          return { block: true, reason: "cannot write secret.txt" };
        }
        return undefined;
      },
      afterToolCall: ({ name, output }) => {
        if (name === "read_file") return { output: `${output}\n[audited]` };
        return undefined;
      },
      streamFn: async (req) => {
        const userContents = req.messages.filter((m) => m.role === "user").map((m) => m.content);
        if (req.messages.length === 1) {
          h.steer("also remember steer-note");
          h.followUp("now summarize");
          return {
            text: "",
            toolCalls: [
              { id: "t1", name: "write_file", input: { path: "secret.txt", content: "nope" } },
              { id: "t2", name: "read_file", input: { path: "notes.txt" } },
            ],
          };
        }
        if (!userContents.includes("now summarize")) {
          return { text: `step2 saw steer=${userContents.includes("also remember steer-note")}` };
        }
        return { text: "final summary complete" };
      },
    });

    const events: Event[] = [];
    for await (const ev of h.chat("start")) events.push(ev);
    expect(events.some((e) => e.type === "tool_rejected" && e.reason === "policy")).toBe(true);
    expect(events.some((e) => e.type === "tool_result" && e.text.includes("[audited]"))).toBe(true);
    const turn = events.find((e) => e.type === "turn");
    expect(turn && turn.type === "turn" ? turn.text : "").toBe("final summary complete");
  });

  test("review runs in read-only isolation and exportState/fromState round-trips", async () => {
    const h1 = new ServerlessHarness({
      workspace: { "a.txt": "alpha" },
      streamFn: async (req) => {
        const toolNames = req.tools.map((t) => t.name);
        return { text: `tools:${toolNames.join(",")}` };
      },
    });
    await h1.ask("turn 1");
    const reviewReport = await h1.review("audit");
    expect(reviewReport).toBe("tools:read_file,list_dir,grep");
    // Review turn must not pollute conversation history.
    expect(h1.getMessages().length).toBe(2);

    const snap = h1.exportState();
    const h2 = ServerlessHarness.fromState(snap, {
      streamFn: async (req) => ({ text: `resumed with ${req.messages.length} msgs` }),
    });
    expect(await h2.ask("turn 2")).toBe("resumed with 3 msgs");
    await h2.compact();
    expect(h2.getMessages().length).toBeLessThanOrEqual(3);
  });

  test("runAgentServerless works with OpenAI-compatible HTTP endpoints over fetch", async () => {
    globalThis.fetch = (async () =>
      Response.json({
        choices: [{ message: { content: "edge ok", tool_calls: [] } }],
        usage: { prompt_tokens: 11, completion_tokens: 4, prompt_tokens_details: { cached_tokens: 3 } },
      })) as unknown as typeof fetch;

    const events: Event[] = [];
    for await (const ev of runAgentServerless({
      provider: "openai",
      model: "gpt-5.4",
      endpoint: "https://api.example.test/v1",
      apiKey: "sk-test",
      prompt: "ping",
    })) {
      events.push(ev);
    }
    const turn = events.find((e) => e.type === "turn");
    expect(turn && turn.type === "turn" ? turn.text : "").toBe("edge ok");
    expect(turn && turn.type === "turn" ? turn.cache_read_tokens : 0).toBe(3);
  });
});
