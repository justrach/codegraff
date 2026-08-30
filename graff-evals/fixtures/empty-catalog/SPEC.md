# Rebuild the catalog after a showcase (CodeGraff rlm-empty-tools, distilled)

`catalog.py` must expose:

- `NATIVE = ["read_file", "bash", "codedb", "rlm"]` — the always-on tools
- `tools_json(showcase=False, extra=None) -> str` — a JSON array of tool
  names. `extra` is an optional list merged after `NATIVE` (deduped, order
  preserved).
- `request_body(showcase=False, extra=None) -> str` — a JSON object with a
  `tools` field whose value is the parsed catalog. The serialized body must
  be valid JSON. An empty catalog is `[]`, never a missing/blank value
  (the `"tools":,` wire bug).

After `showcase=True` the catalog is invalidated and **must be rebuilt**
from `NATIVE` (+ `extra`). It must not come back empty.
