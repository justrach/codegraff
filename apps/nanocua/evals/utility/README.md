# Observation utility comparison

This runs the **same Codegraff agent** on five stateful, synthetic tasks under
five observation policies. It measures completed tasks, total tool calls,
observation bytes, all reply-text bytes, and reported session token usage.
It is not a native macOS test or a claim of equivalent real-app performance.

The fixture uses nanocua's **production tool catalog, argument parsing, node
filter, and text serializer**, through `nanocua-utility-render`. It supplies
synthetic nodes, ref-to-element maps, and action effects. It never links or calls
Accessibility, input injection, the clipboard, app launch, or screenshots.
There is no desktop permission requirement.

## Cases

- Calculate `7*6`, then **read** the displayed answer.
- Open a file's information and read duration, dimensions, and byte size.
- Submit an invalid email and read the validation message.
- Navigate through a button whose name exists only in its child static text.
- Change a checkbox and read its resulting value.

Each case has a semantic oracle: the required action must have changed fixture
state, the successful result must then have appeared in an observation, and the
agent's final answer must match. Guessing an answer is not a pass. Agent startup
or credential failures are reported separately from task failures.

## Policies

| Policy | Observation returned |
| --- | --- |
| `default` | Production defaults: text and refs, no coordinates; explicitly requested options are honored |
| `full` | Full text and coordinates, regardless of requested options |
| `no_frames` | Full text, no coordinates |
| `controls_only` | Controls only, no coordinates, even if full text is requested |
| `adaptive` | Controls by default; full text when the agent requests `interactive_only:false`; no coordinates |

The forced `controls_only` mode is a **negative control**, not production
behavior: production callers can always request a full tree. `adaptive` tests
the cost of making that fallback, rather than hiding its extra calls. The same
prompt tells every agent to read the default tree, use returned refs, request
full text when needed, and verify results after acting.

These small fixtures intentionally have no artificial wall of filler text.
A compact initial read plus a full verification read can cost **more** than two
full reads. Compare success and total observations, not just the shortest reply.
Session tokens include harness overhead, not just observations. One run per cell
is a smoke comparison, not a statistically reliable model ranking.

## Run

From `apps/nanocua`, with Zig 0.17:

```sh
zig build utility-eval
python3 -m unittest discover -s evals/utility -p 'test_*.py' -v
python3 evals/utility/run.py --graff /path/to/graff --model PROVIDER/MODEL \
  --output .zig-cache/utility-model.json
```

Model runs are opt-in, use the configured provider, and incur its usual cost.
Supply credentials through the provider's environment variable. The runner
inherits it in memory; it never copies credentials into files. Each run uses a
temporary HOME, cwd, and MCP config; plugins, telemetry, local coding tools, and
non-local learning are disabled. The only MCP server is this fixture, named
`nanocua` so it also overrides any automatic desktop-server entry.

`--cases`, `--modes`, `--jobs`, and `--timeout` bound the run. `--resume` keeps
previously recorded case/mode pairs; use it only with the same binary, model,
prompt, and fixtures. Results are written incrementally to the requested local
file, without raw harness logs or session identifiers. A nonzero runner exit
means an infrastructure failure, not an expected negative-control task failure.
`--resume --retry-infrastructure` retries only those cells and retains their
original failures under `infrastructure_attempts`. It does not retry task
failures to improve the score. `verified_answer` records a correct observed
answer separately from `passed`, which also requires the agent to exit cleanly
within the fixed twelve-model-call budget.

Coverage limits: synthetic ref handling and action effects do not test the real
AX walker, native click delivery, Spaces, changing app trees, or arbitrary
third-party accessibility roles. Those need a separate controlled desktop test.
