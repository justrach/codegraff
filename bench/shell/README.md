# Shell-call loop benchmark

Measures graff's per-shell overhead with an instant fake model: 30 `shell`
tool calls (`echo hello`, `pwd`, `ls`, `true` cycling), then `DONE`. One
stdio MCP server is configured. Sandbox is off (root `--yolo` shells).

Loop time is wall clock from the first `--json` `tool_call` event to the last
`tool_result`. Default: 3 warm-ups, then 20 runs; report median and p90.

## Run

From the repository root, with a built `zig-out/bin/graff` (or pass `--graff`):

```bash
python3 bench/shell/run.py
python3 bench/shell/run.py --graff /path/to/graff --warmups 3 --runs 20
```

Requires Go (for `bench/shell/fake_model.go`) and Python 3.

The fake server speaks OpenAI Chat Completions over HTTP/1.1 keep-alive on a
loopback port. The runner points graff at it with a workspace
`.graff/.config.router` (`tier2/mock`) so the built-in lmstudio port is unused.
