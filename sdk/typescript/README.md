# @codegraff/sdk

TypeScript / Node SDK for the [codegraff](https://github.com/justrach/codegraff) agent.

The SDK ships as an N-API native addon (built with [napi-rs](https://napi.rs)) that
embeds the Rust `forge_api::ForgeAPI` directly into your Node process — no
subprocess, no daemon. You drive the agent programmatically and consume its
events as a typed async iterable.

## Status

**Phase 4 — cross-platform prebuilds infrastructure (no publish yet).** The
package is wired up so that, once a maintainer is ready, a single tag push can
publish prebuilt binaries for every supported target. Until then, install
falls back to building from source.

Available surface:

- `Graff.init(cwd?)` — long-lived instance with the conversation / agent / trajectory surface.
- `runAgent({ prompt, cwd?, conversationId?, model? })` — one-shot async iterator.
- `new GraffSession({ cwd?, conversationId?, model? })` — multi-turn class that retains `conversationId` between `.send()` calls.
- Cancellation: `handle.cancel()` aborts the in-flight chat and `for await ... break` does the same automatically.
- Low-level passthroughs: `GraffApi`, `ChatStreamHandle`, `newConversationId()`, `version()`.

## Build from source

```bash
cd sdk/typescript
npm install
npm run build         # produces codegraff-sdk.<triple>.node + index.{js,d.ts}
node -e "console.log(require('./lib.js').version())"
```

Requirements: Rust toolchain (1.92+), Node.js 18+, and a C toolchain
appropriate for your platform.

## Cross-platform builds (CI)

`.github/workflows/sdk-typescript.yml` defines a build matrix that produces a
`.node` binary for each supported target. Today CI builds:

| Triple | Runner | Notes |
|---|---|---|
| `aarch64-apple-darwin` | `macos-latest` | native — Apple Silicon |
| `x86_64-apple-darwin` | `macos-13` | native — Intel Mac |
| `x86_64-unknown-linux-gnu` | `ubuntu-latest` | native |
| `x86_64-pc-windows-msvc` | `windows-latest` | native |

After the matrix completes, an `assemble` job downloads each `bindings-*`
artifact, runs `napi artifacts` to move binaries into the matching
`sdk/typescript/npm/<triple>/` subpackage, and uploads the consolidated tree
as a single `sdk-typescript-npm-packages` artifact for inspection.

**Publish is intentionally not wired up.** The assemble job stops after
producing inspectable artifacts. When we're ready for `0.2.0`, a separate
release workflow will download the assembled artifact, run `napi prepublish`,
and call `npm publish` for each subpackage and the root.

### Triples not yet built in CI

`aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`, and
`aarch64-unknown-linux-musl` are listed in `package.json`'s
`optionalDependencies` for forward compatibility, but require cross-compile
infrastructure (cross / zig / Alpine docker images). For now, users on those
platforms must build from source. Adding them is a follow-up task that
extends the matrix in `.github/workflows/sdk-typescript.yml`.

## Layout

```
sdk/typescript/
├── Cargo.toml             # forge_sdk_node — cdylib napi-rs crate
├── src/lib.rs             # #[napi] bindings → GraffApi, ChatStreamHandle, ...
├── src/wire.rs            # ChatResponse → JSON wire format (auto-fires Notify)
├── lib.js / lib.d.ts      # public TS surface — Graff, GraffSession, runAgent
├── index.js / index.d.ts  # napi-rs auto-generated loader + raw type defs
├── package.json           # @codegraff/sdk — main + optionalDependencies
└── npm/
    ├── darwin-arm64/      # @codegraff/sdk-darwin-arm64
    │   ├── package.json   # os/cpu/libc filters
    │   └── README.md
    ├── darwin-x64/
    ├── linux-x64-gnu/
    ├── linux-arm64-gnu/
    └── win32-x64-msvc/
```

The `npm/<triple>/package.json` files are committed; the `.node` binaries
inside them are not (CI builds them fresh per platform).

## Usage

### One-shot

```ts
import { runAgent } from "@codegraff/sdk";

for await (const ev of runAgent({ prompt: "summarise this repo" })) {
  switch (ev.type) {
    case "TaskMessage":
      if (ev.content.kind === "Markdown") process.stdout.write(ev.content.text);
      break;
    case "ToolCallStart": console.log("→ tool:", ev.tool_call.name); break;
    case "TaskComplete":  console.log("\n[done]"); break;
  }
}
```

### Multi-turn session

```ts
import { GraffSession } from "@codegraff/sdk";

const session = new GraffSession({ model: "claude-opus-4-7" });
for await (const _ of session.send("add a logout button"))   { /* render */ }
for await (const _ of session.send("now write a test for it")) { /* render */ }
console.log("session id:", session.conversationId);
```

### Long-lived Graff instance

```ts
import { Graff } from "@codegraff/sdk";

const graff = await Graff.init();

// Browse history
const recent = await graff.listConversations(20);
const last = await graff.lastConversation();
console.log("most recent:", last?.id);

// Manage agents
console.log("active:", await graff.getActiveAgent());
await graff.setActiveAgent("muse");
const agents = await graff.getAgentInfos();   // [{ id: "forge", ... }, ...]

// Run a chat using this Graff's underlying GraffApi
for await (const ev of graff.chat({ prompt: "write a haiku about rust" })) {
  if (ev.type === "TaskMessage" && ev.content.kind === "Markdown") {
    process.stdout.write(ev.content.text);
  }
}

// Build a session that shares this Graff
const sess = graff.session();
for await (const _ of sess.send("now make it about typescript")) { /* render */ }

// Compact / rename / delete history
await graff.renameConversation(last.id, "haiku experiments");
const compaction = await graff.compactConversation(last.id);
console.log("token reduction:", compaction.original_tokens, "→", compaction.compacted_tokens);
await graff.deleteConversation(last.id);

// Inspect tool-call trajectory (used by /trace in the TUI)
const events = await graff.listTrajectory(sess.conversationId!);
```

### Cancellation

```ts
for await (const ev of graff.chat({ prompt: "long task..." })) {
  if (somethingHappened) break;   // calls handle.cancel() automatically via the async generator's finally
}

// Or explicitly via the low-level handle:
const api = await GraffApi.init(process.cwd());
const handle = await api.chat({ prompt: "..." });
setTimeout(() => handle.cancel(), 5000);
for (let raw = await handle.next(); raw != null; raw = await handle.next()) {
  console.log(JSON.parse(raw));
}
```

## Event shape

```ts
type AgentEvent =
  | { type: "ConversationStarted"; conversationId: string }   // synthetic, surfaced once at start
  | { type: "TaskMessage"; content: { kind: "Markdown" | "ToolInput" | "ToolOutput"; ... } }
  | { type: "TaskReasoning"; content: string }
  | { type: "ToolCallStart"; tool_call: ToolCallFull }
  | { type: "ToolCallEnd";   result: ToolResult }
  | { type: "RetryAttempt";  cause: string; duration_ms: number }
  | { type: "Interrupt";     reason: { kind: "MaxToolFailurePerTurnLimitReached" | "MaxRequestPerTurnLimitReached"; limit: number } }
  | { type: "TaskComplete" };
```

See `lib.d.ts` for the full typed surface.

## Examples

- **`examples/agent-demo.ts`** *(recommended)* — TypeScript multi-turn session that drives the agent through a real exploration of this repo. Run with `npm run demo`. Tool calls fire automatically (auto-approved); the second turn intentionally relies on memory from the first to prove session context retention.
- `examples/smoke.mjs` — single prompt, prints rendered markdown to stdout.
- `examples/session.mjs` — minimal two-turn conversation.

All three require a configured codegraff provider (run `graff provider login`
once in this directory or globally).

## Roadmap

- ✅ **Phase 1** — scaffold, version export, workspace wiring.
- ✅ **Phase 2** — `runAgent()` async iterator, `GraffSession` class, `WireEvent` JSON.
- ✅ **Phase 3** — `Graff` class with conversation / agent / trajectory management; cancellation.
- ✅ **Phase 4** — Cross-platform build matrix in CI, per-triple npm subpackages, `optionalDependencies` wired up.
- **Future** — Publish workflow (gated on a release tag), Linux ARM64 + musl matrix entries via cross-compile, MCP / workspace / commit / suggest surfaces.
