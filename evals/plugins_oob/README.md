# Plugin out-of-box inspect eval

Unit tests in `src/plugins.zig` call `discover` / `mergeMcp` directly. They
cannot tell you whether `graff mcp list` and `graff plugins` see the same
trees a session would, honor `GRAFF_NO_PLUGINS`, or keep graff's own
`~/.codegraff/mcp.json` ahead of a colliding plugin name.

This environment builds a fake `$HOME` with a Cursor cache plugin (manifest
name, not the content-hash folder), a Claude plugin, a personal
`~/.cursor/mcp.json`, and a graff global that overrides a shared server
name. The verifier is the real binary. No provider calls.

```sh
zig build
python3 evals/plugins_oob/run.py --self-test
python3 evals/plugins_oob/test_eval.py
```

What it guards:

- Plugin MCP names appear on `graff mcp list`.
- A graff global wins a shared name (plugin command must not leak).
- `GRAFF_NO_PLUGINS=1` hides plugin and foreign-harness names only.
- `graff plugins` prints the manifest name, not the Cursor cache hash.
- The same opt-out prints `GRAFF_NO_PLUGINS` on `graff plugins`.

MCP fixtures use `command: /bin/false` so a mistaken connect cannot hang on
a remote URL. `--yolo` is not passed; list/inspect never start servers.
