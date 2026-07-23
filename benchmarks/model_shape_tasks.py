"""Synthetic fixtures for the root/worker model-shape benchmark."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Task:
    name: str
    source_name: str
    source: str
    visible_tests: str
    visible_count: int
    hidden_grader: str
    hidden_count: int
    request: str



TASKS = (
    Task(
        name="expiring_lru",
        source_name="lease_cache.py",
        source="""\
from collections import OrderedDict


class ExpiringLRU:
    def __init__(self, capacity, ttl, clock):
        self.capacity = capacity
        self.ttl = ttl
        self.clock = clock
        self._items = OrderedDict()

    def put(self, key, value):
        self._items[key] = (value, self.clock() + self.ttl)

    def get(self, key):
        return self._items[key][0]

    def purge_expired(self):
        return 0

    def keys(self):
        return list(self._items)

    def __len__(self):
        return len(self._items)
""",
        visible_tests="""\
import unittest
from lease_cache import ExpiringLRU


class FakeClock:
    def __init__(self):
        self.now = 0.0
    def __call__(self):
        return self.now


class CacheTests(unittest.TestCase):
    def test_get_refreshes_recency_and_capacity_evicts_lru(self):
        clock = FakeClock()
        cache = ExpiringLRU(2, 10, clock)
        cache.put("a", 1)
        cache.put("b", 2)
        self.assertEqual(cache.get("a"), 1)
        cache.put("c", 3)
        with self.assertRaises(KeyError):
            cache.get("b")
        self.assertEqual(cache.keys(), ["c", "a"])

    def test_expiration_is_lazy_and_boundary_is_expired(self):
        clock = FakeClock()
        cache = ExpiringLRU(2, 5, clock)
        cache.put("a", 1)
        clock.now = 5
        with self.assertRaises(KeyError):
            cache.get("a")
        self.assertEqual(len(cache), 0)

    def test_overwrite_refreshes_ttl_and_recency(self):
        clock = FakeClock()
        cache = ExpiringLRU(2, 5, clock)
        cache.put("a", 1)
        clock.now = 4
        cache.put("a", 9)
        clock.now = 6
        self.assertEqual(cache.get("a"), 9)

    def test_purge_reports_removed_items(self):
        clock = FakeClock()
        cache = ExpiringLRU(3, 2, clock)
        cache.put("a", 1)
        cache.put("b", 2)
        clock.now = 2
        self.assertEqual(cache.purge_expired(), 2)
        self.assertEqual(cache.keys(), [])


if __name__ == "__main__":
    unittest.main()
""",
        visible_count=4,
        hidden_grader="""\
import json
from lease_cache import ExpiringLRU

results = {}
def check(name, fn):
    try:
        fn()
        results[name] = True
    except Exception as exc:
        results[name] = f"{type(exc).__name__}: {exc}"

class Clock:
    def __init__(self): self.now = 0
    def __call__(self): return self.now

def validation():
    for capacity, ttl in ((0, 1), (-1, 1), (1, 0), (1, -1)):
        try:
            ExpiringLRU(capacity, ttl, Clock())
        except (ValueError, TypeError):
            continue
        raise AssertionError((capacity, ttl))

def expired_before_capacity():
    c = Clock(); x = ExpiringLRU(2, 2, c)
    x.put("old", 1); c.now = 1; x.put("live", 2); c.now = 2
    x.put("new", 3)
    assert x.keys() == ["new", "live"]

def order_and_len_purge():
    c = Clock(); x = ExpiringLRU(3, 2, c)
    x.put("a", 1); c.now = 1; x.put("b", 2)
    assert x.keys() == ["b", "a"]
    c.now = 2
    assert len(x) == 1 and x.keys() == ["b"]

def missing_key():
    x = ExpiringLRU(1, 2, Clock())
    try: x.get("missing")
    except KeyError as exc: assert exc.args == ("missing",)
    else: raise AssertionError("missing key did not raise")

def clock_called_once_per_operation():
    calls = [0]
    def clock():
        calls[0] += 1
        return 0
    x = ExpiringLRU(2, 2, clock)
    x.put("a", 1); before = calls[0]; x.get("a")
    assert calls[0] == before + 1

for item in (
    ("validation", validation),
    ("expired_before_capacity", expired_before_capacity),
    ("order_and_len_purge", order_and_len_purge),
    ("missing_key", missing_key),
    ("clock_called_once_per_operation", clock_called_once_per_operation),
): check(*item)
print(json.dumps(results, sort_keys=True))
""",
        hidden_count=5,
        request="""\
