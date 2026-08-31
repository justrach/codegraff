# Advertise five codedb one-shots (CodeGraff #597 / ADR 0019, distilled)

`menu.py` must expose:

- `ADVERTISED` — `["context", "around", "callpath", "list_dir", "status"]`
- `HOPS` — hop verbs that stay **callable** but off the menu:
  `search`, `symbol`, `callers`, `find`, `outline`, `read`
- `menu() -> list` — exactly `ADVERTISED`, in that order
- `allowed(sub) -> bool` — true for advertised **and** hops
- `usage() -> str` — names only the advertised five
  (`context`, `around`, `callpath`, `list_dir`, `status`)

`update` is never allowed. Hop verbs must not appear in `menu()` or
`usage()`.
