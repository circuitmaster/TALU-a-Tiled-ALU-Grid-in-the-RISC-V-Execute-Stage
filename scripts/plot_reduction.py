"""Fig. 4 of the paper: (a) whole-vector and (b) segmented
reduction-mechanism ablation, from results/fig4_reduction.csv
(written by tools/abl_reduce.py).

    python3 scripts/plot_reduction.py   ->  results/fig4_reduction.pdf (+ .png)
"""
import csv, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, NullLocator

# Palette: the purples of the paper's drawio figures.
INK, DEEP, MID = "#3d2350", "#6c4a85", "#9673a6"
LILAC = "#c9aeda"
GRAYTXT = "#666666"

plt.rcParams.update({
    "font.family": "Liberation Sans",  # Arial metrics
    "font.size": 7, "axes.labelsize": 7, "xtick.labelsize": 6.5,
    "ytick.labelsize": 6.5, "legend.fontsize": 6.5,
    "axes.linewidth": 0.8, "xtick.major.width": 0.8, "ytick.major.width": 0.8,
    "xtick.major.size": 2.5, "ytick.major.size": 2.5,
    "axes.edgecolor": INK, "xtick.color": INK, "ytick.color": INK,
    "axes.labelcolor": INK, "text.color": INK,
    "hatch.linewidth": 0.5, "hatch.color": DEEP,
    "pdf.fonttype": 42, "ps.fonttype": 42,
})

# ---- data: cycles at AVL = 1024 from tools/abl_reduce.py ----------------------
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV = os.path.join(ROOT, "results", "fig4_reduction.csv")
LABEL = {"vvadd": "vvadd", "sum": "sum", "dot": "dot", "sumsq": "L$_2$",
         "sad": "SAD", "segsum": "sum", "segdot": "dot", "segdotpk": "packed"}
rows = list(csv.DictReader(open(CSV)))
red_kernels = [LABEL[r["kernel"]] for r in rows]
none = [int(r["none"]) for r in rows]
tree = [int(r["tree"]) for r in rows]
diag = [int(r["diagonal"]) for r in rows]
# Best mechanism and its margin over the runner-up.
best = []
for n, t, d in zip(none, tree, diag):
    if n == t == d:
        best.append(None)
    elif t <= d:
        best.append(("tree", f"{min(n, d) / t:.2f}×"))
    else:
        best.append(("diag", f"{min(n, t) / d:.1f}×" if min(n, t) / d >= 10
                     else f"{min(n, t) / d:.2f}×"))

def arrow_axes(ax):
    """Open L-shaped axes with arrowheads."""
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.plot(1, 0, ">", color=INK, ms=3.2, transform=ax.transAxes, clip_on=False)
    ax.plot(0, 1, "^", color=INK, ms=3.2, transform=ax.transAxes, clip_on=False)


def panel_title(ax, text, y):
    ax.text(0.5, y, text, transform=ax.transAxes, ha="center", va="top",
            fontsize=7.5, fontweight="bold", fontstyle="italic", color=INK)


fig, (axa, axs) = plt.subplots(
    1, 2, figsize=(3.5, 1.95),
    gridspec_kw=dict(width_ratios=[5, 3], wspace=0.08))
fig.subplots_adjust(left=0.115, right=0.975, top=0.85, bottom=0.30)

# ---- (a)/(b) reduction mechanisms --------------------------------------------
w = 0.27


def reduction_panel(ax, idx):
    xs = range(len(idx))
    pick = lambda v: [v[i] for i in idx]
    ax.bar([x - w for x in xs], pick(none), w, color="white", ec=INK, lw=0.5,
           hatch="//////", label="none (scalar)", zorder=2)
    ax.bar(list(xs), pick(tree), w, color=LILAC, ec=INK, lw=0.5,
           label="tree adder", zorder=2)
    ax.bar([x + w for x in xs], pick(diag), w, color=DEEP, ec=INK, lw=0.5,
           label="diagonal", zorder=2)
    for x, b in zip(xs, pick(best)):
        mech, txt = b if b else ("", "tie")
        big = bool(mech) and float(txt.rstrip("×")) >= 10   # order of magnitude
        ax.annotate(f"{mech}\n{txt}" if mech else txt, xy=(x, 0),
                    xycoords=ax.get_xaxis_transform(), xytext=(0, -13),
                    textcoords="offset points", ha="center", va="top",
                    fontsize=5.6, linespacing=1.05,
                    fontweight="bold" if big else "normal",
                    color=DEEP if mech == "diag" else GRAYTXT,
                    annotation_clip=False)
    ax.set_yscale("log")
    ax.set_ylim(150, 16000)
    ax.yaxis.set_major_locator(FixedLocator([300, 1000, 3000, 10000]))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.set_yticklabels(["300", "1k", "3k", "10k"])
    ax.set_xticks(list(xs))
    ax.set_xticklabels(pick(red_kernels))
    ax.set_xlim(-0.55, len(idx) - 0.45)
    arrow_axes(ax)


reduction_panel(axa, [0, 1, 2, 3, 4])
reduction_panel(axs, [5, 6, 7])
axa.set_ylabel("Cycles (log)")
axs.set_yticklabels([])
axa.legend(loc="lower left", bbox_to_anchor=(0.06, 1.03), ncol=3, frameon=True,
           fancybox=False, edgecolor=INK, handlelength=1.4, columnspacing=1.0,
           handletextpad=0.5, borderpad=0.35).get_frame().set_linewidth(0.6)
panel_title(axa, "(a) Whole-vector", -0.43)
panel_title(axs, "(b) Segmented", -0.43)

out = os.path.join(ROOT, "results", "fig4_reduction")
fig.savefig(out + ".pdf")
fig.savefig(out + ".png", dpi=300)
print(f"wrote {os.path.relpath(out, ROOT)}.pdf/.png")
