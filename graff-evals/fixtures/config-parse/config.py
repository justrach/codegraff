"""Config loader — incomplete. Fix the SPEC.md contract."""
import json
import os


class ConfigParseError(Exception):
    pass


def _camel(key):
    # BUG: kebab-case is left as-is
    return key


def _flatten(obj, prefix=""):
    out = {}
    if not isinstance(obj, dict):
        return {prefix: obj} if prefix else obj
    for k, v in obj.items():
        nk = _camel(k)
        path = f"{prefix}.{nk}" if prefix else nk
        if isinstance(v, dict):
            out.update(_flatten(v, path))
        else:
            out[path] = v
    return out


def _parse_rc(text):
    out = {}
    for line in text.splitlines():
        # BUG: comments are not ignored
        if not line.strip():
            continue
        if "=" not in line:
            raise ConfigParseError("rc")
        k, v = line.split("=", 1)
        k = _camel(k.strip())
        v = v.strip()
        if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            v = v[1:-1]
        elif v in ("true", "false"):
            v = v == "true"
        else:
            try:
                v = int(v)
            except ValueError:
                pass
        out[k] = v
    return out


def load_config(name, search_paths=None, formats=None, merge_configs=False, cli=None, env=None):
    search_paths = search_paths or ["."]
    formats = formats or [".json", ".rc"]
    found = []
    for path in search_paths:
        for fmt in formats:
            if fmt == ".json":
                fp = os.path.join(path, f"{name}.json")
            elif fmt == ".rc":
                fp = os.path.join(path, f".{name}rc")
            else:
                fp = os.path.join(path, f"{name}{fmt}")
            if os.path.isfile(fp):
                found.append(fp)
    if not found:
        data = {}
    else:
        # BUG: merge_configs=False still merges; later files win
        data = {}
        for fp in found:
            text = open(fp).read()
            try:
                if fp.endswith(".json"):
                    chunk = _flatten(json.loads(text))
                else:
                    chunk = _parse_rc(text)
            except json.JSONDecodeError as e:
                raise ConfigParseError(str(e)) from e
            data.update(chunk)
    env = env or {}
    cli = cli or {}
    # BUG: env overrides cli
    out = {}
    out.update(cli)
    out.update(data)
    out.update(env)
    return out
