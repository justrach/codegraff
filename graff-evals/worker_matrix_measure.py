"""Measurement for private root/worker comparisons; no inferred model prices."""
from decimal import Decimal
import json
import statistics


def read_rows(path):
    rows, malformed = [], 0
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError("Expected an event object")
            rows.append(value)
        except ValueError:
            malformed += 1
    return rows, malformed


def price_rows(rows, rates):
    if not rows:
        return Decimal(0)
    if rates is None:
        return None
    total = Decimal(0)
    for row in rows:
        incoming, outgoing = row["input_tokens"], row["output_tokens"]
        cached, written = row.get("cache_read_tokens", 0), row.get("cache_write_tokens", 0)
        if (min(incoming, outgoing, cached, written) < 0 or cached + written > incoming
                or incoming > rates["max_input"]):
            return None
        write = rates["write_1h"] if row.get("cache_ttl") == "1h" else rates["write"]
        total += (
            Decimal(incoming - cached - written) * Decimal(rates["input"])
            + Decimal(cached) * Decimal(rates["cached"])
            + Decimal(written) * Decimal(write)
            + Decimal(outgoing) * Decimal(rates["output"])
        ) / 1000000
    return total


def measure(events, traces, arm, worker_count, malformed=0):
    terminal = next((e for e in reversed(events) if e.get("type") == "turn"), {})
    usage = [r for r in traces if r.get("ev") == "usage"]
    api = [r for r in traces if r.get("ev") == "api"]
    roots = [r for r in usage if r.get("from_sub") is False]
    children = [r for r in usage if r.get("from_sub") is True]
    routes = [e for e in events if e.get("type") == "agent_route"]
    completions = [e for e in events if e.get("type") == "agent_usage"]
    root, worker = arm["root"], arm.get("worker")

    def identity(row, wanted, model_key="model"):
        return wanted is not None and row.get("provider") == wanted["provider"] and row.get(model_key) == wanted["model"]

    routing_ok = (
        bool(roots) and len(roots) + len(children) == len(usage)
        and all(identity(r, root) for r in roots)
        and all(identity(r, worker) for r in children)
        and all(identity(r, worker, "resolved_model") for r in routes))
    if worker:
        # Each routed worker needs an observed response, not just a spawn receipt.
        labels = {r.get("agent") for r in children}
        delegation_ok = (len(routes) == len(completions) == worker_count
                         and len(labels - {None}) == worker_count)
    else:
        delegation_ok = not children and not routes and not any(
            r.get("ev") == "tool" and r.get("name") in ("subagent", "workflow")
            for r in traces)
    valid_tokens = all(
        all(type(r.get(k, 0)) is int and r.get(k, 0) >= 0 for k in (
            "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"))
        and "input_tokens" in r and "output_tokens" in r
        and r.get("cache_read_tokens", 0) + r.get("cache_write_tokens", 0) <= r["input_tokens"]
        for r in usage)
    valid_counters = all(type(terminal.get(k)) is int and terminal[k] >= 0 for k in (
        "api_calls", "input_tokens", "output_tokens", "missing_usage_calls",
        "unreported_failed_attempts", "unpriced_calls", "subscription_calls"))
    token_complete = bool(
        not malformed and usage and valid_tokens and valid_counters
        and len(api) == len(usage) == terminal.get("api_calls")
        and not any(r.get("is_error") for r in api)
        and terminal.get("missing_usage_calls") == 0
        and terminal.get("unreported_failed_attempts") == 0
        and terminal.get("input_tokens") == sum(r["input_tokens"] for r in usage)
        and terminal.get("output_tokens") == sum(r["output_tokens"] for r in usage))
    native = terminal.get("cost_usd")
    numeric_native = type(native) in (int, float) and Decimal(str(native)).is_finite() and native >= 0
    native_complete = bool(
        token_complete and routing_ok and numeric_native
        and terminal.get("usage_complete") is True
        and terminal.get("unpriced_calls") == 0
        and terminal.get("subscription_calls") == 0)
    estimates = {}
    if token_complete and routing_ok:
        for role, rows in (("root", roots), ("worker", children)):
            value = price_rows(rows, arm.get("prices", {}).get(role))
            estimates[role] = str(value) if value is not None else None
    full_estimate = None
    if estimates and all(v is not None for v in estimates.values()):
        full_estimate = str(sum((Decimal(v) for v in estimates.values()), Decimal(0)))
    return {
        "routing_ok": bool(routing_ok), "delegation_ok": bool(delegation_ok),
        "turn_complete": terminal.get("complete") is True,
        "token_usage_complete": token_complete, "native_cost_complete": native_complete,
        "native_full_cost_usd": native if native_complete else None,
        "native_known_subtotal_usd": native if numeric_native else None,
        "unpriced_calls": terminal.get("unpriced_calls"),
        "subscription_calls": terminal.get("subscription_calls"),
        "missing_usage_calls": terminal.get("missing_usage_calls"),
        "unreported_failed_attempts": terminal.get("unreported_failed_attempts"),
        "api_attempts": len(api), "failed_api_attempts": sum(bool(r.get("is_error")) for r in api),
        "root_calls": len(roots), "worker_calls": len(children),
        "worker_routes": routes, "worker_completions": completions,
        "estimated_role_costs_usd": estimates, "api_equivalent_estimate_usd": full_estimate,
        "pricing_assumptions": arm.get("prices", {}),
        "known_tokens": {
            role: {field: sum(r.get(field, 0) for r in selected)
                   for field in ("input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens")}
            for role, selected in (("root", roots), ("workers", children))
        } if valid_tokens else {},
    }


def summarize(results):
    groups = {}
    for key in sorted({(r["task"], r["arm"]) for r in results}):
        trials = [r for r in results if (r["task"], r["arm"]) == key]
        group = {"task": key[0], "arm": key[1], "attempted": len(trials),
                 "passed": sum(r["passed"] for r in trials),
                 "mean_seconds": statistics.mean(r["seconds"] for r in trials)}
        for field in ("native_full_cost_usd", "api_equivalent_estimate_usd"):
            values = [Decimal(str(r[field])) for r in trials if r[field] is not None]
            group["mean_" + field] = str(sum(values, Decimal(0)) / len(trials)) if len(values) == len(trials) else None
        role_means = {}
        for role in ("root", "worker"):
            values = [r.get("estimated_role_costs_usd", {}).get(role) for r in trials]
            role_means[role] = (
                str(sum((Decimal(str(v)) for v in values), Decimal(0)) / len(trials))
                if all(v is not None for v in values) else None)
        group["mean_estimated_role_costs_usd"] = role_means
        groups[key] = group
    return list(groups.values())
