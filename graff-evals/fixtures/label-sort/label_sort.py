"""Typed label sort — incomplete. Fix the SPEC.md contract."""
import ipaddress
import re


def _natural_key(s):
    parts = re.split(r"(\d+)", s)
    key = []
    for p in parts:
        if p.isdigit():
            key.append((1, int(p)))
        else:
            key.append((0, p))
    return key


def _classify(s):
    # BUG: leading whitespace is parsed as typed
    t = s.strip()
    low = t.lower()
    if low in ("+inf", "inf", "infinity"):
        return (0, 0.0)
    if low in ("-inf", "-infinity"):
        return (2, 0.0)
    # BUG: NaN treated as numeric
    if low == "nan":
        return (1, float("nan"))
    try:
        if re.fullmatch(r"[+-]?\d+(\.\d+)?([eE][+-]?\d+)?", t):
            return (1, float(t))
    except ValueError:
        pass
    m = re.fullmatch(r"([+-]?\d+(?:\.\d+)?)(ms|s|m|h)", t)
    if m:
        n = float(m.group(1))
        unit = {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[m.group(2)]
        return (3, n * unit)
    m = re.fullmatch(r"([+-]?\d+(?:\.\d+)?)(B|Ki|Mi|Gi)", t)
    if m:
        n = float(m.group(1))
        unit = {"B": 1, "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3}[m.group(2)]
        return (4, n * unit)
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", t)
    if m:
        return (5, tuple(int(x) for x in m.groups()))
    try:
        ip = ipaddress.ip_address(t)
        # BUG: IPv6 (6) before IPv4 (7) — SPEC wants IPv4 first
        fam = 6 if ip.version == 4 else 5.5
        return (fam, int(ip))
    except ValueError:
        pass
    return (9, _natural_key(s))


def sort_labels(values):
    return sorted(values, key=lambda s: (_classify(s), _natural_key(s)))
