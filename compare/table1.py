#!/usr/bin/env python3
"""Table I of the paper: cycles for the RISC-V^2 benchmark suite on
TALU (baseline and 1 GHz RTL), RISC-V^2 and Vicuna, at 4 lanes/rows.

  python3 compare/table1.py                 # full table, AVL=1024
  python3 compare/table1.py --talu-only     # both TALU cores, no baselines
  python3 compare/table1.py --avl 64        # another vector length

needs: build/run (rtl/) and build/run_base (rtl_base/)  -- `make sim`
       compare/setup_baselines.sh                         -- for the baselines
Writes results/table1.csv (or results/table1_avl<AVL>.csv).
"""
import argparse, csv, math, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import suite  # noqa: E402  (TALU kernel generators + runner)

# paper row       TALU kernel   RISC-V^2 example  Vicuna kernel
KERNELS = [
    ("vvadd",       "add",        "vvadd",          "vvadd"),
    ("multiply",    "mul",        "multiply",       "multiply"),
    ("saxpy",       "saxpy",      "saxpy",          "saxpy"),
    ("dot product", "dot",        "dot_product",    "dot"),
    ("FIR (5-tap)", "fir5",       "fir",            "fir"),
    ("median",      "median",     None,             "median"),  # no vmin/vmax
    ("SAD",         "sad",        None,             "sad"),     # in RISC-V^2
    ("perceptron",  "perceptron", "perceptron",     "perceptron"),
    ("(a+b)^8",     "power",      "power",          "power"),
    ("average",     "average",    "average",        "average"),
]


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).stdout


def riscv2(ex, avl):
    out = run([os.path.join(HERE, "run_riscv2.sh"), ex, str(avl), "4", "0"])
    m = re.search(r"->\s+(\d+) cycles", out)
    return int(m.group(1)) if m else None


def vicuna(k, avl):
    out = run([os.path.join(HERE, "run_vicuna.sh"), k, str(avl)])
    m = re.search(r"->\s+(\d+) cycles", out)
    return int(m.group(1)) if m else None


def gmean(xs):
    xs = [x for x in xs if x]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--avl", type=int, default=1024)
    ap.add_argument("--talu-only", action="store_true")
    a = ap.parse_args()
    for sim in ("build/run", "build/run_base"):
        if not os.path.exists(os.path.join(ROOT, sim)):
            sys.exit(f"{sim} missing -- run `make sim` first")

    vstart = 0
    if not a.talu_only:
        vstart = vicuna("empty", a.avl) or 0      # fixed start-up, subtracted

    rows = []
    for name, tk, rk, vk in KERNELS:
        base = suite.measure(tk, a.avl, "build/run_base")
        fast = suite.measure(tk, a.avl, "build/run")
        r2 = riscv2(rk, a.avl) if (rk and not a.talu_only) else None
        vc = vicuna(vk, a.avl) if not a.talu_only else None
        vc = vc - vstart if vc else None
        rows.append(dict(kernel=name, talu_base=base, talu_1ghz=fast,
                         riscv2=r2, vicuna=vc))
        print(f"  measured {name:<12} base={base} 1GHz={fast} rv2={r2} vic={vc}",
              file=sys.stderr)

    def r(x, y):
        return y / x if (x and y) else None

    print(f"\nCycles, AVL={a.avl}, 4 lanes/rows (Table I)\n")
    hdr = (f"{'kernel':<13}{'base':>7}{'1GHz':>7}{'RISC-V2':>9}{'Vicuna':>8}"
           f"{'vs RV2':>8}{'vs Vic':>8}")
    print(hdr); print("-" * len(hdr))
    fmt = lambda v: f"{v}" if v is not None else "n/a"
    sp = lambda v: f"{v:.1f}x" if v else "-"
    for x in rows:
        print(f"{x['kernel']:<13}{fmt(x['talu_base']):>7}{fmt(x['talu_1ghz']):>7}"
              f"{fmt(x['riscv2']):>9}{fmt(x['vicuna']):>8}"
              f"{sp(r(x['talu_1ghz'], x['riscv2'])):>8}"
              f"{sp(r(x['talu_1ghz'], x['vicuna'])):>8}")
    tb = sum(x["talu_base"] for x in rows)
    tf = sum(x["talu_1ghz"] for x in rows)
    g2 = gmean([r(x["talu_1ghz"], x["riscv2"]) for x in rows])
    gv = gmean([r(x["talu_1ghz"], x["vicuna"]) for x in rows])
    print("-" * len(hdr))
    print(f"{'total/geomean':<13}{tb:>7}{tf:>7}{'':>9}{'':>8}"
          f"{sp(g2):>8}{sp(gv):>8}")

    by = {x["kernel"]: x for x in rows}
    for lbl, k in (("dot / add", "dot product"), ("(a+b)^8 / add", "(a+b)^8")):
        cells = []
        for col in ("talu_base", "talu_1ghz", "riscv2", "vicuna"):
            v = r(by["vvadd"][col], by[k][col])
            cells.append(f"{v:.2f}" if v else "-")
        print(f"{lbl:<13}{cells[0]:>7}{cells[1]:>7}{cells[2]:>9}{cells[3]:>8}")
    print(f"\nretiming cost (1 GHz vs base, all kernels): {100*(tf/tb-1):+.1f}% cycles")
    if g2:
        print(f"time ratio vs RISC-V^2 at 1.032 GHz vs 1 GHz: {g2*1.032:.1f}x geomean")

    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    out = os.path.join(ROOT, "results",
                       "table1.csv" if a.avl == 1024 else f"table1_avl{a.avl}.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader(); w.writerows(rows)
    print(f"\nwrote {os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
