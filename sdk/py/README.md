# codegraff

Python client for the [codegraff](https://github.com/justrach/codegraff) agent.
It drives the `graff` binary over its `--json` stdio protocol, with constants
auto-generated from `graff --schema`.

## Install

```sh
pip install codegraff
```

> **Note the package / module name mismatch:** the PyPI package is `codegraff`,
> but the importable module is `harness_sdk`:
>
> ```python
> from harness_sdk import Harness
> ```

### Prerequisite: the `graff` binary

The SDK spawns the `graff` binary as a subprocess, so it must be installed:

```sh
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

If `graff` isn't on your `PATH`, point at it explicitly with the `binary`
argument (`Harness(binary="./zig-out/bin/graff")`).

## Quick start

```python
from harness_sdk import Harness

with Harness(yolo=True, model="gpt-5.5") as h:
    # one-shot: ask() returns just the final text
    print(h.ask("what is 2+2?"))

    # streamed: chat() iterates event dicts
    for ev in h.chat("read foo.txt"):
        print(ev["type"], ev)

# replace or extend the system prompt
with Harness(yolo=True, system_prompt="You are a code-review bot. Only report bugs.") as bot:
    print(bot.ask("review main.py"))
```

`Harness` accepts `yolo`, `model`, `cwd`, `system_prompt`, `binary`, and more.
`model` may be a model name **or** a provider id (e.g. `"codex"`, `"moonshot"`).
Also exported: `MODELS` and `PROVIDERS`.

## Events

`chat()` yields event dicts, each with a `type`:

- `text` — assistant text delta
- `tool_call` — the agent invoked a tool (`name`, `input`)
- `tool_result` — a tool returned
- `ask_user` — the agent needs input; answer it with the `call_id`
- `turn` — turn finished; carries the final text, `context_tokens`, and `cost_usd`
- `error` — something went wrong

## Remote (no local binary)

Edge / serverless runtimes can't spawn a subprocess. Run `graff serve` somewhere
and drive it over HTTP (stdlib `urllib` only):

```python
from harness_sdk import RemoteHarness

with RemoteHarness("http://127.0.0.1:8787", token="...", yolo=True) as h:
    print(h.ask("what is 2+2?"))
```

## Links

- Repository: <https://github.com/justrach/codegraff>
- This package (PyPI): <https://pypi.org/project/codegraff/>
- TypeScript sibling (npm): <https://www.npmjs.com/package/@codegraff/sdk>

## License

BSD-3-Clause
