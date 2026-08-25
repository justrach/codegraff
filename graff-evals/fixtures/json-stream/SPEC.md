# Streaming JSON iteration (DeepSWE `httpx-streaming-json-iteration`, distilled)

`json_stream.py` must expose `DecodingError` and `iter_json(content_type, body,
streaming=False)`.

`content_type` matching is case-insensitive; parameters are allowed.
Accept:

- `application/json` and `application/*+json` (the `+json` suffix is **only**
  valid under `application/`)
- `application/ndjson` / `application/x-ndjson`
- `application/json-seq`

Anything else raises `DecodingError`.

`application/json` / `*+json`: skip leading whitespace; if the top-level
value is an array, yield each element; otherwise yield the single value.
After the value only whitespace is allowed.

NDJSON: split on LF / CR / CRLF. Skip blank lines. Each other line is one
JSON value.

JSON text sequences: records start with RS (`0x1e`). Strip at most one
trailing LF per record, then parse one JSON value. Empty payload yields
nothing.

If `streaming=True`, a second call on the same consumed stream raises
`StreamConsumed`. In-memory (`streaming=False`) iteration is repeatable —
this distillation models that with a `Stream` object: `iter_json` may
return an iterator, and `StreamConsumed` is raised by a second
`iter_json(..., streaming=True)` on the same `body` if `body` is a
`Stream`.