Repair `lease_cache.py`. The required behavior is an expiring LRU cache:
capacity and ttl must be positive; `put` refreshes TTL and MRU position;
`get` returns a live value and moves it to MRU; an item is expired when
`clock() >= deadline`; expired entries never consume capacity; `purge_expired`
returns the number removed; `keys` returns live keys MRU-to-LRU; and `len`
counts only live entries. Preserve normal `KeyError(key)` behavior.
""",
    ),
    Task(
        name="route_precedence",
        source_name="router.py",
        source="""\
from urllib.parse import urlsplit


class Router:
    def __init__(self):
        self._routes = []

    def add(self, method, pattern, handler):
        self._routes.append((method, pattern, handler))

    def resolve(self, method, target):
        path = urlsplit(target).path
        for route_method, pattern, handler in self._routes:
            if route_method == method and pattern == path:
                return handler, {}
        raise LookupError((method, target))
""",
        visible_tests="""\
import unittest
from router import Router


class RouterTests(unittest.TestCase):
    def test_params_and_query(self):
        r = Router()
        r.add("GET", "/teams/{team}/repos/{repo}", "repo")
        self.assertEqual(
            r.resolve("get", "/teams/acme/repos/widget?tab=issues"),
            ("repo", {"team": "acme", "repo": "widget"}),
        )

    def test_static_route_beats_parameter_route(self):
        r = Router()
        r.add("GET", "/users/{name}", "profile")
        r.add("GET", "/users/me", "self")
        self.assertEqual(r.resolve("GET", "/users/me"), ("self", {}))

    def test_head_falls_back_to_get(self):
        r = Router()
        r.add("GET", "/health", "ok")
        self.assertEqual(r.resolve("HEAD", "/health"), ("ok", {}))

    def test_duplicate_replaces_handler(self):
        r = Router()
        r.add("POST", "/jobs/{id}", "old")
        r.add("post", "/jobs/{id}", "new")
        self.assertEqual(r.resolve("POST", "/jobs/7"), ("new", {"id": "7"}))


if __name__ == "__main__":
    unittest.main()
""",
        visible_count=4,
        hidden_grader="""\
import json
from router import Router

results = {}
def check(name, fn):
    try:
        fn(); results[name] = True
    except Exception as exc:
        results[name] = f"{type(exc).__name__}: {exc}"

def utf8_decode():
    r = Router(); r.add("GET", "/cafes/{name}", "cafe")
    assert r.resolve("GET", "/cafes/caf%C3%A9") == ("cafe", {"name": "café"})

def reject_encoded_separator():
    r = Router(); r.add("GET", "/files/{name}", "file")
    try: r.resolve("GET", "/files/a%2Fb")
    except (LookupError, ValueError): return
    raise AssertionError("encoded slash accepted")

def validate_patterns():
    bad = ("relative", "/x/{bad-name}", "/x/{id}/{id}", "/x/{oops")
    for pattern in bad:
        try: Router().add("GET", pattern, "x")
        except (ValueError, TypeError): continue
        raise AssertionError(pattern)

def equal_specificity_is_registration_order():
    r = Router()
    r.add("GET", "/{left}/fixed", "first")
    r.add("GET", "/fixed/{right}", "second")
    assert r.resolve("GET", "/fixed/fixed")[0] == "first"

def explicit_head_wins():
    r = Router()
    r.add("GET", "/health", "get")
    r.add("HEAD", "/health", "head")
    assert r.resolve("HEAD", "/health") == ("head", {})

for item in (
    ("utf8_decode", utf8_decode),
    ("reject_encoded_separator", reject_encoded_separator),
    ("validate_patterns", validate_patterns),
    ("equal_specificity_is_registration_order", equal_specificity_is_registration_order),
    ("explicit_head_wins", explicit_head_wins),
): check(*item)
print(json.dumps(results, sort_keys=True))
""",
        hidden_count=5,
        request="""\
Repair `router.py`. Methods are case-insensitive. Patterns start with `/` and
contain literal segments or unique `{identifier}` parameters. Reject malformed
patterns. Ignore the query string, percent-decode each target segment as strict
UTF-8, and reject a decoded slash, NUL, or malformed escape. Match the route
with the most literal segments; preserve registration order on ties. Re-adding
the same method/pattern replaces its handler without changing precedence.
An explicit HEAD route wins, otherwise HEAD may fall back to GET.
""",
    ),
    Task(
        name="atomic_inventory",
        source_name="inventory.py",
        source="""\
class OrderConflict(Exception):
    pass


class InsufficientStock(Exception):
    pass


