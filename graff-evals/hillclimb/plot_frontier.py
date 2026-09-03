#!/usr/bin/env python3
"""Draw 2D Pareto projections (wall vs $, calls vs $) from a graff-evals JSONL.

Lower-left is better. Does not plot REPL first-token (composer echo).
Mixed-model points (list_price_kind != xai-list) are drawn hollow and must
not be read as the same-model grok-4.6 series.

  ./plot_frontier.py results/run-….jsonl -o hillclimb/frontier-YYYYMMDD.svg
"""
from __future__ import annotations

import argparse, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hillclimb import bucket, load_jsonl  # noqa: E402

COLORS = {
    "graff-dev": ("#059669", "#047857"),
    "graff-dev-repl": ("#ffffff", "#64748b"),
    "grok": ("#334155", "#1e293b"),
    "opencode": ("#2563eb", "#1d4ed8"),
    "opencode-zen": ("#ffffff", "#2563eb"),
    "dsh": ("#7c3aed", "#5b21b6"),
    "dsh-deepseek": ("#ffffff", "#7c3aed"),
    "dsh-grok": ("#7c3aed", "#5b21b6"),
    "gemini-cli": ("#4285f4", "#1a73e8"),
    "pi-dev": ("#f97316", "#ea580c"),
    "pi-codegraff": ("#f97316", "#ea580c"),
}


def pareto(points, xk, yk):
    """Minimize-minimize frontier. points: list of (name, xs)."""
    ordered = sorted(points, key=lambda p: (p[1][xk], p[1][yk]))
    front, best_y = [], float("inf")
    for name, b in ordered:
        y = b[yk]
        if y < best_y - 1e-12:
            front.append(name)
            best_y = y
    return set(front)


def _scale(v, lo, hi, a, b):
    if hi <= lo:
        return (a + b) / 2
    t = (v - lo) / (hi - lo)
    return a + t * (b - a)


