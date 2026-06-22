# subagent sa-003-ca4e54cc

- label: Explore SDK packages
- kind: workflow_task
- status: ok
- elapsed_ms: 60452
- tools: codedb,read_file,read_file,read_file,read_file,read_file,read_file,read_file,read_file,codedb,codedb,read_file,read_file,codedb,codedb,codedb,read_file,read_file,read_file

## task

You are exploring the SDK packages in sdk/. Use the codedb tool (search, symbol, outline, callers, context) to thoroughly understand:
1. The Python SDK (sdk/py/harness_sdk.py, demo.py) — what it does, its API, how it communicates with the harness
2. The TypeScript SDK (sdk/ts/harness.ts, remote.ts) — what it does, its API, how it communicates
3. The SDK generation script (sdk/generate.py) — what does it generate and from what
4. How the SDKs relate to the broader project (are they clients for the core Zig server?)

Be thorough and return a structured markdown report.

## report

# SDK Analysis Report — `sdk/` directory

## 1. Python SDK (`sdk/py/`)

### What it does
The Python SDK provides two transport variants for driving the harness agent:

- **`Harness`** — spawns a local `graff --json` (or `harness --json`) subprocess and speaks the JSONL stdio protocol directly.
- **`RemoteHarness`** — connects to a remote `harness serve` bridge over HTTP and exposes the same method surface (`sdk/py/harness_sdk.py:306-432`).

Both classes are context managers (`__enter__`/`__exit__`) and support multi-turn stateful conversations, system-prompt mutation, evaluation scoring for the DGM loop, and OTLP telemetry reporting.

### API surface
| Method | Purpose | File:Line |
|--------|---------|-----------|
| `Harness(...)` | Spawn subprocess with `--json`, optional `--yolo`, `--model`, `--system-prompt`, `--append-system-prompt` | `sdk/py/harness_sdk.py:148-180` |
| `Harness.chat(text)` | Send a user turn; yield NDJSON events (`text`, `tool_call`, `tool_result`, `turn`, `error`) until terminal | `sdk/py/harness_sdk.py:182-207` |
| `Harness.ask(text)` | One-shot: run a turn and return just the final assistant text | `sdk/py/harness_sdk.py:209-217` |
| `Harness.answer(...)` | Reply to an in-flight `ask_user` tool call while consuming `chat()` | `sdk/py/harness_sdk.py:219-228` |
| `Harness.set_system_prompt(text, append=False)` | Replace or extend the system prompt between turns; blocks on harness ack | `sdk/py/harness_sdk.py:230-255` |
| `Harness.append_system_prompt(text)` | Convenience wrapper for `set_system_prompt(..., append=True)` | `sdk/py/harness_sdk.py:257-259` |
| `Harness.score(...)` | Write a DGM evaluation record into `harness.trajectory.jsonl` with optional HMAC provenance | `sdk/py/harness_sdk.py:261-298` |
| `Harness.pull_elites(...)` | GET `/v1/elites` from the telemetry collector (not the subprocess) | `sdk/py/harness_sdk.py:300-323` |
| `Harness.close()` | Close stdin, wait up to 15 s for graceful exit, then terminate | `sdk/py/harness_sdk.py:325-336` |
| `RemoteHarness(...)` | Create or attach to a remote session via `POST /v1/sessions` | `sdk/py/harness_sdk.py:343-360` |
| `RemoteHarness.chat(text)` | Stream NDJSON events from the bridge | `sdk/py/harness_sdk.py:380-393` |
| `RemoteHarness.ask(text)` | One-shot remote turn | `sdk/py/harness_sdk.py:395-403` |
| `RemoteHarness.answer(...)` | POST an answer to the bridge | `sdk/py/harness_sdk.py:405-413` |
| `RemoteHarness.set_system_prompt(...)` | Mutate prompt remotely | `sdk/py/harness_sdk.py:415-427` |
| `RemoteHarness.score(...)` | Write score remotely | `sdk/py/harness_sdk.py:429-445` |
| `RemoteHarness.close()` | DELETE the remote session | `sdk/py/harness_sdk.py:452-457` |

