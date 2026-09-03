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
SWE = HERE / "swe-results.jsonl"
SWE_KIMI = HERE / "swe-kimi-results.jsonl"
BOARD = Path("/tmp/frontier-harness-eval/results/eval-data.json")
OUT = HERE / "tb21-graff-grok46.png"

# Fair no-append first pass was 14/21. Chart shows the final run only.

# zigrepper frontend/src/app/globals.css (:root)
EMERALD = "#059669"
EMERALD_LT = "#10b981"
EMERALD_TEXT = "#047857"
INK = "#171717"
MUTED = "#6b7280"
LINE = "#e5e7eb"
FAIL = "#dc2626"
OK = "#059669"
BG = "#f7f1e7"
BAR = "#d1d5db"
BAR_EDGE = "#d1d5db"
ORANGE = "#d45a43"
INDIGO = "#2654d9"
# grok-4.6 family — warm gold, distinct from K3 gray and kimi indigo
GROK = "#b45309"
GROK_LT = "#d97706"
GROK_INK = "#7c2d12"


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
        det = [t for t in h["task_details"] if t["id"].startswith("terminal-bench/")]
        ok = sum(1 for t in det if t.get("success"))
        spent = sum(t.get("cost_first_cold_usd") or 0 for t in det)
        k3.append((h["name"], ok, spent))
    k3_pass = {}
    for h in board["harnesses"]:
        for t in h["task_details"]:
            if t["id"].startswith("terminal-bench/"):
                k3_pass.setdefault(t["id"].split("/", 1)[1], {})[h["name"]] = bool(t.get("success"))
    return ours, exo, tb, k3, k3_pass, board.get("model", "k3")


def frontier_names(ranks: list) -> set[str]:
    """Max-pass / min-list$ staircase. Rows with no $ cannot sit on it."""
    out = set()
    best = -1
    for name, passes, _, usd in sorted((r for r in ranks if r[3] is not None), key=lambda r: r[3]):
        if passes > best:
            out.add(name)
            best = passes
    return out


