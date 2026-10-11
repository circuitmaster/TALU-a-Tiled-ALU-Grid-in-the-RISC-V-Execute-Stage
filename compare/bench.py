#!/usr/bin/env python3
"""Cross-architecture cycle comparison: TALU vs RISC-V2 vector core.

For each vector length AVL it builds+runs:
  - TALU streaming kernels (array-add, dot-product), N=4 lanes/rows
  - RISC-V2 vvadd / dot_product, 4 lanes, ideal memory (REALISTIC=0)
and prints a cycle-count table.
"""
import os, re, subprocess, sys

HERE  = os.path.dirname(os.path.abspath(__file__))
TALU  = os.path.dirname(HERE)
BUILD = os.path.join(TALU, "build")
N     = 4

def sh(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, shell=isinstance(cmd, str))

def lui_addr(min_bytes):
    """smallest 4096-aligned address >= min_bytes, with its lui immediate."""
    a = ((min_bytes + 4095) // 4096) * 4096
    return a, a >> 12

def talu_kernel(kind, avl):
    blocks = avl // N
    s2, s2i = lui_addr(avl*4)            # src2 after src1[0..avl)
    ds, dsi = lui_addr(s2 + avl*4)       # dst after src2
    hdr = [f"addi x5, x0, 0",
           f"lui  x6, {s2i}",
           f"lui  x7, {dsi}",
           f"addi x8, x0, {blocks}"]
    if kind == "add":
        cfg = [f"gcfg {r},0, add, W,W, 1" for r in range(N)]
        flow = "gflow x5, x6, x7, x8, 0"
    else:  # dot
        cfg = [f"gcfg {r},0, mul, W,W, 0" for r in range(N)] + [
            "gcfg 0,1, copya, W,W, 0", "gcfg 0,2, copya, W,W, 0",
            "gcfg 1,1, copya, W,W, 0",
            "gcfg 2,1, add, W,SW, 0", "gcfg 1,2, add, W,SW, 0",
            "gcfg 0,3, add, W,SW, 1"]
        flow = "gflow x5, x6, x7, x8, 1"
    return "\n".join(hdr + cfg + [flow, "ecall"]) + "\n"

def run_talu(kind, avl):
    src = os.path.join(BUILD, f"k_{kind}_{avl}.s")
    hexf = os.path.join(BUILD, f"k_{kind}_{avl}.hex")
    open(src, "w").write(talu_kernel(kind, avl))
    sh([sys.executable, "tools/asm.py", src, "-o", hexf], cwd=TALU)
    out = sh(["vvp", os.path.join(BUILD, "run"), f"+PROG={hexf}", "+MAXCYC=20000"], cwd=TALU).stdout
    m = re.search(r"HALT at cycle (\d+)", out)
    return int(m.group(1)) if m else None

def run_riscv2(ex, avl):
    out = sh([os.path.join(HERE, "run_riscv2.sh"), ex, str(avl), str(N), "0"]).stdout
    m = re.search(r"->\s+(\d+) cycles", out)
    return int(m.group(1)) if m else None

def main():
    avls = [int(x) for x in sys.argv[1:]] or [256, 1024, 4096]
    print(f"{'AVL':>6} | {'TALU add':>9} {'RV2 vvadd':>10} {'spd':>5} | "
          f"{'TALU dot':>9} {'RV2 dot':>9} {'spd':>5} | {'TALU d/a':>8} {'RV2 d/a':>8}")
    print("-"*92)
    for avl in avls:
        ta, td = run_talu("add", avl), run_talu("dot", avl)
        ra = run_riscv2("vvadd", avl)
        rd = run_riscv2("dot_product", avl)
        print(f"{avl:>6} | {ta:>9} {ra:>10} {ra/ta:>4.1f}x | "
              f"{td:>9} {rd:>9} {rd/td:>4.1f}x | {td/ta:>7.2f}x {rd/ra:>7.2f}x")

if __name__ == "__main__":
    main()
