"""xAI list-price USD for graff-evals (not SuperGrok's $0.0000 footer).

Token bands match src/pricing.zig / pricing_cache.usdForUsage and the
2026-08 xAI table: grok-4.6 is $2 / $0.50 / $6 per 1M under 200k prompt
tokens, and $4 / $1 / $12 for the whole request at or above. Hosted
server-side tools are extra ($5 / 1k for web_search, x_search,
code_execution).

Graff's `[usage]` line reports `in` inclusive of cache reads.
grok-build's stream `input_tokens` is exclusive of `cache_read_input_tokens`.
"""
from __future__ import annotations

RATES = {
    "grok-4.6": {
        "high_at": 200_000,
        "in": 2.0,
        "cache": 0.50,
        "out": 6.0,
        "high_in": 4.0,
        "high_cache": 1.0,
        "high_out": 12.0,
    },
    "grok-4.5": {
        "high_at": 200_000,
        "in": 2.0,
        "cache": 0.30,
        "out": 6.0,
        "high_in": 4.0,
        "high_cache": 0.60,
        "high_out": 12.0,
    },
    "muse-spark-1.2": {
        "high_at": 0,
        "in": 1.25,
        "cache": 0.125,
        "out": 4.25,
        "high_in": 1.25,
        "high_cache": 0.125,
        "high_out": 4.25,
    },
    "muse-spark-1.2-contributor": {
        "high_at": 0,
        "in": 0.10,
        "cache": 0.01,
        "out": 0.20,
        "high_in": 0.10,
        "high_cache": 0.01,
        "high_out": 0.20,
    },
    "grok-build-0.1": {
        "high_at": 200_000,
        "in": 1.0,
        "cache": 0.20,
        "out": 2.0,
        "high_in": 2.0,
        "high_cache": 0.40,
        "high_out": 4.0,
    },
    "gemini-3.8-flash": {
        "high_at": 0,
        "in": 0.75,
        "cache": 0.075,
        "out": 3.75,
        "high_in": 0.75,
        "high_cache": 0.075,
        "high_out": 3.75,
    },
}

# USD per 1k invocations (xAI Tools Pricing). Token-only tools are 0.
TOOL_PER_1K = {
    "web_search": 5.0,
    "x_search": 5.0,
    "code_execution": 5.0,
    "code_interpreter": 5.0,
    "attachment_search": 10.0,
    "collections_search": 2.50,
    "file_search": 2.50,
}


def rates_for(model: str) -> dict | None:
    if not model:
        return None
    if model in RATES:
        return RATES[model]
    # OpenCode / gateway ids look like xai/grok-4.6
    leaf = model.rsplit("/", 1)[-1]
    if model.startswith("grok-4.6") or leaf.startswith("grok-4.6"):
        return RATES["grok-4.6"]
    if model.startswith("grok-build") or leaf.startswith("grok-build"):
        return RATES["grok-build-0.1"]
    if model.startswith("muse-spark-1.2-contributor") or leaf.startswith("muse-spark-1.2-contributor"):
        return RATES["muse-spark-1.2-contributor"]
    if model.startswith("muse-spark-1.2") or leaf.startswith("muse-spark-1.2"):
        return RATES["muse-spark-1.2"]
    if model.startswith("gemini") or leaf.startswith("gemini"):
        return RATES["gemini-3.8-flash"]
    return None


def ordinary_and_cached(tok_in, tok_cached, inclusive: bool) -> tuple[int, int]:
    tin = int(tok_in or 0)
    cached = int(tok_cached or 0)
    if inclusive:
        return max(tin - cached, 0), cached
    return tin, cached


def convention_for(rec: dict) -> bool:
    """True when `tok_in` includes cache reads (graff [usage])."""
    h = rec.get("harness") or ""
    if h == "grok":
        return False
    if h.startswith("graff"):
        return True
    if h in ("muse",) or h.startswith("muse"):
        return True
    if (rec.get("tok_cached") or 0) > (rec.get("tok_in") or 0):
        return False
    return True


