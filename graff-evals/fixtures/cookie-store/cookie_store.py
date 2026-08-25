"""Deterministic cookie jar — incomplete. Fix the SPEC.md contract."""


class CookieConflict(Exception):
    pass


class _C:
    __slots__ = ("name", "value", "domain", "path", "secure", "host_only", "created")

    def __init__(self, name, value, domain, path, secure, host_only, created):
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.host_only = host_only
        self.created = created


class CookieStore:
    def __init__(self, max_cookies=None, max_cookies_per_domain=None):
        for label, v in (("max_cookies", max_cookies), ("max_cookies_per_domain", max_cookies_per_domain)):
            if v is None:
                continue
            if type(v) is not int:
                raise TypeError(label)
            if v < 0:
                raise ValueError(label)
        self.max_cookies = max_cookies
        self.max_cookies_per_domain = max_cookies_per_domain
        self._items = []
        self._tick = 0

    def _clock(self):
        self._tick += 1
        return self._tick

    def set(self, name, value, domain="", path="/", secure=False):
        host_only = False
        stored_domain = domain.lower() if domain else ""
        self._upsert(_C(name, value, stored_domain, path or "/", secure, host_only, self._clock()))
        self._evict()

    def _key(self, c):
        return (c.name, c.domain, c.path)

    def _upsert(self, c):
        for i, old in enumerate(self._items):
            if self._key(old) == self._key(c):
                self._items[i] = c
                return
        self._items.append(c)

    def _evict(self):
        # BUG: evicts newest (keeps oldest). SPEC: drop oldest creation first.
        if self.max_cookies_per_domain is not None:
            by = {}
            for c in self._items:
                by.setdefault(c.domain, []).append(c)
            keep = []
            for cs in by.values():
                cs.sort(key=lambda c: c.created)
                keep.extend(cs[: self.max_cookies_per_domain])
            self._items = keep
        if self.max_cookies is not None and len(self._items) > self.max_cookies:
            self._items.sort(key=lambda c: c.created)
            self._items = self._items[: self.max_cookies]

    def _path_match(self, cookie_path, req_path):
        # BUG: "/sub" matches "/submarine"
        return req_path.startswith(cookie_path)

    def _domain_match(self, c, host):
        host = host.lower()
        if c.domain == "":
            return True
        return host == c.domain or host.endswith("." + c.domain)

    def cookies_for(self, host, path, https=False):
        out = []
        for c in self._items:
            if c.secure and not https:
                continue
            if not self._domain_match(c, host):
                continue
            if not self._path_match(c.path, path):
                continue
            out.append(c)
        out.sort(key=lambda c: (-len(c.path), c.created))
        return out

    def header_for(self, host, path, https=False):
        return "; ".join(f"{c.name}={c.value}" for c in self.cookies_for(host, path, https))

    def extract(self, host, path, set_cookie, https=False):
        parts = [p.strip() for p in set_cookie.split(";")]
        if not parts or "=" not in parts[0]:
            return
        name, value = parts[0].split("=", 1)
        domain = ""
        cpath = None
        secure = False
        max_age = None
        for p in parts[1:]:
            if not p:
                continue
            if "=" in p:
                k, v = p.split("=", 1)
            else:
                k, v = p, ""
            k = k.strip().lower()
            v = v.strip()
            if k == "domain":
                if v == "":
                    return
                domain = v.lstrip(".")
            elif k == "path":
                if v == "":
                    return
                cpath = v
            elif k == "max-age":
                if v == "":
                    return
                try:
                    max_age = int(v)
                except ValueError:
                    return
            elif k == "secure":
                secure = True
        if cpath is None or not str(cpath).startswith("/"):
            cpath = path.rsplit("/", 1)[0] or "/"
        if name.startswith("__Secure-") and (not secure or not https):
            return
        if name.startswith("__Host-") and (not secure or not https or domain or cpath != "/"):
            return
        if max_age is not None and max_age <= 0:
            # BUG: still stores instead of deleting
            self.set(name, value, domain=domain, path=cpath, secure=secure)
            return
        self.set(name, value, domain=domain, path=cpath, secure=secure)

    def delete(self, name, domain=None, path=None):
        def keep(c):
            if c.name != name:
                return True
            if domain is not None and c.domain != domain.lower():
                return True
            if path is not None and c.path != path:
                return True
            return False

        self._items = [c for c in self._items if keep(c)]

    def __getitem__(self, name):
        hits = [c for c in self._items if c.name == name]
        if not hits:
            raise KeyError(name)
        if len(hits) > 1:
            raise CookieConflict(name)
        return hits[0].value