def main():
    ours, exo, tb, k3, k3_pass, k3_model = load()
    kimi = load_jsonl(KIMI)
    gok = sum(1 for t in tb if ours.get(t, {}).get("pass_"))
    eok = sum(1 for t in tb if exo.get(t, {}).get("pass_"))
    kok = sum(1 for t in tb if kimi.get(t, {}).get("pass_"))
    total_usd = sum(c for c in (list_usd(ours[t]) for t in tb if t in ours) if c)
    kimi_usd = sum(c for c in (list_usd(kimi[t]) for t in tb if t in kimi) if c)
    exo_k3 = next(v for n, v, _ in k3 if n == "exo")

    ranks = [(f"{n}   K3 board", v, "k3", usd) for n, v, usd in k3]
    ranks += [
        ("graff   grok-4.6", gok, "graff_now", total_usd),
        ("graff   kimi-k3 ours", kok, "graff_kimi", kimi_usd),
        ("exo   grok-4.6 ours", eok, "exo_now", None),
    ]
    ranks.sort(key=lambda x: (-x[1], 0 if x[2] == "graff_now" else 1, x[0]))
    on_front = frontier_names(ranks)

    color = {
        "k3": BAR,
        "graff_now": GROK,
        "graff_kimi": INDIGO,
        "exo_now": ORANGE,
    }
    edge = {
        "k3": BAR_EDGE,
        "graff_now": GROK_INK,
        "graff_kimi": "#1d4ed8",
        "exo_now": ORANGE,
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

    fig = plt.figure(figsize=(14.6, 15.4), dpi=160)
    fig.suptitle("FrontierHarness", fontsize=18, fontweight="bold", color=INK, x=0.02, ha="left", y=0.985)
    fig.text(
        0.02, 0.968,
        "Each bar is one harness on the same 21 tasks.  The $ next to a bar is that run’s API bill at list rates.",
        fontsize=9.5, color=MUTED, ha="left", va="top",
    )
    gs = fig.add_gridspec(3, 1, height_ratios=[2.6, 1.2, 1.1], hspace=0.55,
                          left=0.015, right=0.98, top=0.945, bottom=0.05)
    ax = fig.add_subplot(gs[0])
    ax2 = fig.add_subplot(gs[1])
    ax3 = fig.add_subplot(gs[2])

    names = [r[0] for r in ranks]
    vals = [r[1] for r in ranks]
    kinds = [r[2] for r in ranks]
    usds = [r[3] for r in ranks]
    y = list(range(len(names) - 1, -1, -1))
    # Labels live inside the axes (negative x) so the PNG cannot crop them.
    name_w = 7.6
    ax.barh(y, vals, color=[color[k] for k in kinds], height=0.58,
            edgecolor=[edge[k] for k in kinds], linewidth=0.7)
    ax.set_yticks(y)
    ax.set_yticklabels([])
    ax.tick_params(axis="y", length=0)
    ax.set_xlim(-name_w, 24)
    ax.set_xlabel("tasks passed  (out of 21 Terminal-Bench tasks)", fontsize=10, color=MUTED)
    ax.set_xticks(range(0, 22, 2))
    ax.axvline(0, color=LINE, lw=0.8, zorder=0)
    ax.axvline(16, color="#d1d5db", lw=0.8, ls="--", zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_visible(False)
    for yi, v, k, usd, name in zip(y, vals, kinds, usds, names):
        ink = edge[k] if k != "k3" else INK
        ax.text(-0.18, yi, name, ha="right", va="center", fontsize=8.6, color=ink,
                fontweight="bold" if name in on_front else "regular", clip_on=False)
        if usd is None:
            extra = "no token log"
        else:
            extra = f"${usd:.2f}"
        tag = "   frontier" if name in on_front else ""
        ax.text(v + 0.28, yi, f"{v}/21   {extra}{tag}", va="center", fontsize=8.8,
                fontweight="bold" if k in ("graff_now", "exo_now") else "regular",
                color=ink if k != "k3" else MUTED, clip_on=False)
    ax.legend(
        handles=[
            Patch(facecolor=GROK, edgecolor=GROK_INK, label="gold  =  grok-4.6 (graff)"),
            Patch(facecolor=INDIGO, edgecolor="#1d4ed8", label="blue  =  kimi-k3 (graff)"),
            Patch(facecolor=ORANGE, edgecolor=ORANGE, label="coral  =  grok-4.6 (exo)"),
            Patch(facecolor=BAR, edgecolor=BAR_EDGE, label="gray  =  published K3 board"),
        ],
        loc="lower right", fontsize=8, framealpha=0.97, edgecolor=LINE,
        facecolor=BG, borderpad=0.6, labelspacing=0.4,
    )

    # --- per-task grid ---
    ax2.set_xlim(-0.7, len(tb) - 0.3)
    ax2.set_ylim(-1.8, 3.6)
    ax2.axis("off")
    ax2.set_title("Per task   ·   graff vs exo on grok-4.6", loc="left", fontsize=12, fontweight="bold", pad=8)
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
    ax2.text(-0.55, 2.82, "exo", ha="right", va="center", fontsize=8, color=ORANGE, fontweight="bold")
    ax2.text(-0.55, 2.02, "graff", ha="right", va="center", fontsize=8, color=GROK_INK, fontweight="bold")
    ax2.text(-0.55, 0.75, "K3", ha="right", va="center", fontsize=8, color=INDIGO)
    ax2.text(0.0, 3.35, "top = exo grok-4.6    mid = graff grok-4.6    indigo bar = how many of 12 K3 harnesses passed",
             fontsize=8, color=MUTED)

    swe = load_jsonl(SWE)
    swe_kimi = load_jsonl(SWE_KIMI)
    board = json.loads(BOARD.read_text())
    exo_h = next(h for h in board["harnesses"] if h["name"] == "exo")
    exo_swe = {t["id"].split("/")[-1]: t.get("cost_first_cold_usd") or 0
               for t in exo_h["task_details"] if not t["id"].startswith("terminal-bench/")}
    names_s = sorted(exo_swe)
    x = list(range(len(names_s)))
    w = 0.36
    g_cost = [list_usd(swe[n]) or 0 if n in swe else 0 for n in names_s]
    e_cost = [exo_swe[n] for n in names_s]
    k_cost = [list_usd(swe_kimi[n]) or 0 if n in swe_kimi else 0 for n in names_s]
    ax3.bar([i - w / 2 for i in x], g_cost, width=w, color=GROK, label="graff grok-4.6  $  (1/9 pass)")
    if any(k_cost):
        ax3.bar([i + w / 2 for i in x], k_cost, width=w, color=INDIGO, label="graff kimi-k3  $  (1/9 pass)")
        ax3.plot(x, e_cost, color=ORANGE, marker="o", lw=1.4, label="exo K3 board $  (0/9 pass)")
    else:
        ax3.bar([i + w / 2 for i in x], e_cost, width=w, color=ORANGE, label="exo K3 board $  (0/9 pass)")
    ax3.set_xticks(x)
    ax3.set_xticklabels([n.replace("-", "-\n") for n in names_s], fontsize=7.2, rotation=30, ha="right")
    ax3.set_ylabel("USD", fontsize=9, color=MUTED)
    ax3.margins(x=0.06)
    ax3.spines["top"].set_visible(False)
    ax3.spines["right"].set_visible(False)
    gsum = sum(g_cost)
    ksum = sum(k_cost)
    esum = sum(e_cost)
    extra = f"    graff kimi-k3  ${ksum:.2f}" if ksum else ""
    ax3.set_title(
        f"DeepSWE 9  (the other 9 of 30)    graff grok  ${gsum:.2f} (1/9)    "
        f"exo K3  ${esum:.2f} (0/9){extra}",
        loc="left", fontsize=11, fontweight="bold", pad=8, color=INK,
    )
    ax3.legend(frameon=False, fontsize=8, loc="upper right")

    fig.savefig(OUT, facecolor=BG)
    print(OUT)
    print(f"graff grok {gok}/21  exo grok {eok}/21  exo K3 {exo_k3}/21  list_usd={total_usd:.4f}")
    print("frontier:", sorted(on_front))


if __name__ == "__main__":
    main()
