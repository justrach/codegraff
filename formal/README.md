# Harness lifecycle models

These TLA+ models describe concurrency rules in the harness. TLC explores the
finite configurations committed beside each model, including interleavings that
are difficult to reproduce with ordinary tests.

- [Effort selection](effort-selection.md): admission, stale completions, manual
  changes, cancellation, and owner-boundary application.
- [Async tools](async-tools.md): early admission, call identity, ordering
  barriers, result ownership, joining, and cancellation.
- [ACP permissions](acp-permissions.md): transport-owned GUI tokens, replaced
  workers, offered choices, and responses racing with cancellation.
- [HTTP/2 leases](http2-leases.md): exclusive ownership, idle pooling,
  cancellation, shutdown, and reuse only after stream completion.

Each model has a normal configuration and a deliberately broken configuration.
The negative control must fail the intended invariant. A syntax error, timeout,
or unrelated failure is not a successful negative control.

See [change evidence](change-evidence.md) for connecting source diffs, model
counterexamples, and runtime regressions.

See the [ranked extension plan](roadmap.md) for the next ownership, retry,
budget, and session properties to model.

The [DGM integration design](dgm-integration.md) separates formal admission
from task correctness and measured fitness, and identifies the native promotion
paths that need their own integration.

## Scope

Passing TLC establishes the checked properties of these finite abstractions.
It is not a proof that the Zig implementation refines the models, an unbounded
mathematical proof, or evidence of faster execution or lower token usage. The
companion documents map actions to code and state what is omitted. Runtime
regression tests remain necessary, particularly for parsing, allocation,
transport behavior, and cancellation implementation.

Changes to the corresponding runtime lifecycle should update its model and
mapping in the same change. A counterexample is a design or model finding until
it is reproduced against the implementation; do not report it as a runtime bug
without that check.

## Toolchain

Use Java 11 or newer and the official
[TLA+ command-line tools](https://github.com/tlaplus/tlaplus/blob/master/USE.md).
The checked tool release is
[v1.7.4](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.4), whose
`tla2tools.jar` has SHA-256:

```text
936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
```

Set `JAVA` to the Java executable and `TLA2TOOLS` to that jar. The check runner
uses a bounded heap, one worker, and temporary state directories. It does not
download tools or call a model provider.

```sh
python3 scripts/check-formal.py
```

Keep model-checker state and counterexample output outside the source tree.
See the individual model documents for configuration bounds, invariants, and
any fairness assumptions. These checks are separate from the Zig unit suite;
running `zig build test` alone does not run TLC.
