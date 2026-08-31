# Hosted x_search is a splice, not a catalog tool (CodeGraff #632 / ADR 0031)

`splice.py` must expose `splice(tools, provider, kind, enabled=True) -> list`.

`tools` is a list of dicts (the Responses `tools` array). Return a new list.

- When `enabled` and `provider == "xai"` and `kind == "responses"`: append
  `{"type": "x_search"}` if that type is not already present.
- Chat-completions (`kind == "chat"`) and every other provider: return
  `tools` unchanged (copy ok). Never add a catalog function named `x_search`.
- `enabled=False` (GRAFF_XAI_X_SEARCH=0): never splice.
- Do not local-exec a resulting `x_search_call`. This fixture only covers
  the splice.
