# Config file parsing (DeepSWE `cliffy-config-file-parsing`, distilled)

`config.py` must expose `load_config(name, search_paths=None, formats=None,
merge_configs=False, cli=None, env=None) -> dict`.

Default `formats` is `[".json", ".rc"]`. Default `search_paths` is `["."]`.
For each search path, look for `{name}.json` then `.{name}rc` (for `.rc`).

`.json` is a JSON object. Nested objects flatten with dots
(`{"db": {"host": "x"}}` → `{"db.host": "x"}`). Kebab-case keys become
camelCase (`retry-count` → `retryCount`).

`.rc` is `key=value` per line. `#` comments and blank lines are ignored.
Double-quoted values keep spaces. `true`/`false` become bools; integer
strings become ints.

When `merge_configs` is false, use only the **first** matching file.
When true, merge every match; **earlier search paths win**.

Precedence: CLI overrides env overrides config. Boolean `false` and
numeric `0` are valid values (do not treat them as missing).

Unknown keys stay in the dict (no validation in this distillation).
Raise `ConfigParseError` on malformed JSON/RC.
