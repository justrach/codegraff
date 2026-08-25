# CookieStore (DeepSWE `httpx-deterministic-cookie-store`, distilled)

`cookie_store.py` must expose `CookieConflict` and `CookieStore`.

Constructor: `CookieStore(max_cookies=None, max_cookies_per_domain=None)`.
Non-ints raise `TypeError`. Negative ints raise `ValueError`.

`set(name, value, domain="", path="/", secure=False)` stores a cookie.
`domain=""` cookies are not host-only: they are sent to any host (path +
Secure still apply). A non-empty domain is stored case-insensitively and
matches that host plus subdomains.

Path match: `Path=/sub` matches `/sub` and `/sub/x` but **not** `/submarine`.
A `Path` that is empty or does not start with `/` uses the request default
path (everything through the last `/`, or `/`).

`Secure` cookies are sent only when `https=True`.

`__Secure-` names require `Secure` and an https origin. `__Host-` names
additionally require no Domain attribute and `Path=/`.

`extract(host, path, set_cookie, https=False)` parses one `Set-Cookie` line
(`name=value; Attr=...`). Ignore the cookie if `Domain`, `Path`, or `Max-Age`
appears with an empty value. `Max-Age` is an int; `Max-Age<=0` **deletes** a
matching cookie and does not store. Unknown attributes are ignored.

When a cookie is replaced (same name, domain, path) it is treated as newly
created for eviction order. When limits are exceeded, evict **oldest
creation first**, per-domain then global.

`cookies_for(host, path, https=False)` returns matching cookies ordered by
longer path first, then older creation. `header_for(...)` joins them as
`name=value; name=value`.

`store["name"]` raises `CookieConflict` if more than one stored cookie has
that name.
