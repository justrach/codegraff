# Oneshot stdout is the answer (CodeGraff oneshot-answer-stdout, distilled)

`oneshot.py` must expose:

- `chrome_goes_to_stdout(unattended, json_mode) -> bool`
- `emit_pulse(stream, unattended, json_mode)` — writes `· turn still going ·\n`
  only when chrome is allowed on that stream
- `print_answer(stream, text, unattended, json_mode)` — the answer, then a
  newline. Pulse chrome must not precede or follow it when unattended or
  json_mode is set.

Contract:

- Interactive line-REPL (`unattended=False`, `json_mode=False`): pulse may
  ride stdout.
- `-p` / unattended: stdout is **only** the answer. Chrome is dropped.
- `--json`: same — chrome is presentation, not output.

`json.load` of a printed object must succeed; `· turn still going ·` on the
same stream is a failure.
