#!/usr/bin/env python3
"""TB-21 PNG: K3 board + graff/exo on grok-4.6 (before and now)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import list_price

HERE = Path(__file__).resolve().parent
OURS = HERE / "results.jsonl"
EXO = HERE / "exo-results.jsonl"
KIMI = HERE / "kimi-results.jsonl"
BOARD = Path("/tmp/frontier-harness-eval/results/eval-data.json")
OUT = HERE / "tb21-graff-grok46.png"

# Hillclimb checkpoints (TB-21 pass counts on grok-4.6).
GRAFF_FIRST = 14  # before eval-only append
GRAFF_FIRST_USD = 5.0491  # grok-4.6 list $ on that 21-task pass
GRAFF_MID = 17  # BENCH_APPEND v1

EMERALD = "#059669"
EMERALD_LT = "#6ee7b7"
INK = "#111827"
MUTED = "#6b7280"
LINE = "#e5e7eb"
FAIL = "#e11d48"
OK = "#059669"
BG = "#fafafa"
BAR = "#d1d5db"
BAR_EDGE = "#9ca3af"
ORANGE = "#ea580c"
INDIGO = "#6366f1"


def list_usd(rec: dict) -> float | None:
    if rec.get("tok_in") is None:
        return None
    if rec.get("list_usd") is not None:
        return float(rec["list_usd"])
    model = rec.get("model") or "grok-4.6"
    ordinary, cached = list_price.ordinary_and_cached(rec.get("tok_in"), rec.get("tok_cached"), True)
    out = int(rec.get("tok_out") or 0)
    return list_price.usd_tokens(model, ordinary, cached, out) or None


def load_jsonl(path: Path) -> dict:
    if not path.exists():
        return {}
    out = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        out[r["task"]] = r
    return out


def load():
    ours = load_jsonl(OURS)
    exo = load_jsonl(EXO)
    board = json.loads(BOARD.read_text())
    tb = [t["id"].split("/", 1)[1] for t in board["harnesses"][0]["task_details"] if t["id"].startswith("terminal-bench/")]
    k3 = []
    for h in board["harnesses"]:
        ok = sum(1 for t in h["task_details"] if t["id"].startswith("terminal-bench/") and t.get("success"))
        k3.append((h["name"], ok))
    k3_pass = {}
    for h in board["harnesses"]:
        for t in h["task_details"]:
            if t["id"].startswith("terminal-bench/"):
                k3_pass.setdefault(t["id"].split("/", 1)[1], {})[h["name"]] = bool(t.get("success"))
    return ours, exo, tb, k3, k3_pass, board.get("model", "k3")


def main():
    ours, exo, tb, k3, k3_pass, k3_model = load()
    kimi = load_jsonl(KIMI)
    gok = sum(1 for t in tb if ours.get(t, {}).get("pass_"))
    eok = sum(1 for t in tb if exo.get(t, {}).get("pass_"))
    kok = sum(1 for t in tb if kimi.get(t, {}).get("pass_"))
    costs = [list_usd(ours[t]) for t in tb if t in ours]
    total_usd = sum(c for c in costs if c is not None)
    kimi_usd = sum(c for c in (list_usd(kimi[t]) for t in tb if t in kimi) if c)
    exo_k3 = next(v for n, v in k3 if n == "exo")

    ranks = [(n if n != "exo" else "exo  ·  K3 published", v, "k3") for n, v in k3]
    ranks += [
        ("graff  ·  grok-4.6 now", gok, "graff_now"),
        ("graff  ·  grok-4.6 first", GRAFF_FIRST, "graff_first"),
        ("graff  ·  kimi-k3", kok, "graff_kimi"),
        ("exo  ·  grok-4.6 now", eok, "exo_now"),
    ]
    ranks.sort(key=lambda x: (-x[1], 0 if "now" in x[0] and "graff" in x[0] else 1, x[0]))

    color = {
        "k3": BAR,
        "graff_now": EMERALD,
        "graff_first": EMERALD_LT,
        "graff_kimi": INDIGO,
        "exo_now": ORANGE,
    }
    edge = {
        "k3": BAR_EDGE,
        "graff_now": "#047857",
        "graff_first": EMERALD,
        "graff_kimi": "#4338ca",
        "exo_now": "#c2410c",
    }

    plt.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["SF Pro Text", "Helvetica Neue", "Helvetica", "Arial"],
        "axes.edgecolor": LINE,
        "figure.facecolor": BG,
        "axes.facecolor": BG,
        "text.color": INK,
        "axes.labelcolor": INK,
        "xtick.color": MUTED,
        "ytick.color": INK,
    })

    fig = plt.figure(figsize=(13.4, 11.2), dpi=160)
    gs = fig.add_gridspec(3, 1, height_ratios=[1.35, 0.28, 1.05], hspace=0.42)
    ax = fig.add_subplot(gs[0])
    axh = fig.add_subplot(gs[1])
    ax2 = fig.add_subplot(gs[2])

    names = [n for n, _, _ in ranks]
    vals = [v for _, v, _ in ranks]
    kinds = [k for _, _, k in ranks]
    y = list(range(len(names) - 1, -1, -1))
    ax.barh(y, vals, color=[color[k] for k in kinds], height=0.72,
            edgecolor=[edge[k] for k in kinds], linewidth=0.7)
    ax.set_yticks(y)
    ax.set_yticklabels(names, fontsize=9.5)
    for tick, k in zip(ax.get_yticklabels(), kinds):
        if k == "graff_now":
            tick.set_fontweight("bold")
            tick.set_color("#047857")
        elif k == "exo_now":
            tick.set_fontweight("bold")
            tick.set_color("#c2410c")
    ax.set_xlim(0, 22.2)
    ax.set_xlabel("TB-21 passed", fontsize=10, color=MUTED)
    ax.set_xticks(range(0, 22, 2))
    ax.axvline(16, color="#d1d5db", lw=0.8, ls="--", zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    for yi, v, k in zip(y, vals, kinds):
        note = ""
        if k == "graff_now":
            note = f"   ${total_usd:.2f} list  ${total_usd/max(gok,1):.2f}/pass"
        elif k == "graff_first":
            note = f"   ${GRAFF_FIRST_USD:.2f} list  ${GRAFF_FIRST_USD/GRAFF_FIRST:.2f}/pass"
        elif k == "graff_kimi":
            note = f"   ${kimi_usd:.2f} list  ${kimi_usd/max(kok,1):.2f}/pass"
        elif k == "exo_now":
            note = "   list$ n/a (no tok events)"
        ax.text(v + 0.18, yi, f"{v}/21{note}", va="center", fontsize=8.5,
                fontweight="bold" if k in ("graff_now", "exo_now") else "regular",
                color=edge[k] if k != "k3" else MUTED)
    ax.set_title("FrontierHarness  ·  terminal-bench 21", loc="left", fontsize=16, fontweight="bold", pad=14)
    ax.text(0, 1.06,
            f"Gray = published Kimi {k3_model} board.  Emerald/orange = this grok-4.6 run.  "
            f"graff list $ {total_usd:.2f}  ·  exo tokens not in events (list$ n/a).",
            transform=ax.transAxes, fontsize=8.5, color=MUTED, va="bottom")
    ax.legend(handles=[
        Patch(facecolor=EMERALD, edgecolor="#047857", label="graff grok-4.6 now"),
        Patch(facecolor=EMERALD_LT, edgecolor=EMERALD, label="graff grok-4.6 first (14)"),
        Patch(facecolor=INDIGO, edgecolor="#4338ca", label="graff kimi-k3"),
        Patch(facecolor=ORANGE, edgecolor="#c2410c", label="exo grok-4.6 now"),
        Patch(facecolor=BAR, edgecolor=BAR_EDGE, label=f"K3 published (exo was {exo_k3}/21)"),
    ], loc="lower right", frameon=False, fontsize=8)

    axh.set_xlim(-0.4, 3.4)
    axh.set_ylim(0, 1)
    axh.axis("off")
    steps = [
        (0, GRAFF_FIRST, f"graff first\n${GRAFF_FIRST_USD:.2f}", EMERALD_LT),
        (1, GRAFF_MID, "after append v1", EMERALD),
        (2, gok, f"graff now\n${total_usd:.2f}", "#047857"),
        (3, eok, "exo grok-4.6\nlist$ n/a", ORANGE),
    ]
    axh.plot([0, 1, 2], [0.55, 0.55, 0.55], color=EMERALD, lw=2, zorder=1)
    for x, v, lab, c in steps:
        axh.scatter([x], [0.55], s=140, color=c, zorder=2, edgecolors="white", linewidths=1.2)
        axh.text(x, 0.82, f"{v}/21", ha="center", fontsize=10, fontweight="bold", color=c)
        axh.text(x, 0.18, lab, ha="center", fontsize=8, color=MUTED)
    axh.set_title("Hillclimb on grok-4.6  (eval-only append, not prompt_text)", loc="left", fontsize=11, fontweight="bold", pad=2)

    ax2.set_xlim(-0.7, len(tb) - 0.3)
    ax2.set_ylim(-1.8, 3.6)
    ax2.axis("off")
    ax2.set_title("Per task  ·  graff vs exo on grok-4.6", loc="left", fontsize=12, fontweight="bold", pad=8)
    for i, t in enumerate(tb):
        gp = bool(ours.get(t, {}).get("pass_"))
        ep = bool(exo.get(t, {}).get("pass_"))
        n_k3 = sum(k3_pass[t].values())
        ax2.add_patch(FancyBboxPatch((i - 0.38, 0), 0.76, n_k3 / 12 * 1.5,
                                     boxstyle="round,pad=0.02,rounding_size=0.08",
                                     facecolor="#c7d2fe", edgecolor="none"))
        ax2.add_patch(FancyBboxPatch((i - 0.38, 1.7), 0.76, 0.65,
                                     boxstyle="round,pad=0.02,rounding_size=0.1",
                                     facecolor=OK if gp else FAIL, edgecolor="none"))
        ax2.add_patch(FancyBboxPatch((i - 0.38, 2.5), 0.76, 0.65,
                                     boxstyle="round,pad=0.02,rounding_size=0.1",
                                     facecolor=OK if ep else FAIL, edgecolor="none"))
        ax2.text(i, 2.02, "P" if gp else "F", ha="center", va="center", color="white", fontsize=8, fontweight="bold")
        ax2.text(i, 2.82, "P" if ep else "F", ha="center", va="center", color="white", fontsize=8, fontweight="bold")
        ax2.text(i, -0.12, f"{n_k3}", ha="center", va="top", fontsize=7, color=MUTED)
        ax2.text(i, -0.48, t, ha="right", va="top", fontsize=7, color=INK, rotation=55, rotation_mode="anchor")
    ax2.text(-0.55, 2.82, "exo", ha="right", va="center", fontsize=8, color="#c2410c", fontweight="bold")
    ax2.text(-0.55, 2.02, "graff", ha="right", va="center", fontsize=8, color="#047857", fontweight="bold")
    ax2.text(-0.55, 0.75, "K3", ha="right", va="center", fontsize=8, color=INDIGO)
    ax2.text(0.0, 3.35, "top = exo grok-4.6   mid = graff grok-4.6   indigo = K3 pass count / 12",
             fontsize=8, color=MUTED)

    fig.savefig(OUT, bbox_inches="tight", facecolor=BG, pad_inches=0.28)
    print(OUT)
    print(f"graff now {gok}/21  first {GRAFF_FIRST}/21  exo grok {eok}/21  exo K3 {exo_k3}/21  list_usd={total_usd:.4f}")


if __name__ == "__main__":
    main()
