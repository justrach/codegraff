# Stall budget widens on reconnect (CodeGraff #681, distilled)

`stall.py` must expose `inter_frame_budget_ms(base_ms, tokens_flowing,
reconnects=0) -> int`.

Constants (already in the file): `IDLE_DIVISOR=4`, `IDLE_FLOOR_MS=15000`,
`HEAD_CEILING_MS=45000`.

Regimes:

- No tokens yet (`tokens_flowing=False`): return `min(base_ms, HEAD_CEILING_MS)`.
  The head ceiling is **not** widened by reconnects — a socket that never
  answered is still dead-on-arrival.
- Tokens have flowed, `reconnects=0`: `min(base_ms, max(IDLE_FLOOR_MS, base_ms // 4))`
  (30s at the 120s default).
- Each stall reconnect widens the between-lines budget:
  `reconnects=1` → `base/2`, `reconnects>=2` → `base`. Still clamped to
  `base_ms` and never below `IDLE_FLOOR_MS` unless `base_ms` itself is smaller.

Default `base_ms` in tests is `120_000`.
