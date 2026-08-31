# Resume restores cursor and inbox, not the room (CodeGraff #584 / ADR 0014)

`resume.py` must expose:

- `snapshot(cursor, inbox) -> dict` — `{"cursor": int, "inbox": list}`
  (a copy of `inbox`)
- `resume(snap) -> dict` — `{"cursor", "inbox", "history"}`

`/resume` restores the peer-channel **byte cursor** and **inbox**. It does
**not** replay the room into history. `history` is always `[]`.
`ROOM` in the file is leftover transcript — do not copy it into the
restored session.
