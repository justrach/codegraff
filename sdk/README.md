# simple-harness SDKs

TypeScript (`ts/`) and Python (`py/`) clients that drive graff over its
`--json` stdio protocol. **Both are auto-generated** — never hand-edit the
generated files.

## How it works

The graff binary is the single source of truth. `graff --schema` emits its
interface (providers, models, tools, and the `--json` event protocol) as JSON.
`generate.py` turns that into typed clients:

```sh
# regenerate locally from the built binary
python3 sdk/generate.py --harness ./zig-out/bin/graff
# or from a saved schema
graff --schema | python3 sdk/generate.py
```

On every `sdk-v*` tag the `sdk` GitHub Action rebuilds, regenerates, fails if the
committed SDKs are stale, and publishes to npm/PyPI via OIDC trusted publishing
(no registry tokens required).

## Usage

Python:

```python
from harness_sdk import Harness
with Harness(yolo=True, model="gpt-5.5") as h:
    print(h.ask("what is 2+2?"))
    for ev in h.chat("read foo.txt"):
        print(ev["type"], ev)

# replace or extend the system prompt (passes --system-prompt /
# --append-system-prompt; the cwd AGENTS.md/HARNESS.md/CLAUDE.md project
# file is still appended on top of a replaced prompt)
with Harness(yolo=True, system_prompt="You are a code-review bot. Only report bugs.") as bot:
    print(bot.ask("review main.py"))
```

TypeScript — the API mirrors [`@codegraff/sdk`](https://www.npmjs.com/package/@codegraff/sdk)
(`runAgent` one-shot, `Harness.init` long-lived, `.session()`, `.chat()`/`.ask()`):

```ts
import { Harness, runAgent } from "@codegraff/sdk"; // or "./harness.ts"

// one-shot, streamed (parallel to codegraff's runAgent)
for await (const ev of runAgent({ prompt: "summarize README.md", model: "gpt-5.5", yolo: true })) {
  if (ev.type === "text") process.stdout.write(ev.text);
  if (ev.type === "tool_call") console.log("→", ev.name, ev.input);
  if (ev.type === "turn") console.log("\ncost $", ev.cost_usd);
}

// long-lived, multi-turn (parallel to Graff.init / GraffSession)
const harness = Harness.init({ model: "claude-opus-4-8", yolo: true });
const session = harness.session();
console.log(await session.ask("what files are here?"));
console.log(await session.review("review HEAD against main")); // isolated + read-only
for await (const ev of session.send("ask me a follow-up before continuing")) {
  if (ev.type === "ask_user") session.answer({ text: "continue", callId: ev.call_id });
}
console.log(await session.ask("now read the largest one"));
session.close();
```

Options: `binary`, `cwd`, `env`, `model` (model name *or* provider id, e.g. `"codex"`),
`yolo`, and raw `args`. `chat()`/`send()`/`ask()` accept a string or `{ prompt }`;
`review()` runs an isolated read-only review turn with fresh model-visible history.

## Remote (edge runtimes — no local binary)

Both transports above spawn a local process, which edge runtimes can't do.
Run `graff serve` somewhere (default `127.0.0.1:8787`; pass
`--token <secret>` — required for non-loopback binds) and drive it over HTTP
instead. Same method surface, same event stream:

```ts
// fetch + Web Streams only — works on Cloudflare Workers, Deno, Bun,
// browsers, and Node >= 18
import { RemoteHarness, runAgentRemote } from "@codegraff/sdk/remote";

for await (const ev of runAgentRemote({ url: "https://my-bridge.example", token, yolo: true, prompt: "summarize README.md" })) {
  if (ev.type === "text") console.log(ev.text);
}

const h = RemoteHarness.init({ url: "http://127.0.0.1:8787", yolo: true });
console.log(await h.ask("what files are here?"));
await h.close(); // graceful: the bridge EOFs the child's stdin
```

```python
from harness_sdk import RemoteHarness  # stdlib urllib only

with RemoteHarness("http://127.0.0.1:8787", token="...", yolo=True) as h:
    print(h.ask("what is 2+2?"))
```

One protocol request is in flight per session at a time; pass `yolo=True` in
most cases (the bridge has no terminal to show permission prompts on). The
HTTP contract lives under the `serve` key of `graff --schema`.

Remote sessions are resumable. Every event carries a monotonic `seq`, which the
client tracks as `lastSeq` / `.last_seq`; if a stream dies mid-turn, iterate
`reconnect()` and you get exactly the events you missed and then the live tail
(the bridge kept draining the child into a persisted log the whole time). Name a
session with `session` and the run survives the bridge itself: point a client at
a replacement `graff serve` in the same workspace with the same name and it
picks up from the last persisted turn.

```ts
const h = RemoteHarness.init({ url, session: "nightly-run", yolo: true });
try {
  for await (const ev of h.chat("keep going")) console.log(ev.seq, ev.type);
} catch {
  for await (const ev of h.reconnect()) console.log("missed", ev.seq, ev.type);
}
```

```python
h = RemoteHarness(url, session="nightly-run", yolo=True)
print(h.info)          # {'session_id': 'nightly-run', 'resumed': True, 'last_seq': 42}
for ev in h.reconnect():
    print(ev["seq"], ev["type"])
```

## Protocol

`graff --json` reads `{"type":"user","text":"..."}` lines on stdin and emits
JSONL events: `text` (assistant delta), `tool_call`, `ask_user`, `tool_result`,
`turn` (final text + `context_tokens` + `cost_usd`), and `error`. Answer an
`ask_user` event with `{"type":"answer","text":"...","cancelled":false,"call_id":"..."}`.
See the `protocol` key of `graff --schema`.
