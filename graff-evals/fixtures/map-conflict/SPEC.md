# Map conflict detection (DeepSWE `yjs-map-conflict-detection`, distilled)

`doc.py` must expose `Doc`, `MapConflictError`.

`Doc(map_conflict_policy="allow"|"collect"|"error")`.

`doc.get_map(name)` returns a map-like object with `set(key, value)` and
`delete(key)`. `doc.transact(fn)` runs `fn` inside one transaction.

Conflicts: two `set`s, or a `set` and a `delete`, on the **same key**
inside one transaction.

- `allow`: apply last write; do not record or throw.
- `collect`: apply last write; record conflicts. `get_map_conflicts()`
  returns a list of dicts with `key`, `type` (`set-set` or `delete-set`),
  `source` (`local`), `message` (non-empty), `resolution` with
  `winner`, `strategy` (string), `deterministic` (bool).
  `get_map_conflict_summary()` returns `{count, byType, byKey}` where
  `byType`/`byKey` map strings to counts.
- `error`: raise `MapConflictError` with `.conflicts` (list). The
  transaction must be **atomic**: no partial application.

Values that are dicts (stand-in for nested Y types) make `type` `ambiguous`.
