"""Y.Map-style conflict detection — incomplete. Fix the SPEC.md contract."""


class MapConflictError(Exception):
    def __init__(self, conflicts):
        super().__init__("map conflict")
        # BUG: conflicts not exposed
        self.payload = conflicts


class _Map:
    def __init__(self, doc, name):
        self.doc = doc
        self.name = name
        self._data = {}

    def set(self, key, value):
        self.doc._op(self, "set", key, value)

    def delete(self, key):
        self.doc._op(self, "delete", key, None)

    def get(self, key, default=None):
        return self._data.get(key, default)


class Doc:
    def __init__(self, map_conflict_policy="allow"):
        self.policy = map_conflict_policy
        self._maps = {}
        self._tx = None
        self._conflicts = []

    def get_map(self, name):
        if name not in self._maps:
            self._maps[name] = _Map(self, name)
        return self._maps[name]

    def transact(self, fn):
        self._tx = []
        try:
            fn()
            self._commit()
        finally:
            self._tx = None

    def _op(self, m, kind, key, value):
        if self._tx is None:
            self.transact(lambda: self._op(m, kind, key, value))
            return
        self._tx.append((m, kind, key, value))

    def _commit(self):
        ops = self._tx or []
        by_key = {}
        for m, kind, key, value in ops:
            by_key.setdefault((m.name, key), []).append((m, kind, key, value))
        conflicts = []
        for (name, key), group in by_key.items():
            if len(group) < 2:
                continue
            kinds = [g[1] for g in group]
            if "delete" in kinds and "set" in kinds:
                typ = "delete-set"
            else:
                typ = "set-set"
            if any(isinstance(g[3], dict) for g in group if g[1] == "set"):
                typ = "ambiguous"
            conflicts.append({
                "key": key,
                "type": typ,
                "source": "local",
                "message": f"{typ} on {key}",
                "resolution": {"winner": "last", "strategy": "last-write", "deterministic": True},
            })
        if conflicts and self.policy == "error":
            # BUG: applies ops before raising (not atomic)
            for m, kind, key, value in ops:
                if kind == "delete":
                    m._data.pop(key, None)
                else:
                    m._data[key] = value
            raise MapConflictError(conflicts)
        if conflicts and self.policy == "collect":
            # BUG: conflicts not recorded
            pass
        for m, kind, key, value in ops:
            if kind == "delete":
                m._data.pop(key, None)
            else:
                m._data[key] = value

    def get_map_conflicts(self):
        return list(self._conflicts)

    def get_map_conflict_summary(self):
        by_type, by_key = {}, {}
        for c in self._conflicts:
            by_type[c["type"]] = by_type.get(c["type"], 0) + 1
            by_key[c["key"]] = by_key.get(c["key"], 0) + 1
        return {"count": len(self._conflicts), "byType": by_type, "byKey": by_key}