Free functions:
- `prompt_fingerprint(text)` → SHA-256 first 8 bytes hex (`sdk/py/harness_sdk.py:103-107`)
- `score_signature(key, ...)` → HMAC of a score record (`sdk/py/harness_sdk.py:109-122`)
- `verify_score(key, rec)` → boolean validity check (`sdk/py/harness_sdk.py:124-137`)

### How it communicates
**Local (`Harness`):** Uses `subprocess.Popen` with `stdin=subprocess.PIPE, stdout=subprocess.PIPE` (`sdk/py/harness_sdk.py:175`). The parent writes one JSON object per line to stdin (`{"type":"user","text":"..."}`) and reads NDJSON events from stdout. If the process exits mid-turn without emitting `turn` or `error`, the SDK reports an error to OTLP telemetry and raises `RuntimeError` (`sdk/py/harness_sdk.py:205-207`).

**Remote (`RemoteHarness`):** Uses stdlib `urllib.request` only—no external dependencies. It POSTs to `/v1/sessions` to create a session, then POSTs subsequent requests to `/v1/sessions/{session_id}` and yields NDJSON lines from the response body (`sdk/py/harness_sdk.py:362-378`). Authentication is via an optional `Authorization: Bearer <token>` header (`sdk/py/harness_sdk.py:365-367`).

**Demo:** `sdk/py/demo.py` demonstrates one-shot `ask()`, streamed `chat()` with live tool use, multi-turn persistence, custom prompts via `AGENTS.md` in `cwd`, and full `system_prompt=` replacement (`sdk/py/demo.py:1-110`).

---

## 2. TypeScript SDK (`sdk/ts/`)

### What it does
The TypeScript SDK mirrors the Python SDK but splits into two entry points:

- **`harness.ts`** — Node.js-only client using `node:child_process` and `node:readline` to spawn the local binary.
- **`remote.ts`** — Edge-runtime client using only `fetch` + Web Streams (no `node:` imports), runnable on Cloudflare Workers, Deno, Bun, browsers, and Node ≥ 18 (`sdk/ts/remote.ts:1-10`).

Both expose identical event types (`Event` union), `ModelName`, `ToolName`, and `ProviderId` unions, plus `promptFingerprint`, `fleetSignal`, and `pullElites` helpers.

### API surface
| Export | Kind | Purpose | File:Line |
|--------|------|---------|-----------|
| `Harness` | class | Node stdio subprocess client | `sdk/ts/harness.ts:157-267` |
| `Harness.init(opts)` | static | Factory alias for `new Harness(opts)` | `sdk/ts/harness.ts:172` |
| `Harness.chat(input)` | async generator | Stream events until `turn`/`error` | `sdk/ts/harness.ts:189-205` |
| `Harness.ask(input)` | async | Return final assistant text | `sdk/ts/harness.ts:207-215` |
| `Harness.answer(input)` | method | Write answer to stdin for `ask_user` | `sdk/ts/harness.ts:217-223` |
| `Harness.setSystemPrompt(text, append)` | async | Replace/extend prompt; resolves on ack | `sdk/ts/harness.ts:225-238` |
| `Harness.score(...)` | async | Write DGM score record | `sdk/ts/harness.ts:248-261` |
| `Harness.pullElites(...)` | async | GET `/v1/elites` from collector | `sdk/ts/harness.ts:263-281` |
| `Harness.session()` | method | Return `HarnessSession` wrapper | `sdk/ts/harness.ts:287` |
| `HarnessSession` | class | Thin wrapper over `Harness` for parity with codegraff’s `GraffSession` | `sdk/ts/harness.ts:291-301` |
| `runAgent(opts)` | async generator | One-shot: spawn, chat, close | `sdk/ts/harness.ts:305-312` |
| `RemoteHarness` | class | Fetch-based remote bridge client | `sdk/ts/remote.ts:73-181` |
| `RemoteHarness.init(opts)` | static | Factory | `sdk/ts/remote.ts:85` |
| `RemoteHarness.chat(input)` | async generator | Stream NDJSON from bridge | `sdk/ts/remote.ts:127-140` |
| `RemoteHarness.ask(input)` | async | One-shot remote | `sdk/ts/remote.ts:142-150` |
| `RemoteHarness.answer(...)` | async | POST answer to bridge | `sdk/ts/remote.ts:152-163` |
| `RemoteHarness.setSystemPrompt(...)` | async | Remote prompt mutation | `sdk/ts/remote.ts:165-174` |
| `RemoteHarness.score(...)` | async | Remote score write | `sdk/ts/remote.ts:176-188` |
| `runAgentRemote(opts)` | async generator | One-shot remote | `sdk/ts/remote.ts:193-200` |

