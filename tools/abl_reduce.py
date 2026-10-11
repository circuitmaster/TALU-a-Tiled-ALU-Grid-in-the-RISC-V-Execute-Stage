#!/usr/bin/env python3
"""Cycle comparison of the three reduction mechanisms on the same RTL.

  none      no reduction hardware -- stream raw lanes out, reduce in scalar code
  tree      drain-path N-input adder (GFLOW accumulate over all drained lanes)
  diagonal  ADD(W,SW) collapse inside the fabric
Fig. 4 of the paper; writes results/fig4_reduction.csv
(plot: python3 scripts/plot_reduction.py).

The mechanism is chosen by the *mapping*, so all three run on the default
build; the DIAG_EN / RED_TREE knobs in rtl/talu_pkg.sv separately
prove which hardware each mapping actually needs.
"""
import os, re, subprocess, sys

# simulator under test (default: the 1 GHz core in rtl/); e.g. the baseline:
#   TALU_SIM=build/run_base python3 abl_reduce.py ...
SIM = os.environ.get("TALU_SIM", "build/run")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build/abl")
N = 4
SRC2, TMP, OUT, SCAL = 1, 2, 3, 4          # lui immediates -> 4K-aligned regions

DIAG_TREE = ["gcfg 0,1, copya, W,W, 0", "gcfg 0,2, copya, W,W, 0",
             "gcfg 1,1, copya, W,W, 0", "gcfg 2,1, add, W,SW, 0",
             "gcfg 1,2, add, W,SW, 0",  "gcfg 0,3, add, W,SW, 1"]

col0 = lambda op, dr: [f"gcfg {r},0, {op}, W,W, {dr}" for r in range(N)]


def scalar_sum(src_lui, blocks, acc, lbl):
    """4-way unrolled scalar reduction of blocks*4 words (fair to 'none')."""
    return [f"lui x10, {src_lui}", f"addi x12, x0, {blocks}", f"addi {acc}, x0, 0",
            f"{lbl}:", "lw x13, 0(x10)", "lw x14, 4(x10)", "lw x15, 8(x10)",
            "lw x16, 12(x10)", f"add {acc}, {acc}, x13", f"add {acc}, {acc}, x14",
            f"add {acc}, {acc}, x15", f"add {acc}, {acc}, x16",
            "addi x10, x10, 16", "addi x12, x12, -1", f"bne x12, x0, {lbl}"]


def scalar_seg(src_lui, out_lui, blocks, lbl):
    """Per-block (segmented) reduction in scalar code."""
    return [f"lui x10, {src_lui}", f"lui x11, {out_lui}", f"addi x12, x0, {blocks}",
            f"{lbl}:", "lw x13, 0(x10)", "lw x14, 4(x10)", "lw x15, 8(x10)",
            "lw x16, 12(x10)", "add x13, x13, x14", "add x13, x13, x15",
            "add x13, x13, x16", "sw x13, 0(x11)", "addi x10, x10, 16",
            "addi x11, x11, 4", "addi x12, x12, -1", f"bne x12, x0, {lbl}"]


def compact(src_lui, out_lui, blocks, lbl):
    """Scalar compaction of the diagonal's strided output (one word per N-word
    drain slot) into a packed array."""
    return [f"lui x10, {src_lui}", f"lui x11, {out_lui}", f"addi x12, x0, {blocks}",
            f"{lbl}:", "lw x13, 0(x10)", "sw x13, 0(x11)", f"addi x10, x10, {4*N}",
            "addi x11, x11, 4", "addi x12, x12, -1", f"bne x12, x0, {lbl}"]


