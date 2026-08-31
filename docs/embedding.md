# Embedding graff

graff is a subprocess a host spawns, not a library you link and not a WASM
runtime. Two stdio APIs cover a hosted agent. Pick one; do not speak both on
the same child.

| Host API | Wire | When |
|---|---|---|
| `graff acp` | ACP v1 JSON-RPC, one message per line | The host wants thought / tool / text `session/update`s (Zed, a product UI) |
| `@codegraff/sdk` `Harness` | `graff --json` — JSON requests in, JSONL events out | The host wants our event types (`text`, `tool_call`, `turn`, …) |

The real ACP host in this repo is [`apps/native`](../apps/native): Next.js
`/api/acp` → `graff acp --yolo`. Mid-turn updates map onto thinking and tool
chips (ADR [0032](adr/0032-acp-streams-mid-turn.md)). `graff serve` is not
required.

Methods and shapes below are what `src/acp.zig` / `src/acp_protocol.zig`
actually implement. `session/load` and `session/request_permission` are not
implemented; unattended + `--yolo` is how a host that wants tools from the
first call runs the agent.

## `graff acp`

JSON-RPC 2.0 on stdio. The host is the client; graff is the agent. Protocol
version is **1** (Zed; we speak [v1 session/update](https://agentclientprotocol.com/protocol/v1/tool-calls)
shapes, not v2 upserts). Handshake, then one prompt:

```
initialize  →  { protocolVersion, agentCapabilities, agentImplementation }
session/new →  { sessionId }  then a session/update (available_commands_update)
session/prompt →  session/update*  then  { stopReason }
```

`initialize` params: `{ protocolVersion: 1, clientCapabilities: { fs: {} } }`.
Negotiated version is `min(client, 1)`. Capabilities today:
`loadSession: false`, `promptCapabilities: { image: false, audio: false,
embeddedContext: true }`.

`session/new` params may include `cwd`. After the result, the agent advertises
`/never` and `/constraint` via `available_commands_update`.

`session/prompt` params: `{ sessionId, prompt: [{ type: "text", text }] }`.
`flattenPrompt` also lifts `resource_link` blocks. Mid-turn stdout is
`session/update` notifications, then the prompt result:

| `update.sessionUpdate` | Content |
|---|---|
| `agent_thought_chunk` | `{ content: { type: "text", text } }` |
| `agent_message_chunk` | same |
| `tool_call` | `{ toolCallId, title, kind, status, rawInput }` |
| `tool_call_update` | `{ toolCallId, status, content }` |
| `available_commands_update` | `{ availableCommands }` (after `session/new`) |

`stopReason` is `end_turn`, `cancelled` (Esc / `session/cancel`), or
`max_turn_requests` (run budget). A stub turn that emitted no events still
writes one final `agent_message_chunk` (the v0 contract). A live turn that
already streamed text does not duplicate it.

`session/cancel` sets the Esc latch. It may be a request or a notification.
`set_model` is not an ACP method; a model change respawns the child.

### Node recipe

About twenty lines: spawn, write one JSON-RPC object per stdin line, read
stdout the same way. Notifications (`session/update`) arrive before the
`session/prompt` result.

```js
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const child = spawn("graff", ["acp", "--yolo"], { stdio: ["pipe", "pipe", "inherit"] });
const pending = new Map();
let id = 1;
createInterface({ input: child.stdout }).on("line", (line) => {
  const msg = JSON.parse(line);
  if (msg.method === "session/update") return console.log(msg.params.update);
  const wait = pending.get(msg.id);
  if (wait) { pending.delete(msg.id); msg.error ? wait.reject(msg.error) : wait.resolve(msg.result); }
});
const rpc = (method, params) => new Promise((resolve, reject) => {
  pending.set(id, { resolve, reject });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  id += 1;
});

await rpc("initialize", { protocolVersion: 1, clientCapabilities: { fs: {} } });
const { sessionId } = await rpc("session/new", { cwd: process.cwd() });
await rpc("session/prompt", { sessionId, prompt: [{ type: "text", text: "hello" }] });
```

`@codegraff/sdk/acp` is that spawn plus `request` / `notify` / `prompt`
(`spawnAcp()`, or `acp()` which also runs the handshake).

## `@codegraff/sdk` — `graff --json`

When the host wants graff's JSONL events instead of ACP, spawn through
`Harness` (local) or `RemoteHarness` (`graff serve` over HTTP). Same agent
loop; different framing. See [`sdk/ts/README.md`](../sdk/ts/README.md).

```ts
import { Harness } from "@codegraff/sdk";

const session = Harness.init({ yolo: true, model: "gpt-5.5" }).session();
console.log(await session.ask("what files are here?"));
console.log(await session.ask({
  prompt: "read the code in this image",
  images: [{ type: "image_url", url: "https://example.com/code.png" }],
}));
await session.close();
```

The same `images` option works through edge-safe `RemoteHarness`: HTTP(S)
URLs and base64 payloads stay native vision parts across `graff serve` rather
than being flattened into prompt text.

## Embedder mode

A hosted product that must not exec on the host machine already has a gate:
`--no-local-tools` / `GRAFF_NO_LOCAL_TOOLS=1`. That hard-disables `bash`,
`read_file` / `edit_file` / `write_file`, and `codedb` for the process
(advertised off, dispatch refuses a hallucination). MCP tools are untouched,
so a trusted host maps exec/read/write onto its own sandbox. Works with both
`graff acp` and `graff --json`. `--yolo` does not lift the gate.

```bash
graff acp --yolo --no-local-tools --model gpt-5.5
graff --json --no-local-tools --model gpt-5.5
```

The same `graff acp` spawn is what a registry listing would run
(`args: ["acp"]`). Listing itself is the other-repo recipe in
[acp-registry.md](acp-registry.md) (#613); this page does not grow a
registry client.

## License

codegraff is **Modified AGPLv3** ([`LICENSE`](../LICENSE)): a hosted or SaaS
embed is a legal event (AGPL §13) unless both authors grant a separate
written permission.

## In-process (`createGraffAgent`)

fx-shaped same-process embed (ADR [0038](adr/0038-in-process-acp-core.md)).
The host loads `graff-core.wasm` (or links `libgraff`) and speaks ACP over
in-memory slots — no child process.

```ts
import { graffAgent } from "@codegraff/sdk/embed";

const agent = await graffAgent({ wasm: "./graff-core.wasm", cwd: process.cwd() });
const { stopReason, updates } = await agent.prompt("hello");
```

Build the artifacts on this branch:

```
zig build wasm-core    # zig-out/bin/graff-core.wasm
zig build libgraff     # zig-out/lib/libgraff.so (C ABI)
```

`createGraffAgent()` is the JS host. The first-slice turn is `echo:` —
protocol + handshake in-process. Live tools / TLS / bash still go through
`graff acp` (above). A host-imported model turn is the next slice.

C ABI (wasm exports and the shared library):

| export | role |
|---|---|
| `graff_acp_create(seed)` | reset session |
| `graff_acp_in_ptr` / `in_cap` | write one JSON-RPC line |
| `graff_acp_feed(len)` | dispatch |
| `graff_acp_out_ptr` / `out_len` / `out_consume` | read newline-framed replies |

## Not this

No full-agent `fx-core.wasm` (HTTP + bash + git inside the isolate). No
Node-API addon yet — `libgraff` is a C ABI, not a `.node`. Those stay a
later slice on this continuation branch.