### How it communicates
**Local (`harness.ts`):** Spawns `opts.binary ?? defaultBinary()` with `spawnArgs(opts)` (always includes `--json`). Stderr is inherited (`stdio: ["pipe", "pipe", "inherit"]`) so tool progress prints directly to the terminal (`sdk/ts/harness.ts:165-167`). A `readline.Interface` pumps stdout line-by-line into an internal queue/buffer. If the process errors or closes before a terminal event, `reportError` fires OTLP telemetry and the waiting promise rejects (`sdk/ts/harness.ts:180-184`).

**Remote (`remote.ts`):** Uses `fetch` exclusively. `create()` POSTs to `/v1/sessions` with `{model?, yolo?, system_prompt?, append_system_prompt?}` and stores the returned `session_id` (`sdk/ts/remote.ts:95-110`). Every turn POSTs to `/v1/sessions/{id}` and the response body is parsed via `ndjson()`, a Web-Streams reader that yields parsed JSON lines (`sdk/ts/remote.ts:47-71`). If the stream ends without a terminal event, it throws `Error: bridge stream ended mid-turn`.

---

## 3. SDK Generation Script (`sdk/generate.py`)

### What it does
`generate.py` is a codegen tool that reads the JSON schema emitted by `graff --schema` and produces all three SDK artifacts:

- `sdk/ts/harness.ts` — Node.js stdio client
- `sdk/ts/remote.ts` — Edge-safe fetch client
- `sdk/py/harness_sdk.py` — Python stdio + urllib client

The script is the **single source of truth** for SDK types; the generated files carry the header `"AUTO-GENERATED by sdk/generate.py from \`harness --schema\`. Do not edit."` (`sdk/generate.py:1`, `sdk/ts/harness.ts:1`, `sdk/py/harness_sdk.py:1`).

### How it works
1. **Schema ingestion** (`load_schema`) accepts:
   - `stdin` (e.g. `graff --schema | python3 sdk/generate.py`)
   - `--schema FILE`
   - `--harness BIN` (runs the binary for you)
   (`sdk/generate.py:16-34`)

2. **Type extraction** pulls three arrays from the schema:
   - `models` → `ModelName` union / `MODELS` constant
   - `tools` → `ToolName` union / `TOOLS` constant
   - `providers` → `ProviderId` union / `PROVIDERS` constant
   - `version` → `HARNESS_VERSION` constant
   (`sdk/generate.py:37-42`, `sdk/generate.py:44-47`, `sdk/generate.py:431-438`)

3. **Template generation** uses large Python f-string templates that embed the sorted unions and version. The templates contain the full class implementations (including telemetry, prompt fingerprinting, score signing, event parsing, etc.). No logic is synthesized from the schema beyond the literal type constants and version string; the rest is static boilerplate maintained inside `generate.py` itself.

4. **Output** writes all three files via `write()` and prints byte counts (`sdk/generate.py:439-445`).

### CI enforcement
The `.github/workflows/sdk.yml` workflow publishes the committed SDKs to npm and PyPI on every `sdk-v*` tag, but the generation must be run locally before tagging because the action does **not** regenerate— it ships what is committed (`sdk/README.md:11-15`, `.github/workflows/sdk.yml:1-8`). The `.github/workflows/ci.yml` also includes a `sdk` job that validates the committed SDKs without requiring a Zig build (`codedb` context for `.github/workflows/ci.yml:10`).

