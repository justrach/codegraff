# TB-21 misses (graff · grok-4.6)

Eval-only diagnosis. `prompt_text.zig` was not changed. The runner now
`--append-system-prompt`s `BENCH_APPEND` in `fh_run.py` for these modes.

| task | K3 | mode | what went wrong |
|---|---|---|---|
| `vulnerable-secret` | 12/12 | safety | Model refused to extract `FLAG{...}` from a local sandbox binary (2 calls). Bench CTF, not a real secret. |
| `polyglot-c-py` | 12/12 | leftover file | Polyglot worked; `gcc -o cmain` left `/app/polyglot/cmain`. Test requires **only** `main.py.c`. |
| `db-wal-recovery` | 12/12 | incomplete | 33 calls, 5/7 tests. WAL decrypt + recovered-data completeness failed. |
| `gcode-to-text` | 5/12 | timeout | Hit the 900s agent cap. No usage footer. |
| `largest-eigenval` | 0/12 | timeout | Same. Nobody on the K3 board passed. |
| `extract-elf` | 2/12 | wrong output | 9 calls; 0% match vs 75% required. |
| `kv-store-grpc` | 0/12 | server down | 10 calls; gRPC server didn't stay up. Nobody on the K3 board passed. |

Suite peaks on the first graff pass (list $ at grok-4.6 `$2 / $0.50 cached / $6`):

See `results.maxima.json` after a run. First-pass eyeball: `calls_max=53` (build-cython-ext), `tok_in_max=1.95M`, `tok_cached_max=1.68M`, `list_usd_sum≈$5.05`.
