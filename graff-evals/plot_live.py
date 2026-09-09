#!/usr/bin/env python3
"""Publish the live 12-PR board as summary.json + a codegraff.com card.

Palette is the website token set (apps/native/app/appearance.css website theme):
  page #fafaf8 · ink #18231e · accent #059669.

  python3 plot_live.py --from-jsonl   # rebuild summary from local results/
  python3 plot_live.py                # svg + html from summary.json
"""
from __future__ import annotations

import json, os, sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
OUT = REPO / "artifacts" / "graff-evals-live"
TASKS = [
    "graff-195", "graff-726", "graff-727", "graff-servers", "graff-interrupt",
    "graff-acp-pixels", "graff-gemini-ix", "codedb-arch", "codedb-hybrid",
    "turbo-ws-load", "turbo-ws-duplex", "turbo-asgi",
]
LABEL = {
    "graff-dev": "graff",
    "grok": "grok",
    "opencode": "OpenCode",
    "pi-xai": "Pi",
    "exo": "exo",
}
SHORT = {
    "graff-195": "195", "graff-726": "726", "graff-727": "727",
    "graff-servers": "srv", "graff-interrupt": "int",
    "graff-acp-pixels": "acp", "graff-gemini-ix": "gem",
    "codedb-arch": "arch", "codedb-hybrid": "hyb",
    "turbo-ws-load": "load", "turbo-ws-duplex": "dup", "turbo-asgi": "asgi",
}
# Website tokens. Graff owns emerald; others stay in the same forest.
FILL = {
    "graff-dev": "#059669",
    "grok": "#18231e",
    "opencode": "#3d7a5c",
    "pi-xai": "#047857",
    "exo": "#6b8f7a",
}
PAGE, INK, INK2, INK3 = "#fafaf8", "#18231e", "#526157", "#737f75"
ACCENT, TINT, LINE = "#059669", "#e3f3e9", "#d5e0d8"
CORAL = "#c2410c"  # errors only (site rule: coral is not the accent)

JSONL = {
    "graff-dev": [
        (ROOT / "results/run-20260908-173944.jsonl", "graff-dev", None),
        (ROOT / "results/run-20260908-182322.jsonl", "graff-dev", {"graff-195"}),
    ],
    "grok": [
        (ROOT / "results/run-20260908-173944.jsonl", "grok", None),
        (ROOT / "results/run-20260909-011118.jsonl", "grok", None),
    ],
    "opencode": [(ROOT / "results/run-20260909-042501.jsonl", "opencode", None)],
    "pi-xai": [(ROOT / "results/run-20260909-095017.jsonl", None, None)],
    "exo": [(ROOT / "results/run-20260909-095016.jsonl", None, None)],
}


def honest(r: dict) -> float:
    ordinary = int(r.get("list_ordinary") or 0)
    cached = int(r.get("list_cached") or r.get("tok_cached") or 0)
    out = int(r.get("list_out") or r.get("tok_out") or 0)
    return (ordinary * 2 + cached * 0.5 + out * 6) / 1e6


def load_rows(path: Path, harness: str | None, skip: set | None) -> list[dict]:
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        r = json.loads(line)
        if r.get("task") not in TASKS:
            continue
        if harness and r.get("harness") != harness:
            continue
        if skip and r.get("task") in skip:
            continue
        rows.append(r)
    return rows


def score(rows: list[dict]) -> dict:
    by = defaultdict(list)
    for r in rows:
        by[r["task"]].append(r)
    tasks, suite, walls = {}, 0.0, []
    pass_reps = fail_reps = to_ok = to_fail = 0
    for tid in TASKS:
        rs = sorted(by.get(tid, []), key=lambda x: x.get("rep", 0))
        wins = sum(1 for r in rs if r.get("outcome_ok"))
        done = len(rs) >= 3
        ok = wins >= 2 if done else None
        cost = 0.0
        if done and ok:
            cost = sum(honest(r) for r in rs if r.get("outcome_ok"))
            suite += cost
        for r in rs:
            walls.append(r.get("wall_s") or 0)
            if r.get("outcome_ok"):
                pass_reps += 1
            else:
                fail_reps += 1
            if r.get("timed_out"):
                if r.get("outcome_ok"):
                    to_ok += 1
                else:
                    to_fail += 1
        tasks[tid] = {
            "n": len(rs), "wins": wins, "pass": ok,
            "cost": round(cost, 4) if done and ok else 0.0,
            "timeouts": sum(1 for r in rs if r.get("timed_out")),
        }
    return {
        "tasks": tasks,
        "honest_usd": round(suite, 2),
        "pass_reps": pass_reps,
        "n_reps": pass_reps + fail_reps,
        "pass_tasks": sum(1 for t in tasks.values() if t["pass"] is True),
        "n_tasks": sum(1 for t in tasks.values() if t["n"] >= 3),
        "mean_wall_s": round(sum(walls) / max(1, len(walls))),
        "timeout_ok": to_ok,
        "timeout_fail": to_fail,
    }


