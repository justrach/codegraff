# @codegraff/sdk

TypeScript / Node SDK for the [codegraff](https://github.com/justrach/codegraff)
agent. It drives the `graff` binary over its `--json` stdio protocol, and the
types are auto-generated from `graff --schema`.

## Install

```sh
npm install @codegraff/sdk
```

### Native binary included

npm installs the matching native `graff` executable through an optional platform
package, so a separate CLI install or `PATH` setup is not required on supported
macOS, Linux, and Windows arm64/x64 systems. Provider authentication is still
required through the normal environment variables or `graff login` credentials.

If optional dependencies are disabled, the SDK falls back to `graff` on `PATH`.
Development and custom builds can always set an explicit binary:

```ts
const graff = Harness.init({ binary: "./zig-out/bin/graff" });
```

## Quick start

```ts
import { Harness, runAgent } from "@codegraff/sdk";

// one-shot, streamed
for await (const ev of runAgent({ prompt: "summarize README.md", model: "gpt-5.5", yolo: true })) {
  if (ev.type === "text") process.stdout.write(ev.text);
  if (ev.type === "tool_call") console.log("→", ev.name, ev.input);
  if (ev.type === "turn") console.log("\ncost $", ev.cost_usd);
}

// long-lived, multi-turn session
const harness = Harness.init({ model: "claude-opus-4-8", yolo: true });
const session = harness.session();
console.log(await session.ask("what files are here?")); // returns final text
const result = await session.askResult("summarize the changes");
console.log(result.text, result.inputTokens, result.costUsd);
console.log(await session.review("review HEAD against main")); // isolated + read-only
for await (const ev of session.send("ask me a follow-up before continuing")) {
  if (ev.type === "ask_user") session.answer({ text: "continue", callId: ev.call_id });
}
await session.close();
```

`Harness.init` accepts `{ model, yolo, cwd, env, binary, systemPrompt,
maxToolCalls, maxModelCalls, dedupeToolCalls, args }`.
`model` may be a model name **or** a provider id (e.g. `"codex"`, `"moonshot"`).
Also exported: `MODELS` and `PROVIDERS`.

## Runtime controls and cancellation

Turns and acknowledged controls are serialized per session, so overlapping calls
cannot steal each other's events. `answer()` remains out-of-band so it can answer
an active `ask_user` prompt.

```ts
await session.setModel("codex", "gpt-5.6-luna");
await session.setEffort("high");
await session.compact();

const controller = new AbortController();
const pending = session.ask({ prompt: "long task", signal: controller.signal });
controller.abort(); // interrupts the active model/tool turn
await pending;      // rejects with the terminal cancellation error
```

`askResult()` returns final text plus context, token, cache, cost, and provider-call
usage. `ask()` remains the compatibility shorthand that returns only final text.
The same controls, abort behavior, structured results, and out-of-band answers are
available on `RemoteHarness`.

## Events

Both `runAgent` and `session.send` yield an `AsyncGenerator<Event>`:

- `text` — assistant text delta
- `tool_call` — the agent invoked a tool (`name`, `input`)
- `tool_result` — a tool returned
- `ask_user` — the agent needs input; answer it with `session.answer({ text, callId })`
- `turn` — turn finished; carries the final `text`, `context_tokens`, and `cost_usd`
- `error` — something went wrong

## Remote (edge runtimes)

Edge runtimes can't spawn a subprocess. Run `graff serve` somewhere and drive it
over HTTP with fetch + Web Streams (works on Cloudflare Workers, Deno, Bun,
browsers, Node >= 18):

```ts
import { RemoteHarness, runAgentRemote } from "@codegraff/sdk/remote";

for await (const ev of runAgentRemote({ url: "https://my-bridge.example", token, prompt: "summarize README.md" })) {
  if (ev.type === "text") console.log(ev.text);
}

const h = RemoteHarness.init({ url: "http://127.0.0.1:8787", token, yolo: true });
console.log(await h.ask("what files are here?"));
await h.close();
```

## Orchestration (#276): agent()/parallel()/pipeline(), budgets, resumable runs

`@codegraff/sdk/orchestrate` is a deterministic scripting layer on top of the
harness's `subagent`/`workflow` tools/`agent_output` — instead of asking the
root model to decide, on its own judgement, to fan out, the SDK drives those
tools programmatically:

```ts
import { agent, parallel, pipeline, Run } from "@codegraff/sdk/orchestrate";

// one subagent call
const r = await agent("summarize README.md", { agent: "researcher" });
console.log(r.ok, r.text, r.usage.contextTokens);

// parallel(): explicit barrier, a failed thunk resolves null (never rejects)
const reviews = await parallel([
  () => agent("review auth.ts for bugs", { agent: "reviewer" }),
  () => agent("review db.ts for bugs", { agent: "reviewer" }),
]);

// pipeline(): per-item flow, no barrier between an item's stages -- one
// slow file never blocks another file's later stages
const results = await pipeline(
  ["a.ts", "b.ts"],
  async (_prev, file) => agent(`refactor ${file}`, { isolation: "worktree" }),
  async (prev, file) => agent(`review this diff for ${file}:\n${(prev as any).text}`),
);
```

A `Run` adds a token-aware budget and a JSONL journal + prefix-resume so a
re-invoked script skips unchanged calls and goes live from the first
divergence:

```ts
const run = new Run({ budget: { maxTokens: 200_000 } });
await run.agent("step one");
await run.agent("step two");
console.log(run.budget.spent(), run.budget.remaining());

// later / after a crash: replay unchanged calls, run only what diverged
const resumed = new Run({ resumeFrom: run.journalPath });
await resumed.agent("step one"); // cached, no process spawned
```

See `orchestrate.ts`'s file header for the exact journal format and the
concurrency/determinism guarantees (and their documented edges) for
`parallel()`/`pipeline()`.

## Links

- Repository: <https://github.com/justrach/codegraff>
- This package (npm): <https://www.npmjs.com/package/@codegraff/sdk>
- Python sibling (PyPI): <https://pypi.org/project/codegraff/>

## License

BSD-3-Clause