---

## 4. Relationship to the Broader Project

### Verified facts
1. **The core is a Zig CLI binary.** The project’s engine lives in `src/main.zig` (~1,250 lines of Zig 0.16) and compiles to a single executable named `graff` (formerly `harness`) (`architecture.md:1-3`, `build.zig:32-35`).
2. **The SDKs are thin clients over that binary.** They do not reimplement the agent loop, LLM provider routing, tool dispatch, or context compaction. They only wrap the `--json` stdio protocol or the HTTP bridge (`harness serve`) (`sdk/README.md:1-4`, `sdk/ts/harness.ts:155-157`).
3. **`harness --schema` is the contract.** The Zig binary emits its own interface (models, tools, providers, event protocol, version). The generation script consumes this JSON to keep the SDK types in lockstep with the binary (`sdk/generate.py:1-8`, `sdk/README.md:11-15`).
4. **`harness serve` is an HTTP bridge.** The remote clients do not talk to a separate server implementation. The server side of the bridge still runs the same `harness --json` child per session; one POST equals one protocol request, streamed back as NDJSON (`sdk/ts/remote.ts:1-10`, `sdk/py/harness_sdk.py:338-341`).
5. **The DGM evolution loop is built on the SDK.** `examples/dgm_loop.py` imports `Harness`, `prompt_fingerprint`, and `verify_score` from the Python SDK to implement a Darwin Gödel Machine that mutates system prompts, scores them via a replay judge, and writes lineage into the trajectory archive (`examples/dgm_loop.py:18-20`, `examples/dgm_loop.py:101-110`).
6. **Telemetry is shared.** Both the harness binary and the SDKs report to the same OTLP endpoint (`https://harness-telemetry.rachpradhan.workers.dev` by default) using the same opt-out environment variables (`GRAFF_NO_TELEMETRY`, `OTEL_EXPORTER_OTLP_ENDPOINT`) (`sdk/py/harness_sdk.py:54-96`, `sdk/ts/harness.ts:79-121`).
7. **The CLI was renamed.** The default binary is now `graff`, with `harness` as a fallback compatibility name (`sdk/py/harness_sdk.py:139-142`, `sdk/ts/harness.ts:133-140`).

### Inferred but not directly verified
- The `harness serve` mode is likely implemented inside `src/main.zig` as an HTTP server (referenced in `architecture.md` under “Where this could go next” and in `sdk/ts/remote.ts` comments), but I did not read the Zig server code directly because `src/main.zig` is not indexed by `codedb` in this output.

---

## Top 3 Load-Bearing Facts

1. **The SDKs are auto-generated from `graff --schema`; the schema JSON is the only source of truth for models, tools, providers, and the event protocol.** Any drift between the binary and the SDKs is caught by regenerating via `sdk/generate.py` (`sdk/generate.py:1`, `sdk/py/harness_sdk.py:1`, `sdk/ts/harness.ts:1`).
2. **Both Python and TypeScript SDKs are thin wrappers: they spawn the local Zig binary (`Harness`) or talk HTTP to a bridge that still spawns the binary per session (`RemoteHarness`).** They do not contain the agent loop, tool implementations, or LLM logic (`sdk/py/harness_sdk.py:148-180`, `sdk/ts/harness.ts:157-167`, `sdk/README.md:1-4`).
3. **The `score()` and `pull_elites()` APIs exist to support the Darwin Gödel Machine evolution loop.** The SDK is not just a chat client; it is the programmatic interface for automated prompt evolution, with HMAC-signed fitness records and fleet telemetry (`sdk/py/harness_sdk.py:261-323`, `examples/dgm_loop.py:1-110`).

---

## 1 Open Question

**Does `harness serve` (the HTTP bridge) live entirely in `src/main.zig`, or is it a separate binary / wrapper?** The SDKs and docs refer to it as the server side of the remote transport, but I did not inspect the Zig source to confirm whether it is a built-in subcommand (`graff serve`) or an external component.