def usd_tokens(model: str, ordinary: int, cached: int, out: int, writes: int = 0) -> float:
    p = rates_for(model)
    if not p:
        return 0.0
    ui, ci, wi = max(ordinary, 0), max(cached, 0), max(writes, 0)
    fo = max(out, 0)
    prompt = ui + ci + wi
    high = p["high_at"] > 0 and prompt >= p["high_at"]
    inn = p["high_in"] if high else p["in"]
    cache = p["high_cache"] if high else p["cache"]
    out_r = p["high_out"] if high else p["out"]
    return (ui * inn + ci * cache + wi * inn + fo * out_r) / 1_000_000.0


def usd_tools(counts: dict | None) -> float:
    if not counts:
        return 0.0
    total = 0.0
    for name, n in counts.items():
        rate = TOOL_PER_1K.get(name)
        if rate is None:
            continue
        total += (int(n or 0) / 1000.0) * rate
    return total


def attach(rec: dict, inclusive: bool | None = None) -> dict:
    """Mutate `rec` with list-price fields. Returns rec."""
    if inclusive is None:
        inclusive = convention_for(rec)
    ordinary, cached = ordinary_and_cached(rec.get("tok_in"), rec.get("tok_cached"), inclusive)
    writes = int(rec.get("tok_writes") or 0)
    out = int(rec.get("tok_out") or 0)
    model = rec.get("model") or ""
    tools = rec.get("tok_tools") or {}
    p = rates_for(model)
    token_usd = usd_tokens(model, ordinary, cached, out, writes)
    tool_usd = usd_tools(tools)
    rec["list_ordinary"] = ordinary
    rec["list_cached"] = cached
    rec["list_out"] = out
    rec["list_prompt"] = ordinary + cached + writes
    rec["list_tokens"] = ordinary + cached + writes + out
    rec["list_token_usd"] = round(token_usd, 6) if p else None
    rec["list_tool_usd"] = round(tool_usd, 6) if p else None
    # Unknown models are not grok-4.6 list price. Leave list_usd unset so the
    # runner can fall back to a harness-reported tok_cost_usd without pretending.
    if p:
        rec["list_usd"] = round(token_usd + tool_usd, 6)
        rec["list_price_kind"] = "xai-list"
    else:
        rec["list_usd"] = None
        rec["list_price_kind"] = "none"
    rec["list_high_band"] = bool(p and p["high_at"] > 0 and rec["list_prompt"] >= p["high_at"])
    return rec


def self_test() -> None:
    # Matches src/pricing_tests.zig "grok-4.6 prices"
    assert abs(usd_tokens("grok-4.6", 10_000, 2_000, 500) - 0.024) < 1e-12
    assert abs(usd_tokens("grok-4.6", 199_999, 0, 0) - 0.399998) < 1e-12
    assert abs(usd_tokens("grok-4.6", 200_000, 0, 1_000) - 0.812) < 1e-12
    assert abs(usd_tokens("grok-4.6", 190_000, 20_000, 0) - 0.78) < 1e-12
    # Graff [usage] is inclusive: 5407 in (512 cached) + 80 out
    o, c = ordinary_and_cached(5407, 512, True)
    assert (o, c) == (4895, 512)
    assert abs(usd_tokens("grok-4.6", o, c, 80) - 0.010526) < 1e-12
    # grok-build stream is exclusive: 4461 in + 11520 cached + 37 out
    o, c = ordinary_and_cached(4461, 11520, False)
    assert (o, c) == (4461, 11520)
    assert abs(usd_tokens("grok-4.6", o, c, 37) - 0.014904) < 1e-12
    assert abs(usd_tools({"x_search": 2, "web_search": 0}) - 0.01) < 1e-12
    rec = attach({"harness": "graff-dev", "model": "grok-4.6", "tok_in": 5407, "tok_cached": 512, "tok_out": 80})
    assert rec["list_usd"] == 0.010526
    rec = attach({"harness": "grok", "model": "grok-4.6", "tok_in": 4461, "tok_cached": 11520, "tok_out": 37})
    assert rec["list_usd"] == 0.014904
    rec = attach({"harness": "opencode", "model": "xai/grok-4.6", "tok_in": 5407, "tok_cached": 512, "tok_out": 80})
    assert rec["list_usd"] == 0.010526
    rec = attach({"harness": "opencode-zen", "model": "opencode/big-pickle", "tok_in": 100, "tok_out": 10})
    assert rec["list_usd"] is None
    assert rec["list_price_kind"] == "none"


if __name__ == "__main__":
    self_test()
    print("list_price self-test ok")
