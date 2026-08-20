# lean-proofs

The formal corpus. It grows one **kernel** at a time: a discrete decision
procedure with a finite reachable state space, properties that would be
easy to miss as hand-written examples, and an implementation that can be
diffed against exported fixtures.

Lean is the source of truth. `lake` is optional. `spec/conformance.py`
and `zig build test` are what CI runs. Adding a vendor, a flag, or a
transport path means adding a row or a bit here — not a new proof per
brand.

```
lean-proofs/Graff/*.lean     definitions + theorems
        |
   +----+----------------+
   |                     |
spec/ref/*.py          spec/kernels/*.json
executable model       exported cells
        |                     |
        +----------+----------+
                   v
         spec/conformance.py
         zig test vs fixtures
                   |
         pass / counterexample
```

See `KERNELS.md` for what is in, what is next, and what will never be a
kernel. The rule: **factor axes, then drop illegal cells**. Nineteen
providers are one table over three wire kinds, not nineteen programs.
WebSocket is a predicate on `Kind × seat × flags`, and almost every
cell is *not* WebSocket.