def render(by: dict, title: str, subtitle: str) -> str:
    rows = []
    for h, b in by.items():
        if b["n"] == 0:
            continue
        if b.get("usd_n", 0) == 0:
            continue  # no measured $ — do not plot as a $0 winner
        rows.append((h, {
            "wall_s": b["wall_s"],
            "tok_calls": b["tok_calls"],
            "list_usd": b["list_usd"],
            "pass": b["pass"],
            "list_tokens": b["list_tokens"],
        }))
    if not rows:
        raise SystemExit("no harness rows")

    wall_front = pareto(rows, "wall_s", "list_usd")
    call_front = pareto(rows, "tok_calls", "list_usd")
    walls = [b["wall_s"] for _, b in rows]
    calls = [b["tok_calls"] for _, b in rows]
    usds = [b["list_usd"] for _, b in rows]
    wlo, whi = min(walls) * 0.85, max(walls) * 1.12 or 1
    clo, chi = min(calls) - 1.2, max(calls) + 1.2
    ulo, uhi = 0.0, max(usds) * 1.15 or 0.01

    def xy_wall(b):
        return _scale(b["wall_s"], wlo, whi, 72, 412), _scale(b["list_usd"], ulo, uhi, 342, 86)

    def xy_call(b):
        return _scale(b["tok_calls"], clo, chi, 500, 840), _scale(b["list_usd"], ulo, uhi, 342, 86)

    ticks_u = [ulo + (uhi - ulo) * i / 4 for i in range(5)]
    ticks_w = [wlo + (whi - wlo) * i / 4 for i in range(5)]
    # integer-ish call ticks
    cmin, cmax = int(round(min(calls))), int(round(max(calls)))
    ticks_c = list(range(cmin, cmax + 1)) or [0]

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 880 490" width="880" height="490" role="img">',
        f'<title>{title}</title>',
        f'<rect width="880" height="490" fill="#ffffff"/>',
        f'<text x="20" y="22" font-size="16" font-weight="700" fill="#0f172a" font-family="ui-sans-serif, system-ui, sans-serif">{title}</text>',
        f'<text x="20" y="40" font-size="11" fill="#64748b" font-family="ui-sans-serif, system-ui, sans-serif">{subtitle}</text>',
        '<rect x="72" y="62" width="340" height="280" fill="#fafcfb" stroke="#d1d5db"/>',
        '<rect x="500" y="62" width="340" height="280" fill="#fafcfb" stroke="#d1d5db"/>',
        '<text x="72" y="56" font-size="13" font-weight="600" fill="#0f172a" font-family="ui-sans-serif, system-ui, sans-serif">wall vs list$</text>',
        '<text x="500" y="56" font-size="13" font-weight="600" fill="#0f172a" font-family="ui-sans-serif, system-ui, sans-serif">calls vs list$</text>',
        '<text x="242" y="376" text-anchor="middle" font-size="12" fill="#334155" font-family="ui-sans-serif, system-ui, sans-serif">wall (s) →</text>',
        '<text x="670" y="376" text-anchor="middle" font-size="12" fill="#334155" font-family="ui-sans-serif, system-ui, sans-serif">tool calls →</text>',
    ]
    for yv in ticks_u:
        y = _scale(yv, ulo, uhi, 342, 86)
        parts.append(f'<line x1="72" y1="{y:.1f}" x2="412" y2="{y:.1f}" stroke="#e5e7eb"/>')
        parts.append(f'<line x1="500" y1="{y:.1f}" x2="840" y2="{y:.1f}" stroke="#e5e7eb"/>')
        parts.append(f'<text x="64" y="{y + 4:.1f}" text-anchor="end" font-size="11" fill="#64748b" font-family="ui-sans-serif, system-ui, sans-serif">${yv:.3f}</text>')
        parts.append(f'<text x="492" y="{y + 4:.1f}" text-anchor="end" font-size="11" fill="#64748b" font-family="ui-sans-serif, system-ui, sans-serif">${yv:.3f}</text>')
    for xv in ticks_w:
        x = _scale(xv, wlo, whi, 72, 412)
        parts.append(f'<line x1="{x:.1f}" y1="62" x2="{x:.1f}" y2="342" stroke="#e5e7eb"/>')
        parts.append(f'<text x="{x:.1f}" y="358" text-anchor="middle" font-size="11" fill="#64748b" font-family="ui-sans-serif, system-ui, sans-serif">{xv:.0f}s</text>')
    for xv in ticks_c:
        x = _scale(xv, clo, chi, 500, 840)
        parts.append(f'<line x1="{x:.1f}" y1="62" x2="{x:.1f}" y2="342" stroke="#e5e7eb"/>')
        parts.append(f'<text x="{x:.1f}" y="358" text-anchor="middle" font-size="11" fill="#64748b" font-family="ui-sans-serif, system-ui, sans-serif">{xv}</text>')

    # calls-vs-$ frontier polyline
    call_pts = sorted(
        [(n, b) for n, b in rows if n in call_front],
        key=lambda p: p[1]["tok_calls"],
    )
    if len(call_pts) >= 2:
        d = " ".join(f"{xy_call(b)[0]:.1f},{xy_call(b)[1]:.1f}" for _, b in call_pts)
        parts.append(f'<polyline points="{d}" fill="none" stroke="#059669" stroke-width="1.6" stroke-dasharray="5 4" opacity="0.85"/>')

    legend_y = 410
    for h, b in rows:
        fill, stroke = COLORS.get(h, ("#94a3b8", "#475569"))
        hollow = h.endswith("-zen") or h.endswith("-deepseek") or h.endswith("-repl")
        xw, yw = xy_wall(b)
        xc, yc = xy_call(b)
        dash = ' stroke-dasharray="2.5 2"' if hollow else ""
        r = 5.5 if hollow else 6.5
        parts.append(f'<circle cx="{xw:.1f}" cy="{yw:.1f}" r="{r}" fill="{fill}" stroke="{stroke}" stroke-width="1.4"{dash}/>')
        parts.append(f'<text x="{xw + 10:.1f}" y="{yw - 8:.1f}" font-size="11" font-weight="600" fill="{stroke}" font-family="ui-sans-serif, system-ui, sans-serif">{h}  {b["wall_s"]:.1f}s · ${b["list_usd"]:.4f}</text>')
        parts.append(f'<circle cx="{xc:.1f}" cy="{yc:.1f}" r="{r}" fill="{fill}" stroke="{stroke}" stroke-width="1.4"{dash}/>')
        parts.append(f'<text x="{xc + 10:.1f}" y="{yc - 8:.1f}" font-size="11" font-weight="600" fill="{stroke}" font-family="ui-sans-serif, system-ui, sans-serif">{h}  {b["tok_calls"]} · ${b["list_usd"]:.4f}</text>')
        on = []
        if h in wall_front:
            on.append("wall/$")
        if h in call_front:
            on.append("calls/$")
        mark = "on " + " + ".join(on) if on else "interior"
        parts.append(f'<circle cx="28" cy="{legend_y}" r="{r}" fill="{fill}" stroke="{stroke}" stroke-width="1.4"{dash}/>')
        parts.append(f'<text x="40" y="{legend_y + 4}" font-size="12" fill="#0f172a" font-family="ui-sans-serif, system-ui, sans-serif">{h} — {b["pass"]} · {mark}</text>')
        legend_y += 20

    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("jsonl")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--title", default="Eval frontier · lower-left is better")
    ap.add_argument("--subtitle", default="Pass is a tie-break, not an axis. Hollow = mixed-model / REPL. REPL first-token is echo — not plotted.")
    ap.add_argument("--harness", help="comma-separated harness names to keep")
    args = ap.parse_args()
    rows = load_jsonl(args.jsonl)
    if args.harness:
        keep = {h.strip() for h in args.harness.split(",") if h.strip()}
        rows = [r for r in rows if r.get("harness") in keep]
    svg = render(bucket(rows), args.title, args.subtitle)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        f.write(svg)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
