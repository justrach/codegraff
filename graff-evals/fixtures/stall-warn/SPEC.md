# Stall warning only at give-up (CodeGraff stall-bus-silent, distilled)

`stall_notice.py` must expose:

- `GIVE_UP = "⚠ stall — giving up"`
- `stall_notice(reconnects_left) -> str | None`

`reconnects_left` is how many reconnect attempts remain **after** this stall.

- `reconnects_left > 0`: return `None` (reconnect silently; do not print ⚠).
- `reconnects_left == 0`: return `GIVE_UP` (the ending-turn notice).
- Negative values are treated as 0.

A mid-turn `FORCE_STALL_ALWAYS` run reconnects twice then ends. The e2e
script must see the give-up line, not a reconnect ⚠.
