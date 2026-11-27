# Correctness at first completion

The recovery exercise tests one seeded, durable work queue. Hidden
executable checks exercise unchanged success, stable identity and payload,
partial acknowledgment, repeated transport failure, worker restart,
concurrent workers and intake during delivery.

```sh
python3 evals/first_completion/run.py --self-test
python3 evals/first_completion/run.py --graff ./zig-out/bin/graff
```

The first command checks the external grader against a missing file, an
intentionally incomplete repair and a reference solution. The second runs
the normal ACP entry point with scripted loopback responses. It checks
that the runner captures an incorrect first completion, restores the same
workspace and conversation for both continuations, and scores a rescue in
only the scripted verification arm.

A completion requires the terminal ACP `end_turn` and a final line of
`COMPLETE`. Explicit non-completion, missing claims, timeouts and other
stop reasons stay visible. The two arms share call and time budgets.
They use the same grading executable and receive no grading results.
Output includes seed, grader hash, outcomes, elapsed time and usage when
the harness supplies it.

Pass `--model` to run a live API model. Grant access to an exported
credential by passing its variable name with `--model-key-env`. Live
runs consume model calls and require a verified checkout visibility
boundary with macOS `sandbox-exec` or Linux `bwrap`. The fixture runner
targets cooperating coding agents. The visibility check keeps the grader
out of normal child-process reads. Run adversarial candidates in an
isolated container with no unrelated credentials. One task gives a
starting point for measuring first-completion and rescue rates.