def kernel(name, mech, avl):
    b = avl // N
    packed = name == "segdotpk"          # segmented dot, packed output
    if packed:
        name = "segdot"
    s2 = "x5" if name in ("sum", "sumsq", "segsum") else "x6"
    op = {"sum": "copya", "segsum": "copya", "dot": "mul", "segdot": "mul",
          "sumsq": "mul", "vvadd": "add", "sad": "max"}[name]
    hdr = ["addi x5, x0, 0", f"lui x6, {SRC2}", f"lui x7, {TMP}", f"addi x8, x0, {b}"]

    if name == "vvadd":                                   # no reduction at all
        return hdr + col0("add", 1) + [f"gflow x5, x6, x7, x8, 0", "ecall"]

    if name == "sad":                                     # two reduce passes
        body = []
        for i, o in enumerate(("max", "min")):
            # destination address FIRST: gflow reads its operands unforwarded,
            # so the config block must sit between the write and the gflow
            if mech == "none":
                # the scalar epilogue consumes each pass immediately, so both
                # passes stream to the SAME buffer (no per-pass offset)
                body += [f"lui x7, {TMP}"] + col0(o, 1) + ["gflow x5, x6, x7, x8, 0"]
                body += scalar_sum(TMP, b, "x20" if i == 0 else "x21", f"S{i}")
            else:
                # both scalars must coexist until the final subtract -> offset
                addr = [f"lui x7, {TMP}"] + ([f"addi x7, x7, {i*4}"] if i else [])
                if mech == "diagonal":
                    body += addr + col0(o, 0) + DIAG_TREE + ["gflow x5, x6, x7, x8, 1"]
                else:
                    body += addr + col0(o, 1) + ["gflow x5, x6, x7, x8, 1"]
        if mech == "none":
            body += ["sub x22, x20, x21"]
        else:
            body += [f"lui x10, {TMP}", "lw x20, 0(x10)", "lw x21, 4(x10)",
                     "sub x22, x20, x21"]
        return hdr + body + ["ecall"]

    segmented = name.startswith("seg")
    if mech == "diagonal":
        cfg = col0(op, 0) + DIAG_TREE
        flow = [f"gflow x5, {s2}, x7, x8, {0 if segmented else 1}"]
        tail = compact(TMP, OUT, b, "P") if packed else []
        return hdr + cfg + flow + tail + ["ecall"]
    if mech == "tree" and not segmented:
        return hdr + col0(op, 1) + [f"gflow x5, {s2}, x7, x8, 1", "ecall"]
    # tree cannot express a segmented reduction -> same fallback as 'none'
    pre = hdr + col0(op, 1) + [f"gflow x5, {s2}, x7, x8, 0"]
    tail = scalar_seg(TMP, OUT, b, "S") if segmented else scalar_sum(TMP, b, "x20", "S")
    return pre + tail + ["ecall"]


def run(src, name):
    if isinstance(src, list): src = "\n".join(src)
    p = os.path.join(BUILD, f"{name}.s"); open(p, "w").write(src + "\n")
    h = os.path.join(BUILD, f"{name}.hex")
    r = subprocess.run([sys.executable, "tools/asm.py", p, "-o", h],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        return None
    out = subprocess.run(["vvp", SIM, f"+PROG={h}", "+MAXCYC=400000"],
                         cwd=ROOT, capture_output=True, text=True).stdout
    m = re.search(r"HALT at cycle (\d+)", out)
    return int(m.group(1)) if m else None


def main():
    avl = int(sys.argv[1]) if len(sys.argv) > 1 else 1024
    os.makedirs(BUILD, exist_ok=True)
    rows = [("vvadd", "element-wise (no reduction)"), ("sum", "whole-vector sum"),
            ("dot", "dot product"), ("sumsq", "L2 (sum of squares)"),
            ("sad", "motion est. / SAD (2 passes)"),
            ("segsum", "segmented sum (256 blocks)"),
            ("segdot", "segmented dot (256 blocks)"),
            ("segdotpk", "segmented dot, packed output")]
    table = []
    print(f"reduction-mechanism comparison, N={N}, AVL={avl}\n")
    print(f"{'kernel':<30} {'none':>8} {'tree':>8} {'diagonal':>9}   best")
    for k, desc in rows:
        c = {}
        for mech in ("none", "tree", "diagonal"):
            c[mech] = run(kernel(k, mech, avl), f"{k}_{mech}")
        vals = {m: v for m, v in c.items() if v}
        best = min(vals, key=vals.get) if vals else "-"
        f = lambda v: str(v) if v else "n/a"
        print(f"{desc:<30} {f(c['none']):>8} {f(c['tree']):>8} {f(c['diagonal']):>9}   {best}")
        table.append([k, c["none"], c["tree"], c["diagonal"]])
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    out = os.path.join(ROOT, "results", "fig4_reduction.csv")
    with open(out, "w") as fh:
        fh.write("kernel,none,tree,diagonal\n")
        fh.writelines(",".join(str(x) for x in r) + "\n" for r in table)
    print(f"\nwrote {os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
