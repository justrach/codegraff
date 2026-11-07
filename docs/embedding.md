# Embedding graff

Graff supports native subprocess hosting and an experimental Worker-native
Zig/Wasm host. Two stdio APIs cover a native hosted agent. Pick one; do not
speak both on the same child. The Worker-native host is described separately
below and does not provide full native CLI parity.

| Host API | Wire | When |
|---|---|---|
| `graff acp` | ACP v1 JSON-RPC, one message per line | The host wants thought / tool / text `session/update`s (Zed, a product UI) |
| `@codegraff/sdk` `Harness` | `graff --json` — JSON requests in, JSONL events out | The host wants our event types (`text`, `tool_call`, `turn`, …) |

The desktop ACP host is [Harness](https://github.com/justrach/harness), which
spawns `graff acp`. Mid-turn updates map onto thinking and tool
chips (ADR [0032](adr/0032-acp-streams-mid-turn.md)). `graff serve` is not
required.

Methods and shapes below are what `src/acp.zig` / `src/acp_protocol.zig`
actually implement. Live agents support `session/load` for saved conversations
and send `session/request_permission` when tool approval is required. Unattended
hosts may use `--yolo`; interactive hosts must answer permission requests.
See [client behavior and limits](acp-client-parity.md).

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
`loadSession: true` for the authenticated live CLI (`false` for the in-process
embed and pre-auth startup), `promptCapabilities: { image: false, audio: false,
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
written permission. From the release after v0.0.302.22, an organization that
has raised more than US$500k, is worth more than US$500k, or earns more than
US$100k a year needs a commercial license for any use, embedding included
(contact rach@standardharness.com).

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
`graff acp` (above). The experimental Worker host below adds model/tool turns
through a separate ABI; this ACP surface remains echo-only.

C ABI (wasm exports and the shared library):

| export | role |
|---|---|
| `graff_acp_create(seed)` | reset session |
| `graff_acp_in_ptr` / `in_cap` | write one JSON-RPC line |
| `graff_acp_feed(len)` | dispatch |
| `graff_acp_out_ptr` / `out_len` / `out_consume` | read newline-framed replies |

## Experimental Worker-native turns

`zig build wasm-worker` builds `zig-out/bin/graff-worker.wasm`.
`@codegraff/sdk/worker` provides a fetch-only JSPI host for a statically bundled
`WebAssembly.Module`. Zig owns conversation history and executes the same chat
step as the native REPL and ACP paths; JavaScript supplies HTTP and registered,
input-validated tools. Credentials stay outside Wasm. No native proxy is used.

The first slice supports nonstreaming Chat Completions and host tools. It is
not the complete native `Agent`: native shell/git, persistent sessions,
compaction, goals and other CLI features are not yet portable. Create one
instance per request or serialize a session's turns; recreate after failures
rather than replaying uncertain effects.

See [the cf/workerd example](../examples/workers-engine/README.md) for setup,
the real model/tool/model runtime test, authentication and deployment dry-run.
The Wasm artifact is built separately; it is not fetched or compiled dynamically
inside Workers, and is not included in the existing `core.wasm` package export.

### Existing Codegraff sandboxes

`@codegraff/sdk/worker-sandbox` is a fetch-only client for Codegraff's hosted VMs.
The [Durable Object sandbox example](../examples/workers-sandbox/README.md)
keeps the agent in Zig/Wasm and delegates shell execution to a disposable VM.
Its opt-in live test uses real inference, independently checks a Python repair,
and requires VM deletion. A DO records cleanup ownership and coordinates the
task; it does not itself become a Linux process environment. Credentials remain
outside Wasm and the VM. This is separate from the local `graff mcp serve`
`run_task` endpoint, which may not have sandbox execution permission.

## Durability and shared observability

The [managed SDK](../sdk/ts/MANAGED.md) is a separate native-device transport:
its receipt/cursor reconnects replay the device's event tape and completed
conversation checkpoints. The Worker-native sandbox example instead persists
cleanup ownership; it does not yet checkpoint or resume a conversation.

Both SDK hosts accept the same optional metadata-only observer from
`@codegraff/sdk/otel`. Export is explicitly flushed by the host, and observer
failure cannot fail or hold execution open. Tracing is not a checkpoint or an
exactly-once guarantee. Custom integrations: **rach@standardharness.com**.

## Not this

No full CLI with bash + git inside the isolate, and no Node-API addon yet —
`libgraff` is a C ABI, not a `.node`. The existing subprocess and remote-bridge
recipes remain distinct from the experimental Worker-native host.