def build_summary() -> dict:
    harnesses = {}
    for hid, specs in JSONL.items():
        rows = []
        for path, h, skip in specs:
            rows.extend(load_rows(path, h, skip))
        harnesses[hid] = score(rows)
        harnesses[hid]["label"] = LABEL[hid]
        harnesses[hid]["sources"] = [str(p.relative_to(ROOT)) for p, _, _ in specs]
    return {
        "title": "Live evals · 12 gated PRs",
        "date": "2026-09-09",
        "model": "grok-4.6",
        "seat": "SuperGrok",
        "n": 3,
        "score": {
            "task_pass": ">=2/3",
            "cost": "passing reps of passing tasks",
            "band": "$2 / $0.50 cached / $6 out per 1M (official low band)",
            "failed_usd": 0,
            "cash_usd": 0,
        },
        "caveats": [
            "Only graff-195 is G1–G6 certified; the other 11 are published live tasks.",
            "Stored JSONL list$ high-bands the rep sum; headline $ is the official per-request low band.",
            "exo honest $ is a floor: three timeout-ok reps recorded no usage.",
            "Wall is a hang detector. Do not score Graff first-token (boot ›).",
        ],
        "tasks": TASKS,
        "harnesses": harnesses,
    }


def svg(summary: dict) -> str:
    hs = [(k, summary["harnesses"][k]) for k in LABEL]
    W, H = 1600, 900
    max_usd = max(h["honest_usd"] for _, h in hs) or 1
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img">',
        "<title>Live evals · 12 gated PRs · grok-4.6 SuperGrok</title>",
        f'<rect width="{W}" height="{H}" fill="{PAGE}"/>',
        f'<rect x="0" y="0" width="12" height="{H}" fill="{ACCENT}"/>',
        f'<text x="48" y="56" font-size="15" font-weight="700" letter-spacing="3" fill="{ACCENT}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">GRAFF · LIVE EVALS</text>',
        f'<text x="1552" y="56" text-anchor="end" font-size="16" fill="{INK3}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">codegraff.com</text>',
        f'<text x="48" y="108" font-size="44" font-weight="750" fill="{INK}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">12 gated PRs. Same SuperGrok seat.</text>',
        f'<text x="48" y="148" font-size="20" fill="{INK2}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">grok-4.6 · n=3 · pass ≥2/3 · honest list$ on passing reps of passing tasks</text>',
    ]
    card_w, gap, x0, y0 = 276, 18, 48, 184
    for i, (hid, h) in enumerate(hs):
        x = x0 + i * (card_w + gap)
        parts += [
            f'<rect x="{x}" y="{y0}" width="{card_w}" height="168" rx="18" fill="#fff" stroke="{LINE}"/>',
            f'<rect x="{x}" y="{y0}" width="8" height="168" rx="4" fill="{FILL[hid]}"/>',
            f'<text x="{x+28}" y="{y0+36}" font-size="16" font-weight="700" fill="{INK2}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">{h["label"]}</text>',
            f'<text x="{x+28}" y="{y0+96}" font-size="48" font-weight="780" fill="{INK if h["pass_tasks"]==12 else CORAL}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">{h["pass_tasks"]}/{h["n_tasks"]}</text>',
            f'<text x="{x+28}" y="{y0+132}" font-size="18" fill="{ACCENT if hid=="graff-dev" else INK2}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">${h["honest_usd"]:.2f} · {h["mean_wall_s"]}s</text>',
        ]
    parts.append(f'<text x="48" y="392" font-size="15" font-weight="700" letter-spacing="1.4" fill="{INK3}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">HONEST LIST$  ·  LOWER IS BETTER</text>')
    bar_x, bar_w, bar_y = 220, 1100, 420
    for i, (hid, h) in enumerate(hs):
        y = bar_y + i * 44
        w = max(8, int(bar_w * h["honest_usd"] / max_usd))
        parts += [
            f'<text x="48" y="{y+18}" font-size="16" font-weight="650" fill="{INK}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">{h["label"]}</text>',
            f'<rect x="{bar_x}" y="{y}" width="{bar_w}" height="26" rx="13" fill="{TINT}"/>',
            f'<rect x="{bar_x}" y="{y}" width="{w}" height="26" rx="13" fill="{FILL[hid]}"/>',
            f'<text x="{bar_x + w + 12}" y="{y+19}" font-size="15" font-weight="650" fill="{INK}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">${h["honest_usd"]:.2f}</text>',
        ]
    # task grid
    gx, gy, cw, ch = 48, 660, 118, 28
    parts.append(f'<text x="48" y="648" font-size="15" font-weight="700" letter-spacing="1.4" fill="{INK3}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">TASK GRID  ·  FILL = PASS</text>')
    for j, tid in enumerate(TASKS):
        parts.append(f'<text x="{gx + 86 + j*cw + cw/2}" y="{gy - 6}" text-anchor="middle" font-size="12" fill="{INK3}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">{SHORT[tid]}</text>')
    for i, (hid, h) in enumerate(hs):
        parts.append(f'<text x="{gx}" y="{gy + i*ch + 20}" font-size="13" font-weight="650" fill="{INK}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">{h["label"]}</text>')
        for j, tid in enumerate(TASKS):
            cell = h["tasks"][tid]
            ok = cell["pass"] is True
            fill = FILL[hid] if ok else ("#f3d6c8" if cell["pass"] is False else TINT)
            x = gx + 86 + j * cw
            y = gy + i * ch + 4
            parts.append(f'<rect x="{x}" y="{y}" width="{cw-6}" height="{ch-6}" rx="6" fill="{fill}"/>')
            if not ok and cell["pass"] is False:
                parts.append(f'<text x="{x+(cw-6)/2}" y="{y+16}" text-anchor="middle" font-size="11" font-weight="700" fill="{CORAL}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">FAIL</text>')
    parts.append(f'<text x="48" y="872" font-size="14" fill="{INK3}" font-family="Inter, ui-sans-serif, system-ui, sans-serif">Official low band · SuperGrok cash $0 · failed task $0 · only #195 is G1–G6 certified · exo $ is a floor (3 timeout-ok reps had no usage)</text>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def html_card(summary: dict) -> str:
    hs = [(k, summary["harnesses"][k]) for k in LABEL]
    cards = []
    for hid, h in hs:
        tone = CORAL if h["pass_tasks"] < 12 else INK
        cards.append(
            f'<div class="seat"><i style="background:{FILL[hid]}"></i>'
            f'<div class="name">{h["label"]}</div>'
            f'<div class="pass" style="color:{tone}">{h["pass_tasks"]}/{h["n_tasks"]}</div>'
            f'<div class="usd">${h["honest_usd"]:.2f} · {h["mean_wall_s"]}s</div></div>'
        )
    bars = []
    max_usd = max(h["honest_usd"] for _, h in hs) or 1
    for hid, h in hs:
        pct = 100 * h["honest_usd"] / max_usd
        bars.append(
            f'<div class="bar"><span>{h["label"]}</span>'
            f'<div class="track"><b style="width:{pct:.1f}%;background:{FILL[hid]}"></b></div>'
            f'<em>${h["honest_usd"]:.2f}</em></div>'
        )
    grid = ['<div class="grid">']
    grid.append('<div class="ghead"><b></b>' + "".join(f"<b>{SHORT[t]}</b>" for t in TASKS) + "</div>")
    for hid, h in hs:
        cells = []
        for tid in TASKS:
            cell = h["tasks"][tid]
            cls = "ok" if cell["pass"] else ("bad" if cell["pass"] is False else "na")
            cells.append(f'<i class="{cls}" style="--c:{FILL[hid]}"></i>')
        grid.append(f'<div class="grow"><b>{h["label"]}</b>{"".join(cells)}</div>')
    grid.append("</div>")
    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<title>Graff live evals</title>
<style>
@font-face {{ font-family: Inter; src: url("file:///usr/share/fonts/truetype/macos/Inter-Regular.ttf"); font-weight: 400; }}
@font-face {{ font-family: Inter; src: url("file:///usr/share/fonts/truetype/macos/Inter-Medium.ttf"); font-weight: 500; }}
@font-face {{ font-family: Inter; src: url("file:///usr/share/fonts/truetype/macos/Inter-SemiBold.ttf"); font-weight: 600; }}
@font-face {{ font-family: Inter; src: url("file:///usr/share/fonts/truetype/macos/Inter-Bold.ttf"); font-weight: 700; }}
html, body {{ margin: 0; background: {PAGE}; color: {INK};
  font-family: Inter, ui-sans-serif, system-ui, sans-serif; }}
.card {{ width: 1600px; height: 900px; box-sizing: border-box; padding: 40px 48px 36px 48px;
  background: {PAGE}; border-left: 12px solid {ACCENT}; position: relative; }}
.kicker {{ display: flex; justify-content: space-between; align-items: baseline;
  font-size: 15px; font-weight: 700; letter-spacing: .22em; color: {ACCENT}; }}
.kicker span {{ letter-spacing: 0; font-weight: 500; color: {INK3}; }}
h1 {{ margin: 18px 0 6px; font-size: 44px; letter-spacing: -.03em; line-height: 1.05; }}
.sub {{ margin: 0 0 28px; font-size: 20px; color: {INK2}; }}
.seats {{ display: grid; grid-template-columns: repeat(5, 1fr); gap: 16px; }}
.seat {{ background: #fff; border: 1px solid {LINE}; border-radius: 18px; padding: 16px 18px 18px;
  position: relative; overflow: hidden; }}
.seat i {{ position: absolute; left: 0; top: 0; bottom: 0; width: 8px; }}
.seat .name {{ font-size: 16px; font-weight: 700; color: {INK2}; }}
.seat .pass {{ font-size: 48px; font-weight: 780; letter-spacing: -.03em; margin-top: 8px; }}
.seat .usd {{ font-size: 17px; color: {INK2}; margin-top: 4px; }}
.section {{ margin: 28px 0 10px; font-size: 13px; font-weight: 700; letter-spacing: .14em; color: {INK3}; }}
.bar {{ display: grid; grid-template-columns: 88px 1fr 84px; gap: 12px; align-items: center; margin: 7px 0; }}
.bar span {{ font-weight: 650; }}
.track {{ height: 22px; background: {TINT}; border-radius: 999px; overflow: hidden; }}
.track b {{ display: block; height: 100%; border-radius: 999px; }}
.bar em {{ font-style: normal; font-weight: 650; font-variant-numeric: tabular-nums; }}
.grid {{ margin-top: 8px; }}
.ghead, .grow {{ display: grid; grid-template-columns: 72px repeat(12, 1fr); gap: 6px; align-items: center; margin: 4px 0; }}
.ghead b, .grow b {{ font-size: 12px; color: {INK3}; font-weight: 650; }}
.grow i {{ display: block; height: 18px; border-radius: 5px; background: var(--c); }}
.grow i.bad {{ background: #f3d6c8; }}
.grow i.na {{ background: {TINT}; }}
.foot {{ position: absolute; left: 48px; right: 48px; bottom: 28px; font-size: 14px; color: {INK3}; }}
</style></head>
<body><div class="card">
  <div class="kicker">GRAFF · LIVE EVALS <span>codegraff.com</span></div>
  <h1>12 gated PRs. Same SuperGrok seat.</h1>
  <p class="sub">grok-4.6 · n=3 · pass ≥2/3 · honest list$ on passing reps of passing tasks</p>
  <div class="seats">{''.join(cards)}</div>
  <div class="section">HONEST LIST$ · LOWER IS BETTER</div>
  {''.join(bars)}
  <div class="section">TASK GRID · FILL = PASS</div>
  {''.join(grid)}
  <div class="foot">Official low band · SuperGrok cash $0 · failed task $0 · only #195 is G1–G6 certified · exo $ is a floor (3 timeout-ok reps had no usage)</div>
</div></body></html>
"""


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    summary_path = OUT / "summary.json"
    if "--from-jsonl" in sys.argv:
        summary = build_summary()
        missing = [h for h, s in summary["harnesses"].items() if s["n_reps"] == 0]
        if missing:
            raise SystemExit(f"no rows for {missing} — run with local results/")
        summary_path.write_text(json.dumps(summary, indent=2) + "\n")
        print("wrote", summary_path)
    else:
        if not summary_path.exists():
            raise SystemExit(f"missing {summary_path} (pass --from-jsonl)")
        summary = json.loads(summary_path.read_text())
    (OUT / "live-20260909.svg").write_text(svg(summary))
    (OUT / "card.html").write_text(html_card(summary))
    print("wrote", OUT / "live-20260909.svg")
    print("wrote", OUT / "card.html")


if __name__ == "__main__":
    main()