class Inventory:
    def __init__(self, stock):
        self._stock = dict(stock)
        self._orders = {}

    def reserve(self, order_id, request):
        for sku, quantity in request.items():
            self._stock[sku] = self._stock.get(sku, 0) - quantity
        receipt = {"order_id": order_id, "items": dict(request)}
        self._orders[order_id] = receipt
        return receipt

    def release(self, order_id):
        receipt = self._orders.pop(order_id)
        for sku, quantity in receipt["items"].items():
            self._stock[sku] = self._stock.get(sku, 0) + quantity
        return True

    def snapshot(self):
        return self._stock
""",
        visible_tests="""\
import unittest
from inventory import Inventory, InsufficientStock, OrderConflict


class InventoryTests(unittest.TestCase):
    def test_atomic_failure(self):
        x = Inventory({"a": 3, "b": 1})
        with self.assertRaises(InsufficientStock):
            x.reserve("o1", {"a": 2, "b": 2})
        self.assertEqual(x.snapshot(), {"a": 3, "b": 1})

    def test_idempotent_same_order(self):
        x = Inventory({"a": 3})
        one = x.reserve("o1", {"a": 2})
        two = x.reserve("o1", {"a": 2})
        self.assertEqual(one, two)
        self.assertEqual(x.snapshot(), {"a": 1})

    def test_conflicting_reuse(self):
        x = Inventory({"a": 3})
        x.reserve("o1", {"a": 1})
        with self.assertRaises(OrderConflict):
            x.reserve("o1", {"a": 2})
        self.assertEqual(x.snapshot(), {"a": 2})

    def test_release_is_idempotent(self):
        x = Inventory({"a": 3})
        x.reserve("o1", {"a": 2})
        self.assertTrue(x.release("o1"))
        self.assertFalse(x.release("o1"))
        self.assertEqual(x.snapshot(), {"a": 3})


if __name__ == "__main__":
    unittest.main()
""",
        visible_count=4,
        hidden_grader="""\
import json
from inventory import Inventory, InsufficientStock, OrderConflict

results = {}
def check(name, fn):
    try:
        fn(); results[name] = True
    except Exception as exc:
        results[name] = f"{type(exc).__name__}: {exc}"

def validate_stock_and_request():
    for stock in ({"a": -1}, {"a": True}, {"a": 1.5}):
        try: Inventory(stock)
        except (ValueError, TypeError): continue
        raise AssertionError(stock)
    x = Inventory({"a": 2})
    for req in ({}, {"a": 0}, {"a": -1}, {"a": True}, {"a": 1.5}):
        try: x.reserve("o", req)
        except (ValueError, TypeError): continue
        raise AssertionError(req)

def normalized_idempotency():
    x = Inventory({"a": 3, "b": 4})
    first = x.reserve("o", {"a": 1, "b": 2})
    second = x.reserve("o", {"b": 2, "a": 1})
    assert first == second and x.snapshot() == {"a": 2, "b": 2}

def missing_sku_is_atomic():
    x = Inventory({"a": 3})
    try: x.reserve("o", {"a": 1, "missing": 1})
    except InsufficientStock: pass
    else: raise AssertionError("missing sku accepted")
    assert x.snapshot() == {"a": 3}

def defensive_copies():
    initial = {"a": 3}; request = {"a": 1}
    x = Inventory(initial); receipt = x.reserve("o", request)
    initial["a"] = 99; request["a"] = 99; receipt["items"]["a"] = 99
    assert x.snapshot() == {"a": 2}
    x.release("o")
    assert x.snapshot() == {"a": 3}

def released_id_stays_idempotent():
    x = Inventory({"a": 3})
    receipt = x.reserve("o", {"a": 1})
    x.release("o")
    assert x.reserve("o", {"a": 1}) == receipt
    assert x.snapshot() == {"a": 3}
    try: x.reserve("o", {"a": 2})
    except OrderConflict: return
    raise AssertionError("released id accepted conflicting request")

for item in (
    ("validate_stock_and_request", validate_stock_and_request),
    ("normalized_idempotency", normalized_idempotency),
    ("missing_sku_is_atomic", missing_sku_is_atomic),
    ("defensive_copies", defensive_copies),
    ("released_id_stays_idempotent", released_id_stays_idempotent),
): check(*item)
print(json.dumps(results, sort_keys=True))
""",
        hidden_count=5,
        request="""\
Repair `inventory.py`. Initial stock must contain only nonnegative plain ints.
Reservations require a nonempty order id and nonempty mapping of positive plain
int quantities. A reservation is atomic: insufficient or missing stock raises
`InsufficientStock` without mutation. Repeating an order id with the same
normalized request is idempotent, even after release; a different request raises
`OrderConflict`. Release restores stock at most once and returns whether it did
work. Caller mutations must never alter internal state; `snapshot` is a copy.
""",
    ),
)

